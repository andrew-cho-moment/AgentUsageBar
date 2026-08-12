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
        case .codex:  chevronPath().stroke()
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

    /// Codex ships no menu bar app and therefore no mark to echo; the CLI's
    /// angle-bracket motif reads clearly at this size.
    private static func chevronPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 5.5, y: 10.5))
        path.line(to: NSPoint(x: 2.0, y: 7.0))
        path.line(to: NSPoint(x: 5.5, y: 3.5))
        path.move(to: NSPoint(x: 8.5, y: 10.5))
        path.line(to: NSPoint(x: 12.0, y: 7.0))
        path.line(to: NSPoint(x: 8.5, y: 3.5))
        return path
    }
}

// MARK: - Controller

@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem
    private let store: AppStore
    private let onLeftClick: () -> Void
    private let onQuit: () -> Void

    /// True when the position hint was accepted into our own defaults, meaning we are
    /// most likely sitting beside the vendor's item and can drop our copy of its logo.
    private var parkedNextTo: Set<Provider> = []

    /// Vendor apps currently showing a menu bar item of their own, tracked from workspace
    /// notifications. Each `NSRunningApplication` lookup crosses into LaunchServices, so
    /// rendering reads this instead of asking again.
    private var runningVendors: Set<Provider> = []

    private var renderScheduled = false

    private static let autosaveName = "AgentUsageBar"
    private static let positionKeyPrefix = "NSStatusItem Preferred Position "
    /// Undocumented but long-standing: AppKit persists status item placement here.
    private static let vendorPositionKey = "NSStatusItem Preferred Position Item-0"
    /// Larger values sit further left, so asking for one step below the vendor's puts us
    /// immediately to its right. Copying the vendor's value verbatim left the tie for
    /// AppKit to break, and it put us on the left, so our Codex mark read to the left of
    /// Claude Desktop's logo.
    private static let tieBreakRightward = 1.0

    init(store: AppStore, onLeftClick: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.store = store
        self.onLeftClick = onLeftClick
        self.onQuit = onQuit

        runningVendors = Self.currentVendors()
        // The position hint is consulted when the item is created, so it must be
        // written first.
        Self.applyAdjacencyHints(for: runningVendors, into: &parkedNextTo)

        statusItem = Self.makeStatusItem()
        attachHandlers()
        observeVendorApps()
        render()
    }

    private static func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = autosaveName
        return item
    }

    private func attachHandlers() {
        guard let button = statusItem.button else { return }
        button.target = ClickRouter.shared
        button.action = #selector(ClickRouter.handle(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        ClickRouter.shared.onLeftClick = onLeftClick
        ClickRouter.shared.onQuit = onQuit
        ClickRouter.shared.statusItem = statusItem
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

    /// One compact group per signed-in provider: its mark, when the vendor's own app
    /// is not already showing one, followed by a percentage per headline window.
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
                title.append(NSAttributedString(string: "  "))
            }

            let snapshot = store.snapshot(for: provider)
            let windows = snapshot?.headlineWindows ?? []
            let worst = windows.map(\.percent).max() ?? 0
            let tier = UsageTier(percent: worst)

            if shouldShowGlyph(for: provider) {
                title.append(glyphAttachment(provider: provider, tier: tier))
                title.append(NSAttributedString(string: " "))
            }

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

            tooltipLines.append(tooltip(for: provider, snapshot: snapshot, windows: windows))
        }

        button.image = nil
        button.attributedTitle = title
        button.toolTip = tooltipLines.joined(separator: "\n")
    }

    private func tooltip(for provider: Provider,
                         snapshot: ProviderSnapshot?,
                         windows: [RateWindow]) -> String {
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
        _ = snapshot
        return parts.joined(separator: " · ")
    }

    private func glyphAttachment(provider: Provider, tier: UsageTier) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = Glyphs.image(for: provider, tier: tier)
        attachment.bounds = CGRect(x: 0, y: -3, width: 14, height: 14)
        return NSAttributedString(attachment: attachment)
    }

    // MARK: Adaptive logo

    /// Hide our mark only when the vendor's own item is on screen *and* we managed to
    /// park beside it. If either is false the number would be orphaned without a mark,
    /// so the mark stays.
    private func shouldShowGlyph(for provider: Provider) -> Bool {
        guard provider.vendorMenuBarBundleID != nil else { return true }
        guard parkedNextTo.contains(provider) else { return true }
        return !runningVendors.contains(provider)
    }

    private static func currentVendors() -> Set<Provider> {
        var vendors: Set<Provider> = []
        for provider in Provider.allCases {
            guard let bundleID = provider.vendorMenuBarBundleID,
                  !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            else { continue }
            vendors.insert(provider)
        }
        return vendors
    }

    /// Every app launch on the system posts here, so the vendor check happens before any
    /// work rather than after a full render.
    private func observeVendorApps() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier,
                      Provider.allCases.contains(where: { $0.vendorMenuBarBundleID == bundleID })
                else { return }
                MainActor.assumeIsolated { self?.vendorSetChanged() }
            }
        }
    }

    /// A status item reads its slot only when it is created, so following a vendor app
    /// that launched after us means building a new item, not moving the one we have.
    private func vendorSetChanged() {
        let vendors = Self.currentVendors()
        guard vendors != runningVendors else { return }
        runningVendors = vendors

        if vendors.isEmpty {
            // Nothing left to sit beside. Staying put is harmless once our mark returns.
            parkedNextTo = []
        } else {
            // The outgoing item's slot is written back to defaults as it goes, so it has
            // to be gone before the new hint is placed.
            NSStatusBar.system.removeStatusItem(statusItem)
            parkedNextTo = []
            Self.applyAdjacencyHints(for: vendors, into: &parkedNextTo)
            statusItem = Self.makeStatusItem()
            attachHandlers()
        }
        render()
    }

    // MARK: Adjacency

    /// Reads each vendor app's saved slot from its own preferences domain — legible
    /// because this app is unsandboxed, and needing no Accessibility permission — then
    /// asks AppKit for the same neighbourhood. The key is undocumented and the position
    /// is advisory, so this is strictly best-effort.
    private static func applyAdjacencyHints(for vendors: Set<Provider>,
                                            into parked: inout Set<Provider>) {
        for provider in Provider.allCases {
            guard vendors.contains(provider),
                  let bundleID = provider.vendorMenuBarBundleID
            else { continue }
            // A vendor that launched after us wrote its slot after we last looked, and
            // the cached copy of its domain would still be empty.
            CFPreferencesAppSynchronize(bundleID as CFString)
            guard let position = CFPreferencesCopyAppValue(vendorPositionKey as CFString,
                                                          bundleID as CFString) as? NSNumber
            else { continue }

            let slot = position.doubleValue - tieBreakRightward
            UserDefaults.standard.set(slot, forKey: positionKeyPrefix + autosaveName)
            parked.insert(provider)
            debugLog("Parking right of \(bundleID) (\(position.doubleValue)) at \(slot)")
            // One status item can only sit in one place; the first vendor found wins.
            break
        }
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
