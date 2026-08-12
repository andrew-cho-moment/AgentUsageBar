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

    var roundedInt: Int { Int(value.rounded()) }
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
    static func windowLabel(seconds: Double) -> String {
        if seconds < 21_600 { return "Session (\(Int((seconds / 3600).rounded())) hour)" }
        if seconds < 172_800 { return "Daily (24 hour)" }
        if seconds < 1_209_600 { return "Weekly (7 day)" }
        return "Limit (\(Int((seconds / 86_400).rounded())) day)"
    }
}
