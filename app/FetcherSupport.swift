import Foundation

enum HTTPClient {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: configuration)
    }()
}

/// The app's own settings, written by the menu-bar host and read here. The helper is a
/// bare executable with no Info.plist, so `UserDefaults.standard` would resolve to a
/// domain of its own rather than the app's.
enum Settings {
    static let store = UserDefaults(suiteName: "com.andrewcho.agentusagebar")!

    /// Expanded here as well as by the host, because a path can also arrive from
    /// `defaults write`, which normalizes nothing.
    static func homeOverride(_ provider: Provider) -> String? {
        guard let value = store.string(forKey: "home_override_\(provider.rawValue)"),
            !value.isEmpty
        else { return nil }
        return (value as NSString).expandingTildeInPath
    }
}

/// Where a provider's CLI keeps the state this app reads, and who chose that folder.
/// An app launched at login inherits no shell environment, which is why the app holds
/// a setting of its own: it is the only source that survives that launch.
struct AgentHome: Sendable {
    enum Source: String, Sendable {
        /// The folder the CLI installs to.
        case standard
        /// The CLI's own variable, visible only when a shell launched this app.
        case environment
        /// The folder named in the app's settings.
        case setting

        /// Whether a person picked this folder, which is what makes its absence an
        /// error to report rather than a CLI that was never installed.
        var isChosen: Bool { self != .standard }
    }

    let provider: Provider
    let path: String
    let source: Source

    init(
        provider: Provider, configuredPath: String?, environmentPath: String?, standardPath: String
    ) {
        self.provider = provider
        if let configuredPath {
            path = configuredPath
            source = .setting
        } else if let environmentPath {
            path = environmentPath
            source = .environment
        } else {
            path = standardPath
            source = .standard
        }
    }

    init(provider: Provider, environmentKey: String, standardFolder: String) {
        self.init(
            provider: provider,
            configuredPath: Settings.homeOverride(provider),
            // `getenv` rather than `ProcessInfo.environment`, which copies the whole
            // environment into a fresh dictionary on every access.
            environmentPath: getenv(environmentKey).map { String(cString: $0) },
            standardPath: (NSHomeDirectory() as NSString).appendingPathComponent(standardFolder))
    }

    /// What a missing credential means here. A folder that is present holds an install
    /// nobody has signed into; a chosen folder that is gone is a setting or a variable
    /// its owner can fix; a missing standard folder is a CLI that was never installed.
    var missingCredential: UsageError {
        var directory: ObjCBool = false
        let exists =
            FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && directory.boolValue
        if exists { return .notLoggedIn(provider) }
        return source.isChosen ? .homeMissing(provider, path: path) : .notInstalled(provider)
    }
}

/// Text bounded to a byte budget on a character boundary. The host copies these fields
/// into fixed buffers and rejects the whole refresh on overflow, so a deep path has to
/// be cut here, and cut by bytes: one accented component is two bytes per character.
enum Bounded {
    static func utf8(_ text: String, bytes limit: Int) -> String {
        if text.utf8.count <= limit { return text }
        var trimmed = ""
        var used = 3  // the three bytes of the ellipsis that marks the cut
        for character in text.reversed() {
            let size = String(character).utf8.count
            if used + size > limit { break }
            used += size
            trimmed = String(character) + trimmed
        }
        return "\u{2026}" + trimmed
    }
}

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
            debugDescription: "Expected a finite number or decimal string")
    }

    /// Absent rather than trapping when the value is finite but outside `Int`'s
    /// range: every money and limit field in both providers flows through here, so
    /// one absurd number from an upstream endpoint would otherwise kill the helper
    /// and surface only as "Usage refresh failed".
    var roundedInt: Int? {
        let rounded = value.rounded()
        guard rounded.magnitude < 9e15 else { return nil }
        return Int(rounded)
    }
}

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
            debugDescription: "Expected a boolean or 0/1")
    }
}

/// An API enum whose value set the endpoint still extends. Decoding keeps the wire
/// string when it names no case, so a new value reaches `ProviderSnapshot.unrecognized`
/// instead of throwing: a strict decode of one peripheral field takes the whole response
/// down with it, and every window and budget in it.
struct APIEnum<Value: RawRepresentable & Sendable>: Decodable, Sendable
where Value.RawValue == String {
    /// `raw` reaches a fixed-size diagnostics buffer in the menu bar app, and this is
    /// the one place wire-controlled text enters it. Truncating here keeps a long value
    /// from overflowing that buffer, which costs the whole refresh.
    private static var maximumRawLength: Int { 48 }

    let value: Value?
    let raw: String

    /// Accepts a number or boolean as well as a string, matching `APINumber` and
    /// `APIBool`: an enum that moves to an integer ladder upstream should surface as an
    /// unrecognized value, not throw and take the response down.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text: String
        if let string = try? container.decode(String.self) {
            text = string
        } else if let number = try? container.decode(Double.self), number.isFinite {
            text = String(number)
        } else if let boolean = try? container.decode(Bool.self) {
            text = boolean ? "true" : "false"
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a string, number, or boolean")
        }
        // Matched before truncating, so a long legitimate value still names its case.
        value = Value(rawValue: text)
        raw = String(text.prefix(Self.maximumRawLength))
    }

    /// The wire string, only when this build has no case for it.
    var unrecognized: String? { value == nil ? raw : nil }
}

/// One array element, decoded without taking the array down with it. A plain `[Value]`
/// is all-or-nothing: one unreadable entry throws for every entry. Decoding
/// `[APIElement<Value>]` keeps the entries this build understands.
struct APIElement<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

enum DateParse {
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func iso(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return (try? Date(string, strategy: isoFractional))
            ?? (try? Date(string, strategy: isoPlain))
    }

    static func epoch(_ value: APINumber?) -> Date? {
        guard let seconds = value?.value, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

enum Fmt {
    /// Windows shorter than this are the rolling session meter; anything longer is
    /// the weekly cap. Both the id and the label derive from this one boundary, so
    /// a window can never come out labelled "Session" while carrying the weekly id.
    static let sessionMaximumSeconds: Double = 21_600

    static func windowID(seconds: Double) -> String {
        seconds > 0 && seconds < sessionMaximumSeconds ? WindowID.session : WindowID.weekly
    }

    static func windowLabel(seconds: Double) -> String {
        if seconds < sessionMaximumSeconds {
            return "Session (\(Int((seconds / 3600).rounded())) hour)"
        }
        if seconds < 172_800 { return "Daily (24 hour)" }
        if seconds < 1_209_600 { return "Weekly (7 day)" }
        return "Limit (\(Int((seconds / 86_400).rounded())) day)"
    }
}
