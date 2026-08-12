import AppKit
import Security
import UserNotifications

// MARK: - Types

/// Statuspage component states, ordered by how bad they are. Typed rather than raw
/// strings so severity ranking is total and a new state cannot silently rank as fine.
enum ComponentStatus: String, Comparable, Decodable, Sendable {
    case operational
    case underMaintenance = "under_maintenance"
    case degradedPerformance = "degraded_performance"
    case partialOutage = "partial_outage"
    case majorOutage = "major_outage"

    private var severity: Int {
        switch self {
        case .operational: return 0
        case .underMaintenance: return 1
        case .degradedPerformance: return 1
        case .partialOutage: return 2
        case .majorOutage: return 3
        }
    }

    static func < (lhs: ComponentStatus, rhs: ComponentStatus) -> Bool {
        lhs.severity < rhs.severity
    }

    var indicator: StatusIndicator {
        switch severity {
        case 0: return .none
        case 1: return .minor
        case 2: return .major
        default: return .critical
        }
    }

    var label: String {
        switch self {
        case .operational: return "operational"
        case .underMaintenance: return "maintenance"
        case .degradedPerformance: return "degraded"
        case .partialOutage: return "partial outage"
        case .majorOutage: return "major outage"
        }
    }
}

enum StatusIndicator: String {
    case none, minor, major, critical

    var nsColor: NSColor {
        switch self {
        case .none: return .systemGreen
        case .minor: return .systemYellow
        case .major: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

enum IncidentStatus: String, Decodable, Sendable {
    case investigating, identified, monitoring, resolved, postmortem, scheduled
    case inProgress = "in_progress"
    case verifying
    case completed

    var isOpen: Bool {
        switch self {
        case .resolved, .postmortem, .completed: return false
        default: return true
        }
    }

    var nsColor: NSColor {
        switch self {
        case .investigating: return .systemRed
        case .identified: return .systemOrange
        case .monitoring, .verifying: return .systemBlue
        case .resolved, .completed: return .systemGreen
        case .postmortem: return .systemGray
        case .scheduled, .inProgress: return .systemBlue
        }
    }
}

struct StatusIncident: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: IncidentStatus
    let latestUpdate: String
    let updatedAt: Date?
    let componentIDs: [String]
}

struct StatusComponent: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: ComponentStatus

    /// "Claude Console (platform.claude.com)" reads better as just "Claude Console"
    /// in the compact summary line.
    var shortName: String {
        guard let paren = name.range(of: " (") else { return name }
        return String(name[..<paren.lowerBound])
    }
}

// MARK: - Manager

/// Anthropic's status page only. Codex outages are deliberately not tracked: the
/// notification scope chosen for this build is Claude service outages.
@MainActor
final class StatusManager {
    private(set) var description: String = "All systems operational"
    private(set) var incidents: [StatusIncident] = []
    private(set) var components: [StatusComponent] = []
    private(set) var lastUpdated: Date?
    private(set) var hasFetched = false
    var onViewChange: (() -> Void)?

    private static let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!
    private static let lastIndicatorKey = "last_effective_indicator"

    private let settings: Settings
    private var isFetching = false
    private var entityTag: String?
    private var lastModified: String?

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: Filtered views

    private var trackedComponents: [StatusComponent] {
        components.filter { settings.trackedComponentIDs.contains($0.id) }
    }

    var affectedComponents: [StatusComponent] {
        trackedComponents.filter { $0.status != .operational }
    }

    var filteredIncidents: [StatusIncident] {
        incidents.filter { incident in
            guard !incident.componentIDs.isEmpty else { return true }
            return incident.componentIDs.contains { settings.trackedComponentIDs.contains($0) }
        }
    }

    /// Severity across tracked components only, so an outage in a service the user
    /// does not use never colors the dot.
    var indicator: StatusIndicator {
        trackedComponents.map(\.status).max()?.indicator ?? .none
    }

