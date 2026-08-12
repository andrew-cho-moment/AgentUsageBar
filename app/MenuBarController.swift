import AppKit

// MARK: - Glyphs

/// Provider marks, cached per severity color. Each vendor ships its own menu bar art as
/// a template PNG, so the real mark is used when their app is installed and a drawn path
/// stands in when it is not. Upstream re-rendered its icon on every poll for one of
/// exactly three colors.
@MainActor
enum Glyphs {
    private struct Key: Hashable {
        let provider: Provider
        let tier: UsageTier
    }

    private enum TemplateState {
        case image(NSImage)
        case absent
    }

    /// Anthropic's mark carries a dozen thin rays that fall under a pixel at 14pt.
    /// Vendors draw their own marks nearer 18pt for the same reason.
    static let pointSize: CGFloat = 16
    private static let size = NSSize(width: pointSize, height: pointSize)
    private static var cache: [Key: NSImage] = [:]
    private static var templateCache: [Provider: TemplateState] = [:]

    static func image(for provider: Provider, tier: UsageTier) -> NSImage {
        let key = Key(provider: provider, tier: tier)
        if let cached = cache[key] { return cached }

        let color = tier.nsColor
        let template = vendorTemplate(for: provider)

        // Drawn on demand rather than rasterised here. Baking a 14pt bitmap at 1x means
        // the display scales it back up on a Retina screen, which turned Anthropic's
        // fine-rayed mark into a smudge; this redraws at whatever scale is asked for.
        let image = NSImage(size: size, flipped: false) { rect in
            if let template {
                // Template art is black plus alpha, so the alpha carries the shape and
                // the colour is ours to choose.
                template.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                color.set()
                rect.fill(using: .sourceAtop)
            } else {
                color.setFill()
                color.setStroke()
                switch provider {
                case .claude: sparkPath().fill()
                case .codex:  promptPath().stroke()
                }
            }
            return true
        }
        image.isTemplate = false   // colour carries the severity signal
        cache[key] = image
        return image
    }

    /// The vendor's own menu bar artwork, taken from their installed app so the marks are
    /// the real ones. Highest scale first: more source pixels survive the downscale to
    /// 14pt. Returns nil when the app is absent, and the drawn fallback takes over.
    private static func vendorTemplate(for provider: Provider) -> NSImage? {
        if let cached = templateCache[provider] {
            switch cached {
            case .image(let image): return image
            case .absent:           return nil
            }
        }

        let (bundleID, resource) = provider.vendorTemplate
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            templateCache[provider] = .absent
            return nil
        }
        let resources = appURL.appendingPathComponent("Contents/Resources")
        for suffix in ["@3x", "@2x", ""] {
            let url = resources.appendingPathComponent("\(resource)\(suffix).png")
            if let image = NSImage(contentsOf: url) {
                templateCache[provider] = .image(image)
                return image
            }
        }
        templateCache[provider] = .absent
        return nil
    }

    /// Stand-in for Anthropic's radiating mark, drawn from a 16pt design.
    private static func sparkPath() -> NSBezierPath {
        let points: [(CGFloat, CGFloat)] = [
            (8, 1), (9, 6), (13, 3), (10, 7), (15, 8), (10, 9), (13, 13), (9, 10),
            (8, 15), (7, 10), (3, 13), (6, 9), (1, 8), (6, 7), (3, 3), (7, 6),
        ]
        let scale = pointSize / 16.0
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let scaled = NSPoint(x: point.0 * scale, y: point.1 * scale)
            if index == 0 { path.move(to: scaled) } else { path.line(to: scaled) }
        }
        path.close()
        return path
    }

    /// A shell prompt, the Codex CLI's own motif. Stands in for OpenAI's knot, which
    /// cannot be reproduced by hand at 14pt: every approximation tried collapsed into a
    /// blob, since the interlacing that carries the shape is finer than a pixel.
    private static func promptPath() -> NSBezierPath {
        let k = pointSize / 14.0          // designed in a 14pt box
        let path = NSBezierPath()
        path.lineWidth = 1.6 * k
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 2.8 * k, y: 9.8 * k))
        path.line(to: NSPoint(x: 6.2 * k, y: 7.0 * k))
        path.line(to: NSPoint(x: 2.8 * k, y: 4.2 * k))
        path.move(to: NSPoint(x: 7.6 * k, y: 3.9 * k))
        path.line(to: NSPoint(x: 11.5 * k, y: 3.9 * k))
        return path
    }
}

// MARK: - Controller

@MainActor
final class MenuBarController {
    private struct ProviderPresentation: Equatable {
        let provider: Provider
        let tier: UsageTier
        let text: String
        let tooltip: String
    }

    private let statusItem: NSStatusItem
    private let store: AppStore

