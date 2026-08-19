import Foundation

/// Reads Claude usage from the same endpoint Claude Code's own `/usage` command uses,
/// authenticated with the OAuth token `claude login` already stored in the Keychain.
/// No browser cookie is involved, so nothing has to be pasted and nothing expires
/// independently of the CLI.
final class ClaudeProvider: UsageProvider, Sendable {
    let provider: Provider = .claude

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let maximumCredentialBytes = 64 * 1024
    private static let keychainService = "Claude Code-credentials"
    /// `security` reports `errSecItemNotFound` as exit 44.
    private static let itemNotFoundStatus: Int32 = 44

    private struct KeychainCredentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
        }

        let claudeAiOauth: OAuth?
        let accessToken: String?
    }

    private struct ClaudeConfig: Decodable {
        struct OAuthAccount: Decodable {
            let organizationName: String?
            let seatTier: String?
        }

        let oauthAccount: OAuthAccount?
    }

    private enum LimitKind: String, Decodable, Sendable {
        case session
        case weeklyAll = "weekly_all"
        case weeklyScoped = "weekly_scoped"
    }

    /// Only `limit_reached` changes behaviour; the rest of the ladder is inert and listed
    /// so a routine response raises no unrecognized warning. Decoded through `APIEnum`
    /// because a strict decode of this one peripheral field cost every window and the
    /// budget when `critical` appeared. A renamed `limit_reached` would read as `.active`.
    private enum SpendSeverity: String, Sendable {
        case none
        case normal
        case warning
        case critical
        case limitReached = "limit_reached"
    }

    private struct UsageResponse: Decodable, Sendable {
        struct Limit: Decodable, Sendable {
            struct Scope: Decodable, Sendable {
                struct Model: Decodable, Sendable {
                    let displayName: String?

                    private enum CodingKeys: String, CodingKey {
                        case displayName = "display_name"
                    }
                }

                let model: Model?
            }

            let kind: APIEnum<LimitKind>
            let percent: APINumber?
            let resetsAt: String?
            let isActive: APIBool?
            let scope: Scope?

            private enum CodingKeys: String, CodingKey {
                case kind, percent, scope
                case resetsAt = "resets_at"
                case isActive = "is_active"
            }
        }

        struct MoneyAmount: Decodable, Sendable {
            let amountMinor: APINumber?
            let currency: String?
            let exponent: APINumber?

            private enum CodingKeys: String, CodingKey {
                case currency, exponent
                case amountMinor = "amount_minor"
            }
        }

        struct Spend: Decodable, Sendable {
            let limit: MoneyAmount?
            let used: MoneyAmount?
            let disabledReason: String?
            let enabled: APIBool?
            let severity: APIEnum<SpendSeverity>?

            private enum CodingKeys: String, CodingKey {
                case limit, used, enabled, severity
                case disabledReason = "disabled_reason"
            }
        }

        struct ExtraUsage: Decodable, Sendable {
            let monthlyLimit: APINumber?
            let monthlyCreditLimit: APINumber?
            let usedCredits: APINumber?
            let decimalPlaces: APINumber?
            let currency: String?
            let disabledReason: String?
            let isEnabled: APIBool?
            let spendLimitReached: APIBool?

            private enum CodingKeys: String, CodingKey {
                case currency
                case monthlyLimit = "monthly_limit"
                case monthlyCreditLimit = "monthly_credit_limit"
                case usedCredits = "used_credits"
                case decimalPlaces = "decimal_places"
                case disabledReason = "disabled_reason"
                case isEnabled = "is_enabled"
                case spendLimitReached = "spend_limit_reached"
            }
        }

        let limits: [Limit]
        let spend: Spend?
        let extraUsage: ExtraUsage?

        /// Halves of the response this build could not read, named for the panel.
        let undecodable: [String]

        private enum CodingKeys: String, CodingKey {
            case limits, spend
            case extraUsage = "extra_usage"
        }

        /// Decodes `limits`, `spend` and `extra_usage` in isolation. `limits` carries the
        /// windows this app exists to show and the other two carry the budget, yet a
        /// single throw anywhere under one of them used to fail the whole response and
        /// cost the others — a new `spend.severity` string was enough. Entries are
        /// decoded one at a time for the same reason, so an unreadable window drops
        /// itself alone. What the strict decode bought was a fatal error naming no
        /// field; each half now reports itself through `unrecognized` instead.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var undecodable: [String] = []

            let entries: [APIElement<Limit>] =
                Self.isolate(container, .limits, "limits", into: &undecodable) ?? []
            limits = entries.compactMap(\.value)
            if entries.count > limits.count {
                undecodable.append("\(entries.count - limits.count) unreadable limits")
            }

            spend = Self.isolate(container, .spend, "spend", into: &undecodable)
            extraUsage = Self.isolate(container, .extraUsage, "extra_usage", into: &undecodable)
            self.undecodable = undecodable
        }

        /// Absent and unreadable are different outcomes: only the second is reported.
        private static func isolate<T: Decodable>(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys,
            _ label: String,
            into undecodable: inout [String]
        ) -> T? {
            guard container.contains(key), (try? container.decodeNil(forKey: key)) == false
            else { return nil }
            guard let value = try? container.decode(T.self, forKey: key) else {
                undecodable.append("\(label) unreadable")
                return nil
            }
            return value
        }
    }

    /// The Keychain item holds JSON rather than a bare token. Claude Code rewrites the item
    /// on every token refresh with `security add-generic-password -U`, and each rewrite
    /// installs a fresh ACL trusting only `/usr/bin/security`. Reading through that same
    /// tool is therefore the one route that never prompts for consent.
    private static func accessToken() throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UsageError.malformed(field: "security tool")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit else {
            throw UsageError.malformed(field: "security tool exit")
        }
        switch process.terminationStatus {
        case 0: break
        case Self.itemNotFoundStatus: throw UsageError.notLoggedIn(.claude)
        default: throw UsageError.keychain
        }
        // `security -w` terminates the payload with a newline.
        var payload = data
        while payload.last == UInt8(ascii: "\n") {
            payload.removeLast()
        }
        guard !payload.isEmpty, payload.count <= maximumCredentialBytes,
            let credentials = try? JSONDecoder().decode(
                KeychainCredentials.self, from: payload)
        else {
            throw UsageError.malformed(field: "keychain payload")
        }
        // Claude Code nests the token; tolerate a flat shape too.
        guard let token = credentials.claudeAiOauth?.accessToken ?? credentials.accessToken,
            !token.isEmpty
        else {
            throw UsageError.notLoggedIn(.claude)
        }
        return token
    }

    // MARK: Fetch

    func fetch() async throws -> ProviderSnapshot {
        let token = try Self.accessToken()

        var request = URLRequest(
            url: Self.usageURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await HTTPClient.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.malformed(field: "response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.unauthorized }
        guard http.statusCode == 200 else { throw UsageError.http(status: http.statusCode) }
        return try Self.snapshot(from: data, planLabel: Self.readPlanLabel())
    }

    /// Split from the transport so a captured body decodes without the Keychain or the
    /// network, which is what `tests/ClaudeDecodeTests.swift` drives.
    static func snapshot(from data: Data, planLabel: String?) throws -> ProviderSnapshot {
        guard let response = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            throw UsageError.malformed(field: "body")
        }

        var unrecognized = response.undecodable
        let windows = decodeWindows(response.limits, unrecognized: &unrecognized)
        if let value = response.spend?.severity?.unrecognized {
            unrecognized.append("spend severity \(value)")
        }

        return ProviderSnapshot(
            provider: .claude,
            planLabel: planLabel,
            windows: windows,
            budgetReading: decodeBudget(response),
            creditBalanceMinor: nil,
            creditUnit: nil,
            unrecognized: unrecognized
        )
    }

    // MARK: Windows

    /// The `limits` array is self-describing — each entry names its own kind, percent,
    /// reset and model scope — so it is preferred over the top-level meter keys, many
    /// of which are unreleased codenames (`nimbus_quill`, `iguana_necktie`) this app
    /// could not label meaningfully.
    private static func decodeWindows(
        _ entries: [UsageResponse.Limit],
        unrecognized: inout [String]
    ) -> [RateWindow] {
        var windows: [RateWindow] = []
        for entry in entries {
            let percent = entry.percent?.value ?? 0
            let resetsAt = DateParse.iso(entry.resetsAt)
            let isActive = entry.isActive?.value ?? false

            guard let kind = entry.kind.value else {
                unrecognized.append("limit kind \(entry.kind.raw)")
                continue
            }

            switch kind {
            case .session:
                windows.append(
                    RateWindow(
                        id: WindowID.session,
                        label: "Session (5 hour)",
                        percent: percent,
                        resetsAt: resetsAt,
                        isActive: isActive))
            case .weeklyAll:
                windows.append(
                    RateWindow(
                        id: WindowID.weekly,
                        label: "Weekly (7 day)",
                        percent: percent,
                        resetsAt: resetsAt,
                        isActive: isActive))
            case .weeklyScoped:
                let model = entry.scope?.model?.displayName
                guard let model else {
                    unrecognized.append("weekly_scoped without model name")
                    continue
                }
                windows.append(
                    RateWindow(
                        id: "weekly_\(model.lowercased())",
                        label: "Weekly \(model) (7 day)",
                        percent: percent,
                        resetsAt: resetsAt,
                        isActive: isActive))
            }
        }
        return windows
    }

    // MARK: Budget

    /// Prefers the `spend` object, whose amounts arrive as explicit
    /// `{amount_minor, currency, exponent}` triples, over `extra_usage`, which requires
    /// assuming cents. Falls back to `extra_usage` so an account served only the older
    /// shape still gets a budget.
    private static func decodeBudget(_ response: UsageResponse) -> BudgetReading? {
        if let reading = decodeSpendBudget(response.spend) { return reading }
        return decodeExtraUsageBudget(response.extraUsage)
    }

    private static func decodeSpendBudget(_ spend: UsageResponse.Spend?) -> BudgetReading? {
        guard let spend else { return nil }
        let limitMinor = spend.limit?.amountMinor?.roundedInt
        let spentMinor = spend.used?.amountMinor?.roundedInt
        guard limitMinor != nil || spentMinor != nil else { return nil }

        let exponent =
            spend.limit?.exponent?.roundedInt
            ?? spend.used?.exponent?.roundedInt ?? 2
        let currency = spend.limit?.currency ?? spend.used?.currency

        return BudgetReading(
            spentMinor: spentMinor,
            limitMinor: limitMinor,
            unit: currency.map { .currency(code: $0, exponent: exponent) }
                ?? .credits(exponent: exponent),
            scope: nil,
            state: state(
                disabledReason: spend.disabledReason,
                enabled: spend.enabled?.value,
                limitReached: spend.severity?.value == .limitReached),
            resetsAt: nil
        )
    }

    /// `used_credits` is a float here — decoding it as Int is what made upstream report
    /// $0 spent and then hide the whole section behind a `spent > 0` check. The limit
    /// moved from `monthly_credit_limit` to `monthly_limit`, so both are accepted.
    private static func decodeExtraUsageBudget(_ extra: UsageResponse.ExtraUsage?) -> BudgetReading?
    {
        guard let extra else { return nil }

        let limitMinor = extra.monthlyLimit?.roundedInt ?? extra.monthlyCreditLimit?.roundedInt
        let spentMinor = extra.usedCredits?.roundedInt
        guard limitMinor != nil || spentMinor != nil else { return nil }

        let exponent = extra.decimalPlaces?.roundedInt ?? 2

        return BudgetReading(
            spentMinor: spentMinor,
            limitMinor: limitMinor,
            unit: extra.currency.map { .currency(code: $0, exponent: exponent) }
                ?? .credits(exponent: exponent),
            scope: nil,
            state: state(
                disabledReason: extra.disabledReason,
                enabled: extra.isEnabled?.value,
                limitReached: extra.spendLimitReached?.value ?? false),
            resetsAt: nil
        )
    }

    private static func state(disabledReason: String?, enabled: Bool?, limitReached: Bool)
        -> BudgetState
    {
        if let disabledReason, !disabledReason.isEmpty {
            return .disabled(reason: disabledReason)
        }
        if enabled == false { return .disabled(reason: "Extra usage is turned off") }
        if limitReached { return .limitReached }
        return .active
    }

    // MARK: Plan label

    /// Org name and seat tier live in the CLI's own config, not in the usage response.
    ///
    /// The helper exits after one fetch, so an in-process cache would never hit. The
    /// label is memoized on disk against the config's size and mtime instead: this
    /// file accumulates per-project history and grows without bound, and re-reading
    /// plus re-decoding megabytes on every refresh to recover two strings that change
    /// roughly never is the most expensive thing this provider used to do.
    private static func readPlanLabel() -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        let url = URL(fileURLWithPath: path)

        let attributes = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey,
        ])
        // Skip rather than stall a fetch on a multi-megabyte parse.
        guard let size = attributes?.fileSize, size > 0, size < 20_000_000,
            let modified = attributes?.contentModificationDate
        else { return nil }

        let stamp = "\(size):\(modified.timeIntervalSince1970)"
        if planLabelDefaults.string(forKey: planLabelStampKey) == stamp {
            return planLabelDefaults.string(forKey: planLabelKey)
        }

        let label = parsePlanLabel(url)
        planLabelDefaults.set(label, forKey: planLabelKey)
        planLabelDefaults.set(stamp, forKey: planLabelStampKey)
        return label
    }

    private static let planLabelDefaults = UserDefaults(
        suiteName: "com.andrewcho.agentusagebar")!
    private static let planLabelKey = "claude_plan_label"
    private static let planLabelStampKey = "claude_plan_label_stamp"

    private static func parsePlanLabel(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
            let account = try? JSONDecoder().decode(ClaudeConfig.self, from: data).oauthAccount
        else { return nil }

        let org = account.organizationName
        let tier = account.seatTier.map(prettifyTier)

        switch (org, tier) {
        case (let org?, let tier?): return "\(org) · \(tier)"
        case (let org?, nil): return org
        case (nil, let tier?): return tier
        default: return nil
        }
    }

    /// `team_tier_1` reads better as `Team tier 1`.
    private static func prettifyTier(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
