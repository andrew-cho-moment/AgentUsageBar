import Foundation

/// Reads Codex usage using the OAuth token `codex login` already wrote to
/// `~/.codex/auth.json`. On a 401 the token is refreshed against OpenAI's token
/// endpoint and the result is held **in memory only** — `auth.json` stays owned by the
/// CLI, so this app can never corrupt the CLI's sign-in.
final class CodexProvider: UsageProvider, Sendable {
    let provider: Provider = .codex

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// Public client id of the Codex CLI, needed to redeem its refresh token.
    private static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    // MARK: Credentials

    private static var home: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    private static var authPath: String {
        (home as NSString).appendingPathComponent("auth.json")
    }

    /// The Codex CLI creates this directory on its first run and keeps its config,
    /// history and sessions there, so its absence is what tells the app Codex was never
    /// installed here. Probing for the `codex` binary would not work: a menu-bar app
    /// launched at login inherits no shell `PATH`.
    private static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: home)
    }

    private struct StoredCredentials: Decodable {
        private struct Tokens: Decodable {
            let accessToken: String
            let refreshToken: String?

            private enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
            }
        }

        let accessToken: String
        let refreshToken: String?

        private enum CodingKeys: String, CodingKey {
            case tokens
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tokens = try container.decode(Tokens.self, forKey: .tokens)
            accessToken = tokens.accessToken
            refreshToken = tokens.refreshToken
        }
    }

    private struct UsageResponse: Decodable, Sendable {
        struct Window: Decodable, Sendable {
            let usedPercent: APINumber?
            let limitWindowSeconds: APINumber?
            let resetAt: APINumber?
            let resetsAt: APINumber?

            private enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case limitWindowSeconds = "limit_window_seconds"
                case resetAt = "reset_at"
                case resetsAt = "resets_at"
            }
        }

        struct IndividualLimit: Decodable, Sendable {
            let limit: APINumber?
            let used: APINumber?
            let resetAt: APINumber?
            let resetsAt: APINumber?

            private enum CodingKeys: String, CodingKey {
                case limit, used
                case resetAt = "reset_at"
                case resetsAt = "resets_at"
            }
        }

        struct RateLimit: Decodable, Sendable {
            let limitReached: APIBool?
            let primaryWindow: Window?
            let secondaryWindow: Window?
            let individualLimit: IndividualLimit?

            private enum CodingKeys: String, CodingKey {
                case limitReached = "limit_reached"
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
                case individualLimit = "individual_limit"
            }
        }

        struct AdditionalRateLimit: Decodable, Sendable {
            let limitName: String?
            let meteredFeature: String?
            let rateLimit: RateLimit?

            private enum CodingKeys: String, CodingKey {
                case limitName = "limit_name"
                case meteredFeature = "metered_feature"
                case rateLimit = "rate_limit"
            }
        }

        struct SpendControl: Decodable, Sendable {
            let individualLimit: IndividualLimit?
            let reached: APIBool?

            private enum CodingKeys: String, CodingKey {
                case reached
                case individualLimit = "individual_limit"
            }
        }

        struct Credits: Decodable, Sendable {
            let balance: APINumber?
            let overageLimitReached: APIBool?

            private enum CodingKeys: String, CodingKey {
                case balance
                case overageLimitReached = "overage_limit_reached"
            }
        }

        let planType: String?
        let rateLimit: RateLimit?
        let additionalRateLimits: [AdditionalRateLimit]?
        let individualLimit: IndividualLimit?
        let spendControl: SpendControl?
        let credits: Credits?

        private enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
            case individualLimit = "individual_limit"
            case spendControl = "spend_control"
            case credits
        }
    }

    private struct TokenRefreshRequest: Encodable {
        let clientID: String
        let grantType: GrantType
        let refreshToken: String

        enum GrantType: String, Encodable {
            case refreshToken = "refresh_token"
        }

        private enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
        }
    }

    private struct TokenRefreshResponse: Decodable {
        let accessToken: String

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    private static func loadCredentials() throws -> StoredCredentials {
        guard let data = FileManager.default.contents(atPath: authPath),
            let credentials = try? JSONDecoder().decode(StoredCredentials.self, from: data),
            !credentials.accessToken.isEmpty
        else {
            // An install with no usable `auth.json` earns a `codex login` hint; a machine
            // with no Codex at all earns no mention of Codex anywhere in the UI.
            throw isInstalled ? UsageError.notLoggedIn(.codex) : .notInstalled(.codex)
        }
        return credentials
    }

    // MARK: Fetch

    func fetch() async throws -> ProviderSnapshot {
        let stored = try Self.loadCredentials()
        do {
            return try await fetchUsage(accessToken: stored.accessToken)
        } catch UsageError.unauthorized {
            // One retry only: a refresh that is itself rejected must not loop.
            guard let refreshToken = stored.refreshToken,
                let fresh = try await refreshAccessToken(refreshToken)
            else {
                throw UsageError.unauthorized
            }
            return try await fetchUsage(accessToken: fresh)
        }
    }

    private func fetchUsage(accessToken: String) async throws -> ProviderSnapshot {
        var request = URLRequest(
            url: Self.usageURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await HTTPClient.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.malformed(field: "response")
        }
        // 403 as well as 401: an expired token comes back either way here, and
        // treating 403 as a plain HTTP error is what stopped `fetch` from ever
        // reaching its refresh-and-retry path.
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageError.unauthorized
        }
        guard http.statusCode == 200 else { throw UsageError.http(status: http.statusCode) }
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            throw UsageError.malformed(field: "body")
        }

        let reading = Self.decodeBudget(usage)

        // The bare balance is only informative when there is no budget to frame it.
        var balanceMinor: Int?
        var creditUnit: BudgetUnit?
        if reading == nil, let balance = usage.credits?.balance?.roundedInt, balance > 0 {
            balanceMinor = balance
            creditUnit = .credits(exponent: 0)
        }

        return ProviderSnapshot(
            provider: .codex,
            planLabel: usage.planType.map { $0.capitalized },
            windows: Self.decodeWindows(usage),
            budgetReading: reading,
            creditBalanceMinor: balanceMinor,
            creditUnit: creditUnit,
            unrecognized: []
        )
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> String? {
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            TokenRefreshRequest(
                clientID: Self.oauthClientID,
                grantType: .refreshToken,
                refreshToken: refreshToken
            ))

        let (data, response) = try await HTTPClient.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let result = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        else {
            return nil
        }
        return result.accessToken
    }

    // MARK: Windows

    /// Codex names windows by length rather than by role, and reports extra per-model
    /// meters in a parallel array.
    private static func decodeWindows(_ response: UsageResponse) -> [RateWindow] {
        var windows: [RateWindow] = []
        var seen = Set<String>()

        func append(_ window: RateWindow?) {
            guard let window, !seen.contains(window.id) else { return }
            seen.insert(window.id)
            windows.append(window)
        }

        let limitReached = response.rateLimit?.limitReached?.value ?? false

        if let rateLimit = response.rateLimit {
            append(window(from: rateLimit.primaryWindow, isActive: limitReached))
            append(window(from: rateLimit.secondaryWindow, isActive: limitReached))
        }

        for extra in response.additionalRateLimits ?? [] {
            let name = extra.limitName
            let feature = extra.meteredFeature ?? name ?? "extra"
            append(
                window(
                    from: extra.rateLimit?.primaryWindow,
                    idOverride: "extra_\(feature)",
                    labelOverride: name,
                    isActive: extra.rateLimit?.limitReached?.value ?? false))
        }

        return windows
    }

    private static func window(
        from object: UsageResponse.Window?,
        idOverride: String? = nil,
        labelOverride: String? = nil,
        isActive: Bool
    ) -> RateWindow? {
        guard let object,
            let percent = object.usedPercent?.value
        else { return nil }

        let seconds = object.limitWindowSeconds?.value ?? 0
        // Both spellings appear across the HTTP response and the CLI's on-disk records.
        let resetsAt = DateParse.epoch(object.resetAt) ?? DateParse.epoch(object.resetsAt)

        let id = idOverride ?? Fmt.windowID(seconds: seconds)
        let label = labelOverride ?? Fmt.windowLabel(seconds: seconds)

        return RateWindow(
            id: id, label: label, percent: percent,
            resetsAt: resetsAt, isActive: isActive)
    }

    // MARK: Budget

    /// `individual_limit` has been observed at three different nesting levels, so all
    /// three are checked. It is credit-denominated: OpenAI publishes no credit-to-dollar
    /// rate and the payload carries no currency code, so it is never shown as money.
    private static func decodeBudget(_ response: UsageResponse) -> BudgetReading? {
        let candidates: [UsageResponse.IndividualLimit?] = [
            response.individualLimit,
            response.rateLimit?.individualLimit,
            response.spendControl?.individualLimit,
        ]

        guard let limitObject = candidates.compactMap({ $0 }).first else { return nil }
        let limit = limitObject.limit?.roundedInt
        let used = limitObject.used?.roundedInt
        guard limit != nil || used != nil else { return nil }

        let reached = response.spendControl?.reached?.value ?? false
        let outOfCredits = response.credits?.overageLimitReached?.value ?? false

        return BudgetReading(
            spentMinor: used,
            limitMinor: limit,
            unit: .credits(exponent: 0),
            scope: nil,
            state: outOfCredits ? .outOfCredits : (reached ? .limitReached : .active),
            resetsAt: DateParse.epoch(limitObject.resetsAt)
                ?? DateParse.epoch(limitObject.resetAt)
        )
    }
}
