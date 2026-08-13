import Foundation

enum StatusFetchIndicator: String, Sendable {
    case none, minor, major, critical
}

enum StatusComponentState: String, Decodable, Sendable {
    case operational
    case underMaintenance = "under_maintenance"
    case degradedPerformance = "degraded_performance"
    case partialOutage = "partial_outage"
    case majorOutage = "major_outage"

    var severity: Int {
        switch self {
        case .operational: return 0
        case .underMaintenance, .degradedPerformance: return 1
        case .partialOutage: return 2
        case .majorOutage: return 3
        }
    }
}

struct StatusFetchResult: Sendable {
    let indicator: StatusFetchIndicator
    let description: String
    let context: String
    let fetchedAt: Date
    let components: [StatusFetchComponent]
}

struct StatusFetchComponent: Sendable {
    let id: String
    let name: String
    let status: StatusComponentState
    let tracked: Bool
}

enum StatusFetcher {
    private static let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!
    private static let defaults = UserDefaults(suiteName: "com.andrewcho.agentusagebar")!

    private struct SummaryResponse: Decodable, Sendable {
        struct Summary: Decodable, Sendable { let description: String }
        struct Component: Decodable, Sendable {
            let id: String
            let name: String
            let status: StatusComponentState
        }

        let status: Summary
        let components: [Component]
    }

    static func fetch() async -> StatusFetchResult? {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await HTTPClient.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200,
            let summary = try? JSONDecoder().decode(SummaryResponse.self, from: data)
        else { return nil }

        var tracked = Set(defaults.stringArray(forKey: "tracked_component_ids") ?? [])
        if tracked.isEmpty {
            tracked = Set(
                summary.components
                    .filter { !$0.name.localizedCaseInsensitiveContains("Government") }
                    .map(\.id))
            defaults.set(Array(tracked), forKey: "tracked_component_ids")
        }

        let trackedComponents = summary.components.filter { tracked.contains($0.id) }
        let affected = trackedComponents.filter { $0.status != .operational }
        let severity = trackedComponents.lazy.map(\.status.severity).max() ?? 0
        let indicator: StatusFetchIndicator
        switch severity {
        case 0: indicator = .none
        case 1: indicator = .minor
        case 2: indicator = .major
        default: indicator = .critical
        }

        let context: String
        if affected.isEmpty {
            let names = trackedComponents.prefix(4).map { shortName($0.name) }.joined(
                separator: ", ")
            let remainder = trackedComponents.count > 4 ? " +\(trackedComponents.count - 4)" : ""
            context =
                trackedComponents.isEmpty ? "No services tracked" : "Tracks \(names)\(remainder)"
        } else {
            let names = affected.prefix(3).map { shortName($0.name) }.joined(separator: ", ")
            let remainder = affected.count > 3 ? " +\(affected.count - 3)" : ""
            context = "Affects: \(names)\(remainder)"
        }

        return StatusFetchResult(
            indicator: indicator,
            description: summary.status.description,
            context: context,
            fetchedAt: Date(),
            components: summary.components.map {
                StatusFetchComponent(
                    id: $0.id,
                    name: $0.name,
                    status: $0.status,
                    tracked: tracked.contains($0.id))
            })
    }

    private static func shortName(_ name: String) -> String {
        guard let range = name.range(of: " (") else { return name }
        return String(name[..<range.lowerBound])
    }

}