    private var renderScheduled = false
    private var lastPresentation: [ProviderPresentation]?
    private var lastEmptyTitle: String?

    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
    ]

    /// Wide enough to read as a break between providers, since each group already
    /// opens with its own mark.
    private static let groupSeparator = "   "

    init(store: AppStore, onLeftClick: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.store = store

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "AgentUsageBar"

        if let button = statusItem.button {
            button.target = ClickRouter.shared
            button.action = #selector(ClickRouter.handle(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            ClickRouter.shared.onLeftClick = onLeftClick
            ClickRouter.shared.onQuit = onQuit
            ClickRouter.shared.statusItem = statusItem
        }

        render()
    }

    /// A refresh publishes about seven separate changes, and every one of them lands
    /// here. Collapsing to a single render per turn of the run loop keeps the status item
    /// from being rebuilt for each intermediate state.
    func setNeedsRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renderScheduled = false
                self.render()
            }
        }
    }

    // MARK: Rendering

    /// One compact group per signed-in provider: its mark, then a percentage per
    /// headline window.
    func render() {
        guard let button = statusItem.button else { return }

        let providers = store.visibleProviders
        guard !providers.isEmpty else {
            // Sign-in is only known once a fetch returns, so until the first one does,
            // "not signed in" would be a false claim rather than an unknown one.
            let checking = store.lastUpdated == nil
            let title = checking ? "…" : "—"
            guard lastPresentation != [] || lastEmptyTitle != title else { return }
            lastPresentation = []
            lastEmptyTitle = title
            button.image = nil
            button.attributedTitle = NSAttributedString(string: title)
            button.toolTip = checking
                ? "Checking Claude and Codex…"
                : "Not signed in to Claude or Codex"
            return
        }

        let items = providers.map { presentation(for: $0) }
        guard items != lastPresentation else { return }
        lastPresentation = items
        lastEmptyTitle = nil

        let title = NSMutableAttributedString()
        var tooltipLines: [String] = []

        for item in items {
            if title.length > 0 {
                title.append(NSAttributedString(string: Self.groupSeparator))
            }

            title.append(glyphAttachment(provider: item.provider, tier: item.tier))
            title.append(NSAttributedString(string: " "))

            var attributes = Self.textAttributes
            attributes[.foregroundColor] = item.tier.nsColor
            title.append(NSAttributedString(string: item.text, attributes: attributes))
            tooltipLines.append(item.tooltip)
        }

        button.image = nil
        button.attributedTitle = title
        button.toolTip = tooltipLines.joined(separator: "\n")
    }

    private func presentation(for provider: Provider) -> ProviderPresentation {
        let windows = store.snapshot(for: provider)?.headlineWindows ?? []
        let tier = UsageTier(percent: windows.lazy.map(\.percent).max() ?? 0)
        let text: String
        if store.failures[provider] != nil {
            text = "?"
        } else if windows.isEmpty {
            text = "…"
        } else {
            text = windows.map { "\(Int($0.percent.rounded()))%" }.joined(separator: "/")
        }
        return ProviderPresentation(provider: provider, tier: tier, text: text,
                                    tooltip: tooltip(for: provider, windows: windows))
    }

    private func tooltip(for provider: Provider, windows: [RateWindow]) -> String {
        var parts = [provider.displayName]
        if let failure = store.failures[provider] {
            parts.append(failure)
            return parts.joined(separator: ": ")
        }
        parts.append(contentsOf: windows.map { "\($0.label) \(Int($0.percent.rounded()))%" })
        if let budget = store.budget(for: provider) {
            parts.append("\(Fmt.amount(budget.spentMinor, unit: budget.unit)) of "
                       + "\(Fmt.amount(budget.limitMinor, unit: budget.unit))")
        }
        return parts.joined(separator: " · ")
    }

    private func glyphAttachment(provider: Provider, tier: UsageTier) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = Glyphs.image(for: provider, tier: tier)
        attachment.bounds = CGRect(x: 0, y: -4, width: Glyphs.pointSize, height: Glyphs.pointSize)
        return NSAttributedString(attachment: attachment)
    }
}

// MARK: - Click routing

/// Routes the Objective-C target/action callbacks that AppKit delivers on the main actor.
@MainActor
final class ClickRouter: NSObject {
    static let shared = ClickRouter()

    var onLeftClick: (() -> Void)?
    var onQuit: (() -> Void)?
    weak var statusItem: NSStatusItem?

    @objc func handle(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            onLeftClick?()
        }
    }

    private func showMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show Usage (⌘U)",
                                action: #selector(triggerLeftClick),
                                keyEquivalent: "u")
        toggle.keyEquivalentModifierMask = .command
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AgentUsageBar", action: #selector(triggerQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func triggerLeftClick() { onLeftClick?() }
    @objc private func triggerQuit() { onQuit?() }
}
