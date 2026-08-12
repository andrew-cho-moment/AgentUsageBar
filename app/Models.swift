import Foundation

// MARK: - Providers

enum Provider: String, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

// MARK: - Rate limit windows

/// One usage meter: a 5-hour session, a 7-day window, a model-scoped weekly cap.
struct RateWindow: Sendable {
    let id: String
    let label: String
    let percent: Double  // 0-100, as the provider reports it
    let resetsAt: Date?

    /// True when this window is the one currently throttling the account.
    let isActive: Bool
}

// MARK: - Budget

/// What a budget is denominated in. Claude reports real money with a currency code;
/// Codex reports credits with no published conversion rate. Keeping these apart in
/// the type is what stops a credit count from ever rendering with a dollar sign.
enum BudgetUnit: Sendable {
    case currency(code: String, exponent: Int)
    case credits(exponent: Int)

    var exponent: Int {
        switch self {
        case .currency(_, let e): return e
        case .credits(let e): return e
        }
    }
}

/// Whose spend the budget describes. Absent from the OAuth usage endpoint, which
/// reports the caller's own meter; only `overage_spend_limit` carries `limit_type`.
enum BudgetScope: String, Sendable {
    case organization
    case seatTier = "seat_tier"
    case account
    case group
    case orgService = "org_service"

    /// Rejects unrecognized values rather than coercing them, so a new scope from
    /// the API surfaces immediately instead of being silently mislabelled as personal.
    init(apiValue: String) throws {
        guard let parsed = BudgetScope(rawValue: apiValue) else {
            throw UsageError.unrecognizedEnum(field: "limit_type", value: apiValue)
        }
        self = parsed
    }
}

enum BudgetState: Sendable {
    case active
    case limitReached
    case outOfCredits
    case disabled(reason: String)
}

/// What a provider actually reported. Either half can be absent: an org may report
/// spend without a cap, and Codex reports a cap only on Business/Enterprise seats.
struct BudgetReading: Sendable {
    let spentMinor: Int?
    let limitMinor: Int?
    let unit: BudgetUnit
    let scope: BudgetScope?
    let state: BudgetState
    let resetsAt: Date?
}

// MARK: - Snapshot

struct ProviderSnapshot: Sendable {
    let provider: Provider
    let planLabel: String?
    let windows: [RateWindow]
    let budgetReading: BudgetReading?

    /// Bare credit balance, shown only when there is no budget to put it in context.
    let creditBalanceMinor: Int?
    let creditUnit: BudgetUnit?

    /// API fields this build did not recognize. Surfaced in the UI rather than
    /// swallowed, so an upstream schema change is visible the day it lands.
    let unrecognized: [String]
}

/// Stable identifiers for the meters that both providers have in common, so the
/// menu bar can pick them out without string-matching display labels.
enum WindowID {
    static let session = "session"
    static let weekly = "weekly"
}

// MARK: - Errors

enum UsageError: LocalizedError {
    case notLoggedIn(Provider)
    case unauthorized
    case http(status: Int)
    case malformed(field: String)
    case unrecognizedEnum(field: String, value: String)
    case keychain

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let p):
            return "Not signed in to \(p.displayName)"
        case .unauthorized:
            return "Sign-in expired"
        case .http(let status):
            return "HTTP \(status)"
        case .malformed(let field):
            return "Unexpected response (\(field))"
        case .unrecognizedEnum(let field, let value):
            return "Unrecognized \(field): \(value)"
        case .keychain:
            return "Keychain access failed"
        }
    }
}

// MARK: - Provider interface

protocol UsageProvider: Sendable {
    var provider: Provider { get }

    func fetch() async throws -> ProviderSnapshot
}
