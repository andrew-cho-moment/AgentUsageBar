import AppKit

// MARK: - Glyphs

/// Provider marks drawn as paths and cached per severity color. Upstream re-rendered
/// its icon on every poll for one of exactly three colors.
enum Glyphs {
    private static let size = NSSize(width: 14, height: 14)
    private static var cache: [String: NSImage] = [:]

    static func image(for provider: Provider, tier: UsageTier) -> NSImage {
        let key = "\(provider.rawValue)/\(tier)"
        if let cached = cache[key] { return cached }
        let image = draw(provider: provider, color: tier.nsColor)
        cache[key] = image
        return image
    }

    private static func draw(provider: Provider, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        color.setStroke()
        switch provider {
        case .claude: sparkPath().fill()
        case .codex:  promptPath().stroke()
        }
        image.unlockFocus()
        image.isTemplate = false   // color carries the severity signal
        return image
    }

    /// Anthropic's radiating mark, scaled from a 16pt design to 14pt.
    private static func sparkPath() -> NSBezierPath {
        let points: [(CGFloat, CGFloat)] = [
            (8, 1), (9, 6), (13, 3), (10, 7), (15, 8), (10, 9), (13, 13), (9, 10),
            (8, 15), (7, 10), (3, 13), (6, 9), (1, 8), (6, 7), (3, 3), (7, 6),
        ]
        let scale: CGFloat = 14.0 / 16.0
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let scaled = NSPoint(x: point.0 * scale, y: point.1 * scale)
            if index == 0 { path.move(to: scaled) } else { path.line(to: scaled) }
        }
        path.close()
        return path
    }

    /// A shell prompt, the Codex CLI's own motif. OpenAI's hexagonal knot was tried
    /// first and collapses into a blob at 14pt, where the interlacing that carries the
    /// shape is smaller than a pixel.
    private static func promptPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 2.8, y: 9.8))
        path.line(to: NSPoint(x: 6.2, y: 7.0))
        path.line(to: NSPoint(x: 2.8, y: 4.2))
        path.move(to: NSPoint(x: 7.6, y: 3.9))
        path.line(to: NSPoint(x: 11.5, y: 3.9))
        return path
    }
}

// MARK: - Controller

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let store: AppStore

    private var renderScheduled = false

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
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "—")
            button.toolTip = "Not signed in to Claude or Codex"
            return
        }

        let title = NSMutableAttributedString()
        var tooltipLines: [String] = []

        for provider in providers {
            if title.length > 0 {
                title.append(NSAttributedString(string: Self.groupSeparator))
            }

            let snapshot = store.snapshot(for: provider)
            let windows = snapshot?.headlineWindows ?? []
            let worst = windows.map(\.percent).max() ?? 0
            let tier = UsageTier(percent: worst)

            title.append(glyphAttachment(provider: provider, tier: tier))
            title.append(NSAttributedString(string: " "))

            let text: String
            if store.failures[provider] != nil {
                text = "?"
            } else if windows.isEmpty {
                text = "…"
            } else {
                text = windows.map { "\(Int($0.percent.rounded()))%" }.joined(separator: "/")
            }

            title.append(NSAttributedString(string: text, attributes: [
                .foregroundColor: tier.nsColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            ]))

            tooltipLines.append(tooltip(for: provider, windows: windows))
        }

        button.image = nil
        button.attributedTitle = title
        button.toolTip = tooltipLines.joined(separator: "\n")
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
        attachment.bounds = CGRect(x: 0, y: -3, width: 14, height: 14)
        return NSAttributedString(attachment: attachment)
    }
}

// MARK: - Click routing

/// `NSStatusBarButton` needs an ObjC target/action pair, which an actor-isolated class
/// cannot supply directly.
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
