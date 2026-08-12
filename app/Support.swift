import SwiftUI
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

// MARK: - JSON coercion

/// JSONSerialization hands back NSNumber for every JSON number, and both providers
/// are inconsistent about type: Claude's `used_credits` is a float, Codex's
/// `individual_limit.used` has been observed as the string "7761". Reading these with
/// `as? Int` returns nil for anything fractional or quoted, which is how upstream
/// silently reported $0 of spend. Everything numeric goes through here.
enum JSONNumber {
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String:   return Double(s)
        default:                return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        guard let d = double(value), d.isFinite else { return nil }
        return Int(d.rounded())
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool:     return b
        case let n as NSNumber: return n.boolValue
        default:                return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]]? {
        value as? [[String: Any]]
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
    static func epoch(_ value: Any?) -> Date? {
        guard let seconds = JSONNumber.double(value), seconds > 0 else { return nil }
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
        return includeDate ? "on \(dayAndTime.string(from: floored))"
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
        if seconds < 21_600  { return "Session (\(Int((seconds / 3600).rounded())) hour)" }
        if seconds < 172_800 { return "Daily (24 hour)" }
        if seconds < 1_209_600 { return "Weekly (7 day)" }
        return "Limit (\(Int((seconds / 86_400).rounded())) day)"
    }
}

// MARK: - Shared colors

extension Color {
    /// System gray in dark; darker in light, where a vibrant ~50% gray over the white
    /// popover backing reads as washed out.
    static let secondaryText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .secondaryLabelColor
            : NSColor(white: 0.24, alpha: 1.0) // opaque: vibrancy washes out alpha grays
    })
}

/// Severity thresholds shared by the bars, the labels and the menu bar glyph, so a
/// number and its color can never disagree.
enum UsageTier: Hashable {
    case normal, warning, critical

    init(percent: Double) {
        switch percent {
        case ..<70:  self = .normal
        case ..<90:  self = .warning
        default:     self = .critical
        }
    }

    var color: Color {
        switch self {
        case .normal:   return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .normal:   return NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0)
        case .warning:  return NSColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1.0)
        case .critical: return NSColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1.0)
        }
    }
}

// MARK: - Usage bar

/// Deterministic bar: the native linear ProgressView ignores .tint() under aqua and
/// vibrant rendering and falls back to accent blue.
struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}
