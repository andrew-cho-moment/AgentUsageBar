import AppKit
import Carbon

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var settings: Settings!
    private var store: AppStore!
    private var statusManager: StatusManager!
    private var menuBar: MenuBarController!
    private var popover: NSPopover?
    private var usageController: UsageViewController?

    /// The Carbon handler is installed once for the process lifetime. Upstream
    /// reinstalled it on every enable, so toggling the shortcut off and on left two
    /// handlers registered and one keypress fired the toggle twice.
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    private var pollTimer: Timer?
    /// A transient popover dismisses itself on the mouse-down that precedes our own
    /// button action, so without this the click that should close it reopens it.
    private var lastPopoverClose: Date?

    private static let pollInterval: TimeInterval = 1_800

    private enum RefreshContext {
        case background
        case foreground
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = Settings()
        store = AppStore(settings: settings)
        statusManager = StatusManager(settings: settings)

        menuBar = MenuBarController(
            store: store,
            onLeftClick: { [weak self] in self?.togglePopover() },
            onQuit: { NSApp.terminate(nil) }
        )

        installHotKeyHandler()
        connectModelChanges()
        applyAppearance()
        if settings.shortcutEnabled { registerHotKey() }
        if settings.statusNotificationsEnabled { Notifier.prepare() }
        observeSystemAppearanceChanges()

        startPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterHotKey()
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
            self.hotKeyHandler = nil
        }
        pollTimer?.invalidate()
    }

    // MARK: Polling

    private func startPolling() {
        refresh(.background)
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(.background) }
        }
        // The status item stays visible while the popover is closed, but half-hour
        // freshness is enough until the user opens it. Wide tolerance lets macOS fold
        // this work into an existing wakeup.
        timer.tolerance = 300
        pollTimer = timer
    }

    private func refresh(_ context: RefreshContext) {
        let refreshStatus = context == .foreground || settings.statusNotificationsEnabled
        Task { [weak self] in
            guard let self else { return }
            // Independent endpoints; serialising them only lengthened the window in
            // which the menu bar shows stale numbers.
            async let usage: Void = self.store.refresh()
            if refreshStatus { await self.statusManager.fetch() }
            await usage
        }
    }

    // MARK: Appearance

    private func applyAppearance() {
        let systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let appearance = settings.appearanceMode.resolved(systemIsDark: systemIsDark)
        NSApp.appearance = appearance
        // The popover does not reliably restyle from NSApp.appearance once created.
        popover?.appearance = appearance
    }

    private func observeSystemAppearanceChanges() {
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let delegate = self else { return }
            // The defaults key can lag the notification; re-resolve a tick later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak delegate] in
                MainActor.assumeIsolated { delegate?.applyAppearance() }
            }
        }
    }

    private func connectModelChanges() {
        settings.onAppearanceChange = { [weak self] in self?.applyAppearance() }
        settings.onShortcutChange = { [weak self] enabled in
            guard let self else { return }
            if enabled { self.registerHotKey() } else { self.unregisterHotKey() }
        }
        settings.onNotificationChange = { enabled in
            guard enabled else { return }
            Notifier.prepare()
            Task { [weak self] in await self?.statusManager.fetch() }
        }
        settings.onBudgetChange = { [weak self] in self?.menuBar.setNeedsRender() }
        store.onMenuBarChange = { [weak self] in self?.menuBar.setNeedsRender() }
    }

    // MARK: Popover

    func togglePopover() {
        debugLog("toggle requested: isShown=\(popover?.isShown == true)")
        if popover?.isShown == true {
            popover?.performClose(nil)
            return
        }
        // Distinguish "user clicked to dismiss" from "user clicked to open": the
        // dismissal already happened microseconds ago on mouse-down.
        if let lastPopoverClose, Date().timeIntervalSince(lastPopoverClose) < 0.2 { return }
        showPopover()
    }

    private func showPopover() {
        guard let button = menuBarButton else { return }
        let popover = makePopover(availableHeight: Self.availableHeight(for: button))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        if debugLoggingEnabled {
            // The frame is only final after AppKit has measured and resized it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.logPopoverGeometry() }
            }
        }

        // Opening is the only moment fresh detail is immediately useful. The refresh
        // coalesces with an in-flight launch or timer refresh.
        refresh(.foreground)
    }

    /// The AppKit controller exists only while visible. Closed-state refreshes update
    /// plain model values and the status item without retaining any popover view tree.
    private func makePopover(availableHeight: CGFloat) -> NSPopover {
        if let popover { return popover }

        let controller = UsageViewController(
            store: store,
            statusManager: statusManager,
            settings: settings,
            maximumHeight: availableHeight,
            onRefresh: { [weak self] in self?.refresh(.foreground) }
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = controller
        popover.appearance = settings.appearanceMode.resolved(
            systemIsDark:
                UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
        controller.onContentSizeChange = { [weak popover] size in
            popover?.contentSize = size
        }
        store.onViewChange = { [weak controller] in controller?.reload() }
        statusManager.onViewChange = { [weak controller] in controller?.reload() }
        settings.onViewChange = { [weak controller] in controller?.reload() }
        controller.prepare()
        self.usageController = controller
        self.popover = popover
        return popover
    }

    /// Room below the menu bar on the screen the status item lives on, so the popover is
    /// capped by the display it opens on rather than by a guess.
    private static func availableHeight(for button: NSStatusBarButton) -> CGFloat {
        guard let screen = button.window?.screen ?? NSScreen.main else { return 600 }
        return max(200, screen.visibleFrame.height - 16)
    }

    private func logPopoverGeometry() {
        guard let popover, let window = popover.contentViewController?.view.window else {
            debugLog("popover: no window")
            return
        }
        let frame = window.frame
        guard let screen = menuBarButton?.window?.screen else {
            debugLog("popover frame=\(frame), no screen")
            return
        }
        let barBottom = screen.visibleFrame.maxY
        debugLog(
            "popover frame=\(frame) content=\(popover.contentSize) "
                + "menuBarBottom=\(barBottom) screen=\(screen.frame) "
                + "overTop=\(Int(frame.maxY - barBottom)) "
                + "underBottom=\(Int(screen.frame.minY - frame.minY))")
    }

    private var menuBarButton: NSStatusBarButton? {
        ClickRouter.shared.statusItem?.button
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        // Releasing AppKit objects from inside their close callback is unsafe. The next
        // run-loop turn is past that callback and frees the otherwise-idle view tree.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.popover?.isShown != true else { return }
                self.store.onViewChange = nil
                self.statusManager.onViewChange = nil
                self.settings.onViewChange = nil
                self.popover?.contentViewController = nil
                self.usageController = nil
                self.popover = nil
            }
        }
    }

    // MARK: Global shortcut

    /// Carbon hot keys need no Accessibility permission — that is only required for
    /// CGEventTap and NSEvent global monitors — so none is requested.
    private func installHotKeyHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { delegate.togglePopover() }
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    private func registerHotKey() {
        guard hotKeyRef == nil else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4147_5542), id: 1)  // 'AGUB'
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_U), UInt32(cmdKey), hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        // Report the real outcome rather than guessing at a permissions cause.
        let hasConflict = status != noErr
        if store.shortcutConflict != hasConflict {
            store.shortcutConflict = hasConflict
        }
        if status != noErr {
            hotKeyRef = nil
            debugLog("RegisterEventHotKey failed with status \(status)")
        }
    }

    private func unregisterHotKey() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
        if store?.shortcutConflict == true { store.shortcutConflict = false }
    }
}
