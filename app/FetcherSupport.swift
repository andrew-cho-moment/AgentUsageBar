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
