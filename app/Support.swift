import AppKit
import os

// MARK: - Networking

enum HTTPClient {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()
}

// MARK: - Logging

/// Diagnostics are opt-in. Both providers return bearer-authenticated account data, and
/// the unified log is readable by any process running as this user, so nothing is
/// emitted unless AGENTUSAGEBAR_DEBUG=1 is set in the environment.
///
/// Inspect with:
///   log show --last 5m --predicate 'subsystem == "com.andrewcho.agentusagebar"'
let debugLoggingEnabled = ProcessInfo.processInfo.environment["AGENTUSAGEBAR_DEBUG"] == "1"

private let appLogger = Logger(subsystem: "com.andrewcho.agentusagebar", category: "app")

func debugLog(_ message: @autoclosure () -> String) {
    guard debugLoggingEnabled else { return }
    // Evaluated before interpolation: Logger's interpolation escapes its argument,
    // which a non-escaping autoclosure cannot be captured by.
    let text = message()
    // `notice` rather than `debug`: debug-level records are not persisted to the log
    // store, so they cannot be read back after the fact. Emission is already gated.
    appLogger.notice("\(text, privacy: .public)")
}

// MARK: - API scalar decoding

/// Provider APIs inconsistently encode numbers as JSON numbers and decimal strings.
/// Decoding that variation once keeps every response model typed without building an
/// `[String: Any]` object graph.
struct APINumber: Decodable, Sendable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self), number.isFinite {
            value = number
            return
        }
        if let string = try? container.decode(String.self),
            let number = Double(string), number.isFinite
        {
            value = number
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected a finite number or decimal string"
        )
    }

    var roundedInt: Int { Int(value.rounded()) }
}

/// A few older provider payloads encode booleans as 0 or 1. Other numeric values are
/// rejected so an API contract change cannot silently flip a setting.
struct APIBool: Decodable, Sendable {
    let value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolean = try? container.decode(Bool.self) {
            value = boolean
            return
        }
        if let integer = try? container.decode(Int.self), integer == 0 || integer == 1 {
            value = integer == 1
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected a boolean or 0/1"
        )
    }
}

// MARK: - Dates

enum DateParse {
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// Claude sends ISO-8601, with or without fractional seconds.
    static func iso(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return (try? Date(string, strategy: isoFractional))
            ?? (try? Date(string, strategy: isoPlain))
    }

    /// Codex sends Unix epoch seconds, sometimes as `resets_at` and sometimes `reset_at`.
    static func epoch(_ value: APINumber?) -> Date? {
        guard let seconds = value?.value, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Formatting

enum Fmt {
    @MainActor
    private static var currencyFormatters: [String: NumberFormatter] = [:]

    @MainActor
    private static let creditFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    @MainActor
    static let timeOfDay: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    @MainActor
    static let dayAndTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM 'at' h:mm a"
        return f
    }()

    @MainActor
    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    @MainActor
    private static func currencyFormatter(code: String, exponent: Int) -> NumberFormatter {
        let key = "\(code)/\(exponent)"
        if let existing = currencyFormatters[key] { return existing }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.maximumFractionDigits = exponent
        f.minimumFractionDigits = exponent
        currencyFormatters[key] = f
        return f
    }

    /// Renders a minor-unit amount in its own unit. Credits never get a currency symbol.
    @MainActor
    static func amount(_ minor: Int, unit: BudgetUnit) -> String {
        let scale = pow(10.0, Double(unit.exponent))
        switch unit {
        case .currency(let code, let exponent):
            let value = Double(minor) / scale
            let formatter = currencyFormatter(code: code, exponent: exponent)
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        case .credits:
            let value = (Double(minor) / scale).rounded()
            let formatted = creditFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
            return "\(formatted) credits"
        }
    }

    /// Compact form for the menu bar: no fractional part, no "credits" suffix.
    @MainActor
    static func amountCompact(_ minor: Int, unit: BudgetUnit) -> String {
        let value = (Double(minor) / pow(10.0, Double(unit.exponent))).rounded()
        switch unit {
        case .currency(let code, _):
            let formatter = currencyFormatter(code: code, exponent: 0)
            return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        case .credits:
            return creditFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        }
    }

    /// Truncates to the whole minute. A format string without a seconds field rounds
    /// up, so a window resetting at 23:59:59 would otherwise be shown as 12:00 AM the
    /// *following* day — a second later, but a date that reads as wrong.
    private static func flooredToMinute(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60)
    }

    @MainActor
    static func resetPhrase(_ date: Date, includeDate: Bool) -> String {
        let floored = flooredToMinute(date)
        return includeDate
            ? "on \(dayAndTime.string(from: floored))"
            : "at \(timeOfDay.string(from: floored))"
    }

    @MainActor
    static func shortReset(_ date: Date) -> String {
        "Resets \(monthDay.string(from: flooredToMinute(date)))"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let elapsed = Int(now.timeIntervalSince(date))
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 {
            let m = elapsed / 60
            return "\(m) min\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86_400 {
            let h = elapsed / 3600
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = elapsed / 86_400
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }

    /// Codex reports window length rather than a name; derive the label from it.
    static func windowLabel(seconds: Double) -> String {
        if seconds < 21_600 { return "Session (\(Int((seconds / 3600).rounded())) hour)" }
        if seconds < 172_800 { return "Daily (24 hour)" }
        if seconds < 1_209_600 { return "Weekly (7 day)" }
        return "Limit (\(Int((seconds / 86_400).rounded())) day)"
    }
}

/// Severity thresholds shared by the bars, the labels and the menu bar glyph, so a
/// number and its color can never disagree.
enum UsageTier: Hashable {
    case normal, warning, critical

    init(percent: Double) {
        switch percent {
        case ..<70: self = .normal
        case ..<90: self = .warning
        default: self = .critical
        }
    }

    var nsColor: NSColor {
        switch self {
        case .normal: return NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0)
        case .warning: return NSColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1.0)
        case .critical: return NSColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1.0)
        }
    }
}
