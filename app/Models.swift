import Foundation

// MARK: - Providers

enum Provider: String, CaseIterable, Hashable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    /// The vendor's own menu bar artwork, shipped as a template PNG inside their app.
    /// Preferred over a hand-drawn approximation; `Glyphs` falls back to a drawn path
    /// when the app is not installed.
    var vendorTemplate: (bundleID: String, resource: String) {
        switch self {
        case .claude: return ("com.anthropic.claudefordesktop", "TrayIconTemplate")
        case .codex:  return ("com.openai.codex", "chatgptTemplate")
        }
    }

    /// Where the user changes their own spend limit.
    var manageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex:  return URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }

    /// How the user signs in, shown when a provider is absent.
    var signInHint: String {
        switch self {
        case .claude: return "Run `claude login` to track Claude usage."
        case .codex:  return "Run `codex login` to track Codex usage."
        }
    }
}

// MARK: - Rate limit windows

/// One usage meter: a 5-hour session, a 7-day window, a model-scoped weekly cap.
struct RateWindow: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let percent: Double          // 0-100, as the provider reports it
    let resetsAt: Date?

    /// True when this window is the one currently throttling the account.
    let isActive: Bool
}

// MARK: - Budget

/// What a budget is denominated in. Claude reports real money with a currency code;
/// Codex reports credits with no published conversion rate. Keeping these apart in
/// the type is what stops a credit count from ever rendering with a dollar sign.
enum BudgetUnit: Equatable, Sendable {
    case currency(code: String, exponent: Int)
    case credits(exponent: Int)

    var exponent: Int {
        switch self {
        case .currency(_, let e): return e
        case .credits(let e):     return e
        }
    }
}

/// Whose spend the budget describes. Absent from the OAuth usage endpoint, which
/// reports the caller's own meter; only `overage_spend_limit` carries `limit_type`.
enum BudgetScope: String, Sendable {
    case organization
    case seatTier    = "seat_tier"
    case account
    case group
    case orgService  = "org_service"

    /// Rejects unrecognized values rather than coercing them, so a new scope from
    /// the API surfaces immediately instead of being silently mislabelled as personal.
    init(apiValue: String) throws {
        guard let parsed = BudgetScope(rawValue: apiValue) else {
            throw UsageError.unrecognizedEnum(field: "limit_type", value: apiValue)
        }
        self = parsed
    }
}

enum BudgetState: Equatable, Sendable {
    case active
    case limitReached
    case outOfCredits
    case disabled(reason: String)
}

/// What a provider actually reported. Either half can be absent: an org may report
/// spend without a cap, and Codex reports a cap only on Business/Enterprise seats.
/// Keeping this separate from `Budget` is what lets a user-supplied limit fill a gap
/// without inventing a spend figure that was never measured.
struct BudgetReading: Equatable, Sendable {
    let spentMinor: Int?
    let limitMinor: Int?
    let unit: BudgetUnit
    let scope: BudgetScope?
    let state: BudgetState
    let resetsAt: Date?
}

/// A monthly spend allowance ready to display. The failable initializer enforces
/// `limit > 0` so a zero-limit budget, which would divide by zero and render a
/// meaningless bar, is unrepresentable rather than guarded against at every use site.
struct Budget: Equatable, Sendable {
    let spentMinor: Int
    let limitMinor: Int
    let unit: BudgetUnit
    let scope: BudgetScope?
    let state: BudgetState
    let resetsAt: Date?
    let isUserOverride: Bool

    init?(spentMinor: Int,
          limitMinor: Int,
          unit: BudgetUnit,
          scope: BudgetScope? = nil,
          state: BudgetState = .active,
          resetsAt: Date? = nil,
          isUserOverride: Bool = false) {
        guard limitMinor > 0, spentMinor >= 0 else { return nil }
        self.spentMinor = spentMinor
        self.limitMinor = limitMinor
        self.unit = unit
        self.scope = scope
        self.state = state
        self.resetsAt = resetsAt
        self.isUserOverride = isUserOverride
    }

    var remainingMinor: Int { max(0, limitMinor - spentMinor) }
    var overageMinor: Int { max(0, spentMinor - limitMinor) }
    var fraction: Double { Double(spentMinor) / Double(limitMinor) }
    var percent: Int { Int((fraction * 100).rounded()) }
    var isOver: Bool { spentMinor > limitMinor }

    /// True when the spend figure covers the whole organization rather than this user,
    /// which changes how the number must be labelled.
    var isOrganizationWide: Bool { scope == .organization }
}

// MARK: - Snapshot

struct ProviderSnapshot: Equatable, Sendable {
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

    let fetchedAt: Date

    /// Windows worth putting in the menu bar: the account-wide meters, not the
    /// per-model extras, which would make the title unreadably long.
    var headlineWindows: [RateWindow] {
        windows.filter { $0.isHeadline }
    }

    var worstPercent: Double {
        windows.map(\.percent).max() ?? 0
    }

    /// Combines what the API reported with a limit the user typed in Settings. The
    /// API always wins; the override only fills a missing limit, and never substitutes
    /// for a spend figure that was never reported.
    func resolvedBudget(overrideLimitMinor: Int?) -> Budget? {
        guard let reading = budgetReading, let spent = reading.spentMinor else { return nil }

        if let limit = reading.limitMinor {
            return Budget(spentMinor: spent, limitMinor: limit, unit: reading.unit,
                          scope: reading.scope, state: reading.state,
                          resetsAt: reading.resetsAt, isUserOverride: false)
        }
        guard let overrideLimitMinor else { return nil }
        return Budget(spentMinor: spent, limitMinor: overrideLimitMinor, unit: reading.unit,
                      scope: reading.scope, state: reading.state,
                      resetsAt: reading.resetsAt, isUserOverride: true)
    }
}

extension RateWindow {
    /// Session and overall-weekly meters are headline; model-scoped caps are detail.
    var isHeadline: Bool {
        id == WindowID.session || id == WindowID.weekly
    }
}

/// Stable identifiers for the meters that both providers have in common, so the
/// menu bar can pick them out without string-matching display labels.
enum WindowID {
    static let session = "session"
    static let weekly  = "weekly"
}

// MARK: - Errors

enum UsageError: LocalizedError, Equatable {
    case notLoggedIn(Provider)
    case unauthorized
    case http(status: Int)
    case malformed(field: String)
    case unrecognizedEnum(field: String, value: String)
    case keychain(status: Int32)

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
        case .keychain(let status):
            return "Keychain error \(status)"
        }
    }
}

// MARK: - Provider interface

protocol UsageProvider: Sendable {
    var provider: Provider { get }

    func fetch() async throws -> ProviderSnapshot
}
