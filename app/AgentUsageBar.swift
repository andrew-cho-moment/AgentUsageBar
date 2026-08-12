import SwiftUI
import AppKit
import Carbon
import Combine

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
    private var popover: NSPopover!
    /// Held with its concrete type so the popover can be sized from SwiftUI's own
    /// measurement before it is shown.
    private var hosting: NSHostingController<UsageView>!

    /// The Carbon handler is installed once for the process lifetime. Upstream
    /// reinstalled it on every enable, so toggling the shortcut off and on left two
    /// handlers registered and one keypress fired the toggle twice.
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    private var cancellables: Set<AnyCancellable> = []
    private var timers: [Timer] = []
    /// A transient popover dismisses itself on the mouse-down that precedes our own
    /// button action, so without this the click that should close it reopens it.
    private var lastPopoverClose: Date?

    private static let pollInterval: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = Settings()
        store = AppStore(settings: settings)
        statusManager = StatusManager(settings: settings)

        hosting = NSHostingController(rootView: UsageView(
            store: store,
            statusManager: statusManager,
            settings: settings
        ))

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hosting

        menuBar = MenuBarController(
            store: store,
            onLeftClick: { [weak self] in self?.togglePopover() },
            onQuit: { NSApp.terminate(nil) }
        )

        applyAppearance()
        observeAppearanceChanges()
        observeStoreChanges()

        Notifier.requestAuthorization()

        installHotKeyHandler()
        if settings.shortcutEnabled { registerHotKey() }
        observeShortcutSetting()

        startPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterHotKey()
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
            self.hotKeyHandler = nil
        }
        timers.forEach { $0.invalidate() }
    }

    // MARK: Polling

    private func startPolling() {
        refreshAll()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        // A usage percentage does not need second-accurate scheduling, and the slack lets
        // the OS wake this timer alongside others instead of on its own.
        timer.tolerance = 30
        timers.append(timer)
    }

    private func refreshAll() {
        Task { [weak self] in
            guard let self else { return }
            // Independent endpoints; serialising them only lengthened the window in
            // which the menu bar shows stale numbers.
            async let usage: Void = self.store.refresh()
            async let status: Void = self.statusManager.fetch()
            _ = await (usage, status)
            self.menuBar.setNeedsRender()
        }
    }

    // MARK: Appearance

    private func applyAppearance() {
        let systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let appearance = settings.appearanceMode.resolved(systemIsDark: systemIsDark)
        NSApp.appearance = appearance
        // The popover does not reliably restyle from NSApp.appearance once created.
        popover.appearance = appearance
    }

    private func observeAppearanceChanges() {
        settings.$appearanceMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &cancellables)

        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // The defaults key can lag the notification; re-resolve a tick later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { self?.applyAppearance() }
            }
        }
    }

    private func observeStoreChanges() {
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.menuBar.setNeedsRender() }
            .store(in: &cancellables)
    }

    private func observeShortcutSetting() {
        settings.$shortcutEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.registerHotKey() } else { self.unregisterHotKey() }
            }
            .store(in: &cancellables)
    }

    // MARK: Popover

    func togglePopover() {
        debugLog("toggle requested: isShown=\(popover.isShown)")
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Distinguish "user clicked to dismiss" from "user clicked to open": the
        // dismissal already happened microseconds ago on mouse-down.
        if let lastPopoverClose, Date().timeIntervalSince(lastPopoverClose) < 0.2 { return }
        showPopover()
    }

    private func showPopover() {
        guard let button = menuBarButton else { return }
        store.notePopoverOpened(availableHeight: Self.availableHeight(for: button))
        sizePopoverToContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        if debugLoggingEnabled {
            // The frame is only final after SwiftUI has measured and resized it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.logPopoverGeometry() }
            }
        }

        // Opening is the moment the numbers matter most; refresh if they are stale.
        if let lastUpdated = store.lastUpdated, Date().timeIntervalSince(lastUpdated) > 60 {
            refreshAll()
        }
    }

    /// NSPopover reads `contentSize` to choose where on screen it sits. SwiftUI measures
    /// its content only once the view lays out, so showing first and measuring second
    /// left AppKit growing the window upward from an origin fixed for the old, smaller
    /// size — pushing the top off the screen. Settling the size first means the position
    /// is computed from the height the popover will actually have.
    private func sizePopoverToContent() {
        hosting.view.layoutSubtreeIfNeeded()
        popover.contentSize = hosting.sizeThatFits(
            in: CGSize(width: UsageView.width, height: CGFloat.greatestFiniteMagnitude)
        )
    }

    /// Room below the menu bar on the screen the status item lives on, so the popover is
    /// capped by the display it opens on rather than by a guess.
    private static func availableHeight(for button: NSStatusBarButton) -> CGFloat {
        guard let screen = button.window?.screen ?? NSScreen.main else { return 600 }
        return max(200, screen.visibleFrame.height - 16)
    }

    private func logPopoverGeometry() {
        guard let window = popover.contentViewController?.view.window else {
            debugLog("popover: no window")
            return
        }
        let frame = window.frame
        guard let screen = menuBarButton?.window?.screen else {
            debugLog("popover frame=\(frame), no screen")
            return
        }
        let barBottom = screen.visibleFrame.maxY
        debugLog("popover frame=\(frame) content=\(popover.contentSize) "
               + "menuBarBottom=\(barBottom) screen=\(screen.frame) "
               + "overTop=\(Int(frame.maxY - barBottom)) "
               + "underBottom=\(Int(screen.frame.minY - frame.minY))")
    }

    private var menuBarButton: NSStatusBarButton? {
        ClickRouter.shared.statusItem?.button
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }

    // MARK: Global shortcut

    /// Carbon hot keys need no Accessibility permission — that is only required for
    /// CGEventTap and NSEvent global monitors — so none is requested.
    private func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { delegate.togglePopover() }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    private func registerHotKey() {
        guard hotKeyRef == nil else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x41475542), id: 1)  // 'AGUB'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_U), UInt32(cmdKey), hotKeyID,
                                        GetApplicationEventTarget(), 0, &hotKeyRef)
        // Report the real outcome rather than guessing at a permissions cause.
        store.shortcutConflict = status != noErr
        if status != noErr {
            hotKeyRef = nil
            debugLog("RegisterEventHotKey failed with status \(status)")
        }
    }

    private func unregisterHotKey() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
        store?.shortcutConflict = false
    }
}
