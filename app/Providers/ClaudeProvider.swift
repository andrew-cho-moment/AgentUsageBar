import Foundation
import Security

/// Reads Claude usage from the same endpoint Claude Code's own `/usage` command uses,
/// authenticated with the OAuth token `claude login` already stored in the Keychain.
/// No browser cookie is involved, so nothing has to be pasted and nothing expires
/// independently of the CLI.
final class ClaudeProvider: UsageProvider, Sendable {
    let provider: Provider = .claude

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private static let betaHeader = "oauth-2025-04-20"

    /// `~/.claude.json` can grow large, so the plan label is read at most once per launch.
    private actor PlanLabelCache {
        private var isLoaded = false
        private var value: String?

        func resolve(_ compute: @Sendable () -> String?) -> String? {
            if !isLoaded {
                value = compute()
                isLoaded = true
            }
            return value
        }
    }

    private let planLabelCache = PlanLabelCache()

    // MARK: Sign-in

    func isSignedIn() -> Bool {
        (try? Self.accessToken()) != nil
    }

    /// The Keychain item holds JSON rather than a bare token. Reading it prompts for
    /// consent the first time, since the item belongs to Claude Code.
    private static func accessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw UsageError.notLoggedIn(.claude) }
            throw UsageError.keychain(status: status)
        }
        guard let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformed(field: "keychain payload")
        }
        // Claude Code nests the token; tolerate a flat shape too.
        let container = JSONNumber.object(json["claudeAiOauth"]) ?? json
        guard let token = JSONNumber.string(container["accessToken"]), !token.isEmpty else {
            throw UsageError.notLoggedIn(.claude)
        }
        return token
    }

    // MARK: Fetch

    func fetch() async throws -> ProviderSnapshot {
        let token = try Self.accessToken()

        var request = URLRequest(url: Self.usageURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.malformed(field: "response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.unauthorized }
        guard http.statusCode == 200 else { throw UsageError.http(status: http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformed(field: "body")
        }

        var unrecognized: [String] = []
        let windows = Self.decodeWindows(json, unrecognized: &unrecognized)

        return ProviderSnapshot(
            provider: .claude,
            planLabel: await planLabelCache.resolve(Self.readPlanLabel),
            windows: windows,
            budgetReading: Self.decodeBudget(json),
            creditBalanceMinor: nil,
            creditUnit: nil,
            unrecognized: unrecognized,
            fetchedAt: Date()
        )
    }

    // MARK: Windows

    /// The `limits` array is self-describing — each entry names its own kind, percent,
    /// reset and model scope — so it is preferred over the top-level meter keys, many
    /// of which are unreleased codenames (`nimbus_quill`, `iguana_necktie`) this app
    /// could not label meaningfully.
    private static func decodeWindows(_ json: [String: Any],
                                      unrecognized: inout [String]) -> [RateWindow] {
        guard let entries = JSONNumber.array(json["limits"]) else { return [] }

        var windows: [RateWindow] = []
        for entry in entries {
            guard let kindValue = JSONNumber.string(entry["kind"]) else {
                unrecognized.append("limits[].kind missing")
                continue
            }
            guard let kind = LimitKind(rawValue: kindValue) else {
                // Surfaced rather than skipped silently, so a new bucket is visible
                // the day Anthropic ships it.
                unrecognized.append("limit kind '\(kindValue)'")
                continue
            }
            let percent = JSONNumber.double(entry["percent"]) ?? 0
            let resetsAt = DateParse.iso(JSONNumber.string(entry["resets_at"]))
            let isActive = JSONNumber.bool(entry["is_active"]) ?? false

            switch kind {
            case .session:
                windows.append(RateWindow(id: WindowID.session,
                                          label: "Session (5 hour)",
                                          percent: percent,
                                          resetsAt: resetsAt,
                                          isActive: isActive))
            case .weeklyAll:
                windows.append(RateWindow(id: WindowID.weekly,
                                          label: "Weekly (7 day)",
                                          percent: percent,
                                          resetsAt: resetsAt,
                                          isActive: isActive))
            case .weeklyScoped:
                let model = JSONNumber.object(entry["scope"])
                    .flatMap { JSONNumber.object($0["model"]) }
                    .flatMap { JSONNumber.string($0["display_name"]) }
                guard let model else {
                    unrecognized.append("weekly_scoped without model name")
                    continue
                }
                windows.append(RateWindow(id: "weekly_\(model.lowercased())",
                                          label: "Weekly \(model) (7 day)",
                                          percent: percent,
                                          resetsAt: resetsAt,
                                          isActive: isActive))
            }
        }
        return windows
    }

    private enum LimitKind: String {
        case session
        case weeklyAll    = "weekly_all"
        case weeklyScoped = "weekly_scoped"
    }

    // MARK: Budget

    /// Prefers the `spend` object, whose amounts arrive as explicit
    /// `{amount_minor, currency, exponent}` triples, over `extra_usage`, which requires
    /// assuming cents. Falls back to `extra_usage` so an account served only the older
    /// shape still gets a budget.
    private static func decodeBudget(_ json: [String: Any]) -> BudgetReading? {
        if let reading = decodeSpendBudget(JSONNumber.object(json["spend"])) { return reading }
        return decodeExtraUsageBudget(JSONNumber.object(json["extra_usage"]))
    }

    private static func decodeSpendBudget(_ spend: [String: Any]?) -> BudgetReading? {
        guard let spend else { return nil }
        let limitObject = JSONNumber.object(spend["limit"])
        let usedObject = JSONNumber.object(spend["used"])

        let limitMinor = limitObject.flatMap { JSONNumber.int($0["amount_minor"]) }
        let spentMinor = usedObject.flatMap { JSONNumber.int($0["amount_minor"]) }
        guard limitMinor != nil || spentMinor != nil else { return nil }

        let exponent = limitObject.flatMap { JSONNumber.int($0["exponent"]) }
                    ?? usedObject.flatMap { JSONNumber.int($0["exponent"]) } ?? 2
        let currency = limitObject.flatMap { JSONNumber.string($0["currency"]) }
                    ?? usedObject.flatMap { JSONNumber.string($0["currency"]) }

        return BudgetReading(
            spentMinor: spentMinor,
            limitMinor: limitMinor,
            unit: currency.map { .currency(code: $0, exponent: exponent) }
               ?? .credits(exponent: exponent),
            scope: nil,
            state: state(disabledReason: JSONNumber.string(spend["disabled_reason"]),
                         enabled: JSONNumber.bool(spend["enabled"]),
                         limitReached: JSONNumber.string(spend["severity"]) == "limit_reached"),
            resetsAt: nil
        )
    }

    /// `used_credits` is a float here — decoding it as Int is what made upstream report
    /// $0 spent and then hide the whole section behind a `spent > 0` check. The limit
    /// moved from `monthly_credit_limit` to `monthly_limit`, so both are accepted.
    private static func decodeExtraUsageBudget(_ extra: [String: Any]?) -> BudgetReading? {
        guard let extra else { return nil }

        let limitMinor = JSONNumber.int(extra["monthly_limit"])
                      ?? JSONNumber.int(extra["monthly_credit_limit"])
        let spentMinor = JSONNumber.int(extra["used_credits"])
        guard limitMinor != nil || spentMinor != nil else { return nil }

        let exponent = JSONNumber.int(extra["decimal_places"]) ?? 2

        return BudgetReading(
            spentMinor: spentMinor,
            limitMinor: limitMinor,
            unit: JSONNumber.string(extra["currency"]).map { .currency(code: $0, exponent: exponent) }
               ?? .credits(exponent: exponent),
            scope: nil,
            state: state(disabledReason: JSONNumber.string(extra["disabled_reason"]),
                         enabled: JSONNumber.bool(extra["is_enabled"]),
                         limitReached: JSONNumber.bool(extra["spend_limit_reached"]) ?? false),
            resetsAt: nil
        )
    }

    private static func state(disabledReason: String?, enabled: Bool?, limitReached: Bool) -> BudgetState {
        if let disabledReason, !disabledReason.isEmpty {
            return .disabled(reason: disabledReason)
        }
        if enabled == false { return .disabled(reason: "Extra usage is turned off") }
        if limitReached { return .limitReached }
        return .active
    }

    // MARK: Plan label

    /// Org name and seat tier live in the CLI's own config, not in the usage response.
    /// Captures nothing, so it is safe to hand to the cache actor.
    @Sendable private static func readPlanLabel() -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        let url = URL(fileURLWithPath: path)

        // This file accumulates project state and can be large; skip rather than
        // stall the first fetch on a multi-megabyte parse.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size < 20_000_000 else { return nil }

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = JSONNumber.object(json["oauthAccount"]) else { return nil }

        let org = JSONNumber.string(account["organizationName"])
        let tier = JSONNumber.string(account["seatTier"]).map(prettifyTier)

        switch (org, tier) {
        case let (org?, tier?): return "\(org) · \(tier)"
        case let (org?, nil):   return org
        case let (nil, tier?):  return tier
        default:                return nil
        }
    }

    /// `team_tier_1` reads better as `Team tier 1`.
    private static func prettifyTier(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
