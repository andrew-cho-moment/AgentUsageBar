import Foundation
import SQLite3

/// Reads Cursor's existing IDE session without modifying or retaining credentials.
/// The dashboard endpoint is undocumented; unexpected schemas fail visibly.
struct CursorProvider: UsageProvider {
    let provider: Provider = .cursor
    var home: AgentHome {
        AgentHome(provider: .cursor, configuredPath: Settings.homeOverride(.cursor),
                  environmentPath: nil,
                  standardPath: NSHomeDirectory() + "/Library/Application Support/Cursor")
    }

    func fetch() async throws -> ProviderSnapshot {
        let path = home.path + "/User/globalStorage/state.vscdb"
        guard FileManager.default.fileExists(atPath: path) else { throw home.missingCredential }
        let cookie = try Self.sessionCookie(databasePath: path)
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await HTTPClient.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw UsageError.malformed(field: "Cursor response")
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw UsageError.unauthorized
        }
        guard response.statusCode == 200 else { throw UsageError.http(status: response.statusCode) }
        return try Self.decode(data)
    }

    static func sessionCookie(databasePath: String) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw UsageError.malformed(field: "Cursor database")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1,
            &statement, nil) == SQLITE_OK else {
            throw UsageError.malformed(field: "Cursor credentials")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw UsageError.notLoggedIn(.cursor)
        }
        return try cookie(from: String(cString: value))
    }

    static func cookie(from token: String) throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 3, !parts.contains(where: { $0.isEmpty }),
              token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw UsageError.notLoggedIn(.cursor)
        }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String,
              let identifier = subject.split(separator: "|").last,
              !identifier.isEmpty,
              let encoded = String(identifier).addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { throw UsageError.notLoggedIn(.cursor) }
        return "\(encoded)%3A%3A\(token)"
    }

    private struct Summary: Decodable {
        struct Usage: Decodable {
            struct Plan: Decodable {
                let enabled: APIBool?
                let totalPercentUsed: APINumber?
                let apiPercentUsed: APINumber?
                let autoPercentUsed: APINumber?
            }
            struct Overall: Decodable {
                let used: APINumber?
                let limit: APINumber?
            }
            let plan: Plan?
            let overall: Overall?
        }
        let membershipType: String?
        let billingCycleEnd: String?
        let individualUsage: Usage?
    }

    static func decode(_ data: Data) throws -> ProviderSnapshot {
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            throw UsageError.malformed(field: "Cursor usage")
        }
        let reset = DateParse.iso(summary.billingCycleEnd)
        var windows: [RateWindow] = []
        func append(_ number: APINumber?, id: String, label: String) throws {
            guard let value = number?.value else { return }
            guard value >= 0 else { throw UsageError.malformed(field: "Cursor percentage") }
            windows.append(RateWindow(id: id, label: label, percent: min(value, 100),
                                      resetsAt: reset, isActive: value >= 100))
        }
        if let plan = summary.individualUsage?.plan, plan.enabled?.value != false {
            // Use the reported percentages: used/limit is NOT equivalent for pooled plans.
            try append(plan.totalPercentUsed, id: WindowID.monthly, label: "Total usage")
            try append(plan.apiPercentUsed, id: "cursor_api", label: "API usage")
            try append(plan.autoPercentUsed, id: "cursor_auto", label: "Auto usage")
        }
        var budget: BudgetReading?
        if windows.isEmpty, let overall = summary.individualUsage?.overall,
           let spent = overall.used?.roundedInt, spent >= 0 {
            let limit = overall.limit?.roundedInt
            guard limit == nil || limit! >= 0 else {
                throw UsageError.malformed(field: "Cursor limit")
            }
            budget = BudgetReading(spentMinor: spent, limitMinor: limit,
                unit: .currency(code: "USD", exponent: 2), scope: .account,
                state: .active, resetsAt: reset)
            if let limit, limit > 0 {
                windows.append(RateWindow(id: WindowID.monthly, label: "Total usage",
                    percent: min(100, Double(spent) / Double(limit) * 100),
                    resetsAt: reset, isActive: spent >= limit))
            }
        }
        guard !windows.isEmpty || budget != nil else {
            throw UsageError.malformed(field: "Cursor usage meters")
        }
        return ProviderSnapshot(provider: .cursor,
            planLabel: summary.membershipType.map { Bounded.utf8($0.capitalized, bytes: 60) },
            windows: windows, budgetReading: budget, creditBalanceMinor: nil,
            creditUnit: nil, unrecognized: [])
    }
}
