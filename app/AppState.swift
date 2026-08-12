import SwiftUI
import ServiceManagement

// MARK: - Settings

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .dark:   return "Dark"
        case .light:  return "Light"
        }
    }

    /// Resolves to a concrete appearance. Every mode gets an explicit one so all three
    /// render through the same path: inherited vibrant rendering shades colors
    /// differently, which used to make System and Dark look unlike each other.
    func resolved(systemIsDark: Bool) -> NSAppearance? {
        switch self {
        case .dark:   return NSAppearance(named: .darkAqua)
        case .light:  return NSAppearance(named: .aqua)
        case .system: return NSAppearance(named: systemIsDark ? .darkAqua : .aqua)
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    private enum Key {
        static let statusNotifications = "status_notifications_enabled"
        static let shortcutEnabled     = "shortcut_enabled"
        static let appearanceMode      = "appearance_mode"
        static let trackedComponents   = "tracked_component_ids"
        static func budgetOverride(_ provider: Provider) -> String {
            "budget_override_minor_\(provider.rawValue)"
        }
    }

    private let defaults = UserDefaults.standard

    @Published var statusNotificationsEnabled: Bool {
        didSet { defaults.set(statusNotificationsEnabled, forKey: Key.statusNotifications) }
    }

    @Published var shortcutEnabled: Bool {
        didSet { defaults.set(shortcutEnabled, forKey: Key.shortcutEnabled) }
    }

    @Published var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Key.appearanceMode) }
    }

    @Published var trackedComponentIDs: Set<String> {
        didSet { defaults.set(Array(trackedComponentIDs), forKey: Key.trackedComponents) }
    }

    /// Fills in a monthly limit the provider does not report. Never a spend figure.
    @Published var budgetOverrideMinor: [Provider: Int] {
        didSet {
            for provider in Provider.allCases {
                let key = Key.budgetOverride(provider)
                if let value = budgetOverrideMinor[provider] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    /// Reflects the real login-item state rather than a stored bool that can drift.
    @Published var openAtLogin: Bool

    init() {
        // Absent keys default to on for notifications and the shortcut; a stored
        // `false` must survive, so presence is checked rather than relying on
        // UserDefaults' bool-returns-false-when-missing behavior.
        statusNotificationsEnabled = defaults.object(forKey: Key.statusNotifications) as? Bool ?? true
        shortcutEnabled = defaults.object(forKey: Key.shortcutEnabled) as? Bool ?? true
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Key.appearanceMode) ?? "")
            ?? .system
        trackedComponentIDs = Set(defaults.array(forKey: Key.trackedComponents) as? [String] ?? [])

        var overrides: [Provider: Int] = [:]
        for provider in Provider.allCases {
            if let value = defaults.object(forKey: Key.budgetOverride(provider)) as? Int, value > 0 {
                overrides[provider] = value
            }
        }
        budgetOverrideMinor = overrides

        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    var hasTrackedComponentSelection: Bool { !trackedComponentIDs.isEmpty }

    func toggleComponent(_ id: String) {
        if trackedComponentIDs.contains(id) {
            trackedComponentIDs.remove(id)
        } else {
            trackedComponentIDs.insert(id)
        }
    }

    /// Registers or unregisters the real macOS login item, then re-reads the result so
    /// a failure is visible in the checkbox instead of being silently assumed.
    func applyLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            debugLog("Login item change failed: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Store

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var snapshots: [Provider: ProviderSnapshot] = [:]
    @Published private(set) var failures: [Provider: String] = [:]
    @Published private(set) var signedIn: Set<Provider> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    /// Set when the system refuses to register ⌘U, which in practice means another app
    /// already owns it. Reporting the real failure beats guessing at a cause.
    @Published var shortcutConflict = false

    /// Bumped each time the popover opens. The hosting view outlives any single
    /// showing, so without this the scroll position persists between openings and the
    /// popover can appear already scrolled past the first provider.
    @Published private(set) var openToken = UUID()

    func notePopoverOpened() { openToken = UUID() }

    let settings: Settings

    private let providers: [Provider: any UsageProvider] = [
        .claude: ClaudeProvider(),
        .codex: CodexProvider(),
    ]

    init(settings: Settings) {
        self.settings = settings
        refreshSignInState()
    }

    /// Providers appear and disappear with their local credential, so this is
    /// re-checked every cycle rather than only at launch.
    func refreshSignInState() {
        signedIn = Set(providers.filter { $0.value.isSignedIn() }.keys)
        for provider in Provider.allCases where !signedIn.contains(provider) {
            snapshots[provider] = nil
            failures[provider] = nil
        }
    }

    /// Ordered for display: Claude first, then Codex, skipping providers not signed in.
    var visibleProviders: [Provider] {
        Provider.allCases.filter { signedIn.contains($0) }
    }

    func snapshot(for provider: Provider) -> ProviderSnapshot? { snapshots[provider] }

    func budget(for provider: Provider) -> Budget? {
        snapshots[provider]?.resolvedBudget(overrideLimitMinor: settings.budgetOverrideMinor[provider])
    }

    func refresh() async {
        refreshSignInState()
        guard !signedIn.isEmpty else {
            lastUpdated = Date()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        // Each provider is independent; one being down must not hide the other.
        await withTaskGroup(of: (Provider, Result<ProviderSnapshot, Error>).self) { group in
            for provider in signedIn {
                guard let source = providers[provider] else { continue }
                group.addTask {
                    do { return (provider, .success(try await source.fetch())) }
                    catch { return (provider, .failure(error)) }
                }
            }
            for await (provider, result) in group {
                switch result {
                case .success(let snapshot):
                    snapshots[provider] = snapshot
                    failures[provider] = nil
                    debugLog("\(provider.displayName): \(snapshot.windows.count) window(s)")
                case .failure(let error):
                    let message = (error as? UsageError)?.errorDescription
                        ?? error.localizedDescription
                    failures[provider] = message
                    debugLog("\(provider.displayName) fetch failed: \(message)")
                }
            }
        }
        lastUpdated = Date()
    }
}
