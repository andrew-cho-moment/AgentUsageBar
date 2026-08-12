import Foundation

/// Reads Codex usage using the OAuth token `codex login` already wrote to
/// `~/.codex/auth.json`. On a 401 the token is refreshed against OpenAI's token
/// endpoint and the result is held **in memory only** — `auth.json` stays owned by the
/// CLI, so this app can never corrupt the CLI's sign-in.
final class CodexProvider: UsageProvider, Sendable {
    let provider: Provider = .codex

    /// Holds a refreshed access token for this process only. An actor rather than a
    /// lock because the read and write both happen inside async work.
    private actor TokenCache {
        private var token: String?
        func read() -> String? { token }
        func write(_ value: String) { token = value }
    }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// Public client id of the Codex CLI, needed to redeem its refresh token.
    private static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let tokenCache = TokenCache()

    // MARK: Credentials

    private static var authPath: String {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        return (home as NSString).appendingPathComponent("auth.json")
    }

    private struct StoredCredentials {
        let accessToken: String
        let refreshToken: String?
    }

    private static func loadCredentials() throws -> StoredCredentials {
        guard let data = FileManager.default.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = JSONNumber.object(json["tokens"]),
              let access = JSONNumber.string(tokens["access_token"]), !access.isEmpty else {
            throw UsageError.notLoggedIn(.codex)
        }
        return StoredCredentials(accessToken: access,
                                 refreshToken: JSONNumber.string(tokens["refresh_token"]))
    }

    func isSignedIn() -> Bool {
        (try? Self.loadCredentials()) != nil
    }

    // MARK: Fetch

    func fetch() async throws -> ProviderSnapshot {
        let stored = try Self.loadCredentials()
        let inMemory = await tokenCache.read()

        do {
            return try await fetchUsage(accessToken: inMemory ?? stored.accessToken)
        } catch UsageError.unauthorized {
            // One retry only: a refresh that is itself rejected must not loop.
            guard let refreshToken = stored.refreshToken,
                  let fresh = try await refreshAccessToken(refreshToken) else {
                throw UsageError.unauthorized
            }
            await tokenCache.write(fresh)
            debugLog("Codex access token refreshed in memory; auth.json untouched")
            return try await fetchUsage(accessToken: fresh)
        }
    }

    private func fetchUsage(accessToken: String) async throws -> ProviderSnapshot {
        var request = URLRequest(url: Self.usageURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.malformed(field: "response")
        }
        if http.statusCode == 401 { throw UsageError.unauthorized }
        guard http.statusCode == 200 else { throw UsageError.http(status: http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformed(field: "body")
        }

        let credits = JSONNumber.object(json["credits"])
        let reading = Self.decodeBudget(json)

        // The bare balance is only informative when there is no budget to frame it.
        var balanceMinor: Int?
        var creditUnit: BudgetUnit?
        if reading == nil, let credits,
           let balance = JSONNumber.int(credits["balance"]), balance > 0 {
            balanceMinor = balance
            creditUnit = .credits(exponent: 0)
        }

        return ProviderSnapshot(
            provider: .codex,
            planLabel: JSONNumber.string(json["plan_type"]).map { $0.capitalized },
            windows: Self.decodeWindows(json),
            budgetReading: reading,
            creditBalanceMinor: balanceMinor,
            creditUnit: creditUnit,
            unrecognized: [],
            fetchedAt: Date()
        )
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> String? {
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.oauthClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return JSONNumber.string(json["access_token"])
    }

    // MARK: Windows

    /// Codex names windows by length rather than by role, and reports extra per-model
    /// meters in a parallel array.
    private static func decodeWindows(_ json: [String: Any]) -> [RateWindow] {
        var windows: [RateWindow] = []
        var seen = Set<String>()

        func append(_ window: RateWindow?) {
            guard let window, !seen.contains(window.id) else { return }
            seen.insert(window.id)
            windows.append(window)
        }

        let limitReached = JSONNumber.object(json["rate_limit"])
            .flatMap { JSONNumber.bool($0["limit_reached"]) } ?? false

        if let rateLimit = JSONNumber.object(json["rate_limit"]) {
            append(window(from: JSONNumber.object(rateLimit["primary_window"]),
                          idOverride: nil, labelOverride: nil, isActive: limitReached))
            append(window(from: JSONNumber.object(rateLimit["secondary_window"]),
                          idOverride: nil, labelOverride: nil, isActive: limitReached))
        }

        for extra in JSONNumber.array(json["additional_rate_limits"]) ?? [] {
            let name = JSONNumber.string(extra["limit_name"])
            let feature = JSONNumber.string(extra["metered_feature"]) ?? name ?? "extra"
            let inner = JSONNumber.object(extra["rate_limit"])
            append(window(from: inner.flatMap { JSONNumber.object($0["primary_window"]) },
                          idOverride: "extra_\(feature)",
                          labelOverride: name,
                          isActive: inner.flatMap { JSONNumber.bool($0["limit_reached"]) } ?? false))
        }

        return windows
    }

    private static func window(from object: [String: Any]?,
                               idOverride: String?,
                               labelOverride: String?,
                               isActive: Bool) -> RateWindow? {
        guard let object,
              let percent = JSONNumber.double(object["used_percent"]) else { return nil }

        let seconds = JSONNumber.double(object["limit_window_seconds"]) ?? 0
        // Both spellings appear across the HTTP response and the CLI's on-disk records.
        let resetsAt = DateParse.epoch(object["reset_at"]) ?? DateParse.epoch(object["resets_at"])

        let id = idOverride ?? (seconds > 0 && seconds < 21_600 ? WindowID.session : WindowID.weekly)
        let label = labelOverride ?? Fmt.windowLabel(seconds: seconds)

        return RateWindow(id: id, label: label, percent: percent,
                          resetsAt: resetsAt, isActive: isActive)
    }

    // MARK: Budget

    /// `individual_limit` has been observed at three different nesting levels, so all
    /// three are checked. It is credit-denominated: OpenAI publishes no credit-to-dollar
    /// rate and the payload carries no currency code, so it is never shown as money.
    private static func decodeBudget(_ json: [String: Any]) -> BudgetReading? {
        let candidates: [[String: Any]?] = [
            JSONNumber.object(json["individual_limit"]),
            JSONNumber.object(json["rate_limit"]).flatMap { JSONNumber.object($0["individual_limit"]) },
            JSONNumber.object(json["spend_control"]).flatMap { JSONNumber.object($0["individual_limit"]) },
        ]

        guard let limitObject = candidates.compactMap({ $0 }).first else { return nil }
        let limit = JSONNumber.int(limitObject["limit"])
        let used = JSONNumber.int(limitObject["used"])
        guard limit != nil || used != nil else { return nil }

        let reached = JSONNumber.object(json["spend_control"])
            .flatMap { JSONNumber.bool($0["reached"]) } ?? false
        let outOfCredits = JSONNumber.object(json["credits"])
            .flatMap { JSONNumber.bool($0["overage_limit_reached"]) } ?? false

        return BudgetReading(
            spentMinor: used,
            limitMinor: limit,
            unit: .credits(exponent: 0),
            scope: nil,
            state: outOfCredits ? .outOfCredits : (reached ? .limitReached : .active),
            resetsAt: DateParse.epoch(limitObject["resets_at"])
                   ?? DateParse.epoch(limitObject["reset_at"])
        )
    }
}