    var hasIssue: Bool {
        indicator != .none && !(filteredIncidents.isEmpty && affectedComponents.isEmpty)
    }

    var contextLine: String {
        let tracked = trackedComponents
        let names = tracked.prefix(4).map(\.shortName).joined(separator: ", ")
        let overflow = tracked.count > 4 ? " +\(tracked.count - 4)" : ""
        let summary = tracked.isEmpty ? "No services tracked" : "Tracks \(names)\(overflow)"

        if indicator == .none {
            guard let lastUpdated else { return summary }
            return "\(summary) · checked \(Fmt.relative(lastUpdated))"
        }
        let affected = affectedComponents
        if !affected.isEmpty {
            let affectedNames = affected.prefix(3).map(\.shortName).joined(separator: ", ")
            let more = affected.count > 3 ? " +\(affected.count - 3)" : ""
            return "Affects: \(affectedNames)\(more)"
        }
        guard let lastUpdated else { return "" }
        return "Checked \(Fmt.relative(lastUpdated))"
    }

    // MARK: Fetch

    func fetch() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        var request = URLRequest(
            url: Self.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let entityTag { request.setValue(entityTag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        guard let (data, response) = try? await HTTPClient.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else {
            debugLog("Status fetch failed")
            return
        }
        if http.statusCode == 304 {
            lastUpdated = Date()
            onViewChange?()
            return
        }
        guard http.statusCode == 200 else {
            debugLog("Status fetch failed with HTTP \(http.statusCode)")
            return
        }
        entityTag = http.value(forHTTPHeaderField: "ETag")
        lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        // Parsed off the main actor; only the assignments below hop back.
        let parseTask = Task.detached(priority: .utility) { Self.parse(data) }
        guard let parsed = await parseTask.value else { return }

        apply(parsed)
    }

    private struct Parsed: Sendable {
        let description: String
        let incidents: [StatusIncident]
        let components: [StatusComponent]
    }

    private struct SummaryResponse: Decodable, Sendable {
        struct Summary: Decodable, Sendable {
            let description: String
        }

        struct Incident: Decodable, Sendable {
            struct Update: Decodable, Sendable {
                let body: String?
                let createdAt: String?

                private enum CodingKeys: String, CodingKey {
                    case body
                    case createdAt = "created_at"
                }
            }

            struct ComponentReference: Decodable, Sendable {
                let id: String
            }

            let id: String
            let name: String
            let status: IncidentStatus
            let updatedAt: String?
            let incidentUpdates: [Update]
            let components: [ComponentReference]

            private enum CodingKeys: String, CodingKey {
                case id, name, status, components
                case updatedAt = "updated_at"
                case incidentUpdates = "incident_updates"
            }
        }

        struct Component: Decodable, Sendable {
            let id: String
            let name: String
            let status: ComponentStatus
        }

        let status: Summary
        let incidents: [Incident]
        let components: [Component]
    }

    /// Pure decode, deliberately off the main actor: only `apply` touches live state.
    private nonisolated static func parse(_ data: Data) -> Parsed? {
        do {
            let response = try JSONDecoder().decode(SummaryResponse.self, from: data)
            let incidents = response.incidents.compactMap { incident -> StatusIncident? in
                guard incident.status.isOpen else { return nil }
                return StatusIncident(
                    id: incident.id,
                    name: incident.name,
                    status: incident.status,
                    latestUpdate: incident.incidentUpdates.first?.body ?? "",
                    updatedAt: DateParse.iso(
                        incident.incidentUpdates.first?.createdAt ?? incident.updatedAt
                    ),
                    componentIDs: incident.components.map(\.id)
                )
            }
            let components = response.components.map {
                StatusComponent(id: $0.id, name: $0.name, status: $0.status)
            }
            return Parsed(
                description: response.status.description,
                incidents: incidents, components: components)
        } catch {
            debugLog("Status response decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func apply(_ parsed: Parsed) {
        let isFirstFetch = !hasFetched

        description = parsed.description
        incidents = parsed.incidents
        if !parsed.components.isEmpty {
            components = parsed.components
            // First real component list seen: track everything except Claude for
            // Government, which almost nobody using this app depends on.
            if !settings.hasTrackedComponentSelection {
                settings.trackedComponentIDs = Set(
                    parsed.components
                        .filter { !$0.name.localizedCaseInsensitiveContains("Government") }
                        .map(\.id)
                )
            }
        }
        lastUpdated = Date()
        hasFetched = true

        let current = indicator
        let previous = UserDefaults.standard.string(forKey: Self.lastIndicatorKey)
        if !isFirstFetch, let previous, previous != current.rawValue {
            notifyChange(to: current)
        }
        UserDefaults.standard.set(current.rawValue, forKey: Self.lastIndicatorKey)
        onViewChange?()
    }

    private func notifyChange(to indicator: StatusIndicator) {
        guard settings.statusNotificationsEnabled else { return }
        let title = indicator == .none ? "Claude is back online" : "Claude status: \(description)"
        let body =
            indicator == .none
            ? "All systems operational"
            : "Open status.claude.com for details"
        Notifier.post(title: title, body: body)
    }
}

// MARK: - Notifications

/// `NSUserNotification`, which upstream used, has been deprecated since 10.14 and no
/// longer delivers reliably.
///
/// `UNUserNotificationCenter` is the modern replacement, but macOS only grants it to
/// apps carrying an Apple-issued Team ID. This app is signed with a local self-signed
/// certificate (`TeamIdentifier=not set`), so authorization fails immediately with
/// "Notifications are not allowed for this application" — no prompt, no delivery.
/// Obtaining a Developer ID is the only real fix and is out of scope here.
///
/// So delivery falls back to `osascript`, which posts under Script Editor's own
/// notification permission. Alerts are then attributed to Script Editor rather than to
/// this app. The native path is kept and preferred, so a properly signed build starts
/// using it with no further change.
@MainActor
enum Notifier {
    private enum NativeAuthorization {
        case unchecked
        case requesting
        case authorized
        case unavailable
    }

    private static var nativeAuthorization = NativeAuthorization.unchecked

    static func prepare() {
        guard nativeAuthorization == .unchecked else { return }
        guard hasAppleTeamIdentifier else {
            nativeAuthorization = .unavailable
            return
        }
        nativeAuthorization = .requesting
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                Task { @MainActor in
                    nativeAuthorization = granted && error == nil ? .authorized : .unavailable
                    if let error {
                        debugLog(
                            "Native notifications unavailable (\(error.localizedDescription)); "
                                + "falling back to osascript delivery")
                    } else {
                        debugLog("Native notification authorization granted: \(granted)")
                    }
                }
            }
    }

    static func post(title: String, body: String) {
        if nativeAuthorization == .authorized {
            postNative(title: title, body: body)
        } else {
            postViaOSAScript(title: title, body: body)
        }
    }

    private static var hasAppleTeamIdentifier: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return false }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information) == errSecSuccess,
            let values = information as? [String: Any],
            let team = values[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            return false
        }
        return !team.isEmpty
    }

    private static func postNative(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { debugLog("Notification post failed: \(error.localizedDescription)") }
        }
    }

    /// Arguments are passed as an argv array, so no shell is involved; escaping only
    /// has to make the text a valid AppleScript string literal. Titles and bodies come
    /// from Anthropic's status page, which is not trusted input.
    private static func postViaOSAScript(title: String, body: String) {
        let script =
            "display notification \"\(appleScriptEscaped(body))\" "
            + "with title \"\(appleScriptEscaped(title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            debugLog("osascript notification failed: \(error.localizedDescription)")
        }
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        // Backslashes first, or the escapes introduced below get double-escaped.
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
