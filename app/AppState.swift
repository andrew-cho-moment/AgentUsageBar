import AppKit
import ServiceManagement

// MARK: - Settings

enum AppearanceMode: String, CaseIterable {
    case system, dark, light

    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    /// Resolves to a concrete appearance. Every mode gets an explicit one so all three
    /// render through the same path: inherited vibrant rendering shades colors
    /// differently, which used to make System and Dark look unlike each other.
    func resolved(systemIsDark: Bool) -> NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return NSAppearance(named: systemIsDark ? .darkAqua : .aqua)
        }
    }
}

@MainActor
final class Settings {
    private enum Key {
        static let statusNotifications = "status_notifications_enabled"
        static let shortcutEnabled = "shortcut_enabled"
        static let appearanceMode = "appearance_mode"
        static let trackedComponents = "tracked_component_ids"
        static func budgetOverride(_ provider: Provider) -> String {
            "budget_override_minor_\(provider.rawValue)"
        }
    }

    private let defaults = UserDefaults.standard
    var onAppearanceChange: (() -> Void)?
    var onShortcutChange: ((Bool) -> Void)?
    var onNotificationChange: ((Bool) -> Void)?
    var onBudgetChange: (() -> Void)?
    var onViewChange: (() -> Void)?

    var statusNotificationsEnabled: Bool {
        didSet {
            defaults.set(statusNotificationsEnabled, forKey: Key.statusNotifications)
            onNotificationChange?(statusNotificationsEnabled)
            onViewChange?()
        }
    }

    var shortcutEnabled: Bool {
        didSet {
            defaults.set(shortcutEnabled, forKey: Key.shortcutEnabled)
            onShortcutChange?(shortcutEnabled)
            onViewChange?()
        }
    }

    var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: Key.appearanceMode)
            onAppearanceChange?()
            onViewChange?()
        }
    }

    var trackedComponentIDs: Set<String> {
        didSet {
            defaults.set(Array(trackedComponentIDs), forKey: Key.trackedComponents)
            onViewChange?()
        }
    }

    /// Fills in a monthly limit the provider does not report. Never a spend figure.
    var budgetOverrideMinor: [Provider: Int] {
        didSet {
            for provider in Provider.allCases {
                let key = Key.budgetOverride(provider)
                if let value = budgetOverrideMinor[provider] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            onBudgetChange?()
            onViewChange?()
        }
    }

    /// Read only when Settings is visible. Startup has no reason to initialize the
    /// ServiceManagement client for a control the user may never open.
    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    init() {
        // Absent keys default to on for notifications and the shortcut; a stored
        // `false` must survive, so presence is checked rather than relying on
        // UserDefaults' bool-returns-false-when-missing behavior.
        statusNotificationsEnabled =
            defaults.object(forKey: Key.statusNotifications) as? Bool ?? true
        shortcutEnabled = defaults.object(forKey: Key.shortcutEnabled) as? Bool ?? true
        appearanceMode =
            AppearanceMode(rawValue: defaults.string(forKey: Key.appearanceMode) ?? "")
            ?? .system
        trackedComponentIDs = Set(defaults.array(forKey: Key.trackedComponents) as? [String] ?? [])

        var overrides: [Provider: Int] = [:]
        for provider in Provider.allCases {
            if let value = defaults.object(forKey: Key.budgetOverride(provider)) as? Int, value > 0
            {
                overrides[provider] = value
            }
        }
        budgetOverrideMinor = overrides

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
        onViewChange?()
    }
}

// MARK: - Store

@MainActor
final class AppStore {
    private(set) var snapshots: [Provider: ProviderSnapshot] = [:]
    private(set) var failures: [Provider: String] = [:]
    private(set) var signedIn: Set<Provider> = []
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?

    /// Set when the system refuses to register ⌘U, which in practice means another app
    /// already owns it. Reporting the real failure beats guessing at a cause.
    var shortcutConflict = false {
        didSet { onViewChange?() }
    }
    var onMenuBarChange: (() -> Void)?
    var onViewChange: (() -> Void)?

    let settings: Settings

    private let providers: [Provider: any UsageProvider] = [
        .claude: ClaudeProvider(),
        .codex: CodexProvider(),
    ]

    init(settings: Settings) {
        self.settings = settings
    }

    /// Ordered for display: Claude first, then Codex, skipping providers not signed in.
    var visibleProviders: [Provider] {
        Provider.allCases.filter { signedIn.contains($0) }
    }

    func snapshot(for provider: Provider) -> ProviderSnapshot? { snapshots[provider] }

    func budget(for provider: Provider) -> Budget? {
        snapshots[provider]?.resolvedBudget(
            overrideLimitMinor: settings.budgetOverrideMinor[provider])
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        onViewChange?()

        let results = await withTaskGroup(
            of: (Provider, Result<ProviderSnapshot, Error>).self,
            returning: [(Provider, Result<ProviderSnapshot, Error>)].self
        ) { group in
            // Fetching is also the cheapest sign-in check because each provider already
            // has to load its credential. A separate probe doubled every credential read.
            for provider in Provider.allCases {
                guard let source = providers[provider] else { continue }
                group.addTask {
                    do { return (provider, .success(try await source.fetch())) } catch {
                        return (provider, .failure(error))
                    }
                }
            }
            var collected: [(Provider, Result<ProviderSnapshot, Error>)] = []
            collected.reserveCapacity(Provider.allCases.count)
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (provider, result) in results {
            switch result {
            case .success(let snapshot):
                signedIn.insert(provider)
                snapshots[provider] = snapshot
                failures[provider] = nil
                debugLog("\(provider.displayName): \(snapshot.windows.count) window(s)")
            case .failure(let error):
                if case .notLoggedIn = error as? UsageError {
                    signedIn.remove(provider)
                    snapshots[provider] = nil
                    failures[provider] = nil
                    continue
                }
                guard signedIn.contains(provider) else { continue }
                let message =
                    (error as? UsageError)?.errorDescription
                    ?? error.localizedDescription
                failures[provider] = message
                debugLog("\(provider.displayName) fetch failed: \(message)")
            }
        }
        lastUpdated = Date()
        isRefreshing = false
        onMenuBarChange?()
        onViewChange?()
    }
}
