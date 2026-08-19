import Foundation

/// Drives `ClaudeProvider.snapshot(from:planLabel:)` over captured response bodies.
///
/// Each case asserts what survives a surprise, because the failure this guards against
/// is not a wrong number but an empty panel: the usage endpoint added `"critical"` to
/// `spend.severity`, one strict enum threw, and the Claude row lost every rate-limit
/// window and its budget to a field that only picks a warning colour.
@main struct ClaudeDecodeTests {
    static var failures = 0
    static var checks = 0

    static let limits = """
        "limits":[
          {"kind":"session","percent":1,"resets_at":null,"scope":null,"is_active":false},
          {"kind":"weekly_all","percent":40,"resets_at":null,"scope":null,"is_active":true}
        ]
        """
    static let spend = """
        "spend":{"used":{"amount_minor":90306,"currency":"USD","exponent":2},
                 "limit":{"amount_minor":100000,"currency":"USD","exponent":2},
                 "severity":"critical","enabled":true,"disabled_reason":null}
        """
    static let extraUsage = """
        "extra_usage":{"is_enabled":true,"monthly_limit":50000,"used_credits":10.0,
                       "decimal_places":2,"currency":"USD","spend_limit_reached":false}
        """
    static let usedOnly = #""used":{"amount_minor":1,"currency":"USD","exponent":2}"#

    static func expect(
        _ name: String,
        _ body: String,
        windows: Int,
        budget: Bool,
        unrecognized: [String]
    ) {
        checks += 1
        guard
            let snapshot = try? ClaudeProvider.snapshot(
                from: Data(body.utf8), planLabel: nil)
        else {
            FileHandle.standardError.write(Data("\(name): whole response was rejected\n".utf8))
            failures += 1
            return
        }
        guard snapshot.windows.count == windows,
            (snapshot.budgetReading != nil) == budget,
            snapshot.unrecognized == unrecognized
        else {
            FileHandle.standardError.write(
                Data(
                    """
                    \(name): expected \(windows) windows, budget \(budget), \
                    \(unrecognized); got \(snapshot.windows.count) windows, \
                    budget \(snapshot.budgetReading != nil), \(snapshot.unrecognized)

                    """.utf8))
            failures += 1
            return
        }
    }

    static func main() {
        expect(
            "healthy response", "{\(limits),\(spend),\(extraUsage)}",
            windows: 2, budget: true, unrecognized: [])

        // The regression: a severity this build has no case for costs nothing but a note.
        expect(
            "unknown severity tier",
            "{\(limits),\"spend\":{\(usedOnly),\"severity\":\"apocalyptic\"}}",
            windows: 2, budget: true, unrecognized: ["spend severity apocalyptic"])
        expect(
            "severity moved to a number ladder",
            "{\(limits),\"spend\":{\(usedOnly),\"severity\":3}}",
            windows: 2, budget: true, unrecognized: ["spend severity 3.0"])

        // Each half of the response is isolated from the other two.
        expect(
            "unreadable spend falls back to extra_usage",
            "{\(limits),\"spend\":5,\(extraUsage)}",
            windows: 2, budget: true, unrecognized: ["spend unreadable"])
        expect(
            "unreadable spend with no fallback loses only the budget",
            "{\(limits),\"spend\":5}",
            windows: 2, budget: false, unrecognized: ["spend unreadable"])
        expect(
            "unreadable extra_usage leaves spend winning",
            "{\(limits),\(spend),\"extra_usage\":\"nope\"}",
            windows: 2, budget: true, unrecognized: ["extra_usage unreadable"])
        expect(
            "unreadable limits leaves the budget",
            "{\"limits\":{\"session\":1},\(spend)}",
            windows: 0, budget: true, unrecognized: ["limits unreadable"])

        // Entries are isolated from each other too, so one window cannot cost the rest.
        expect(
            "a new limit kind drops its own window and names itself",
            "{\"limits\":[{\"kind\":\"session\",\"percent\":1,\"is_active\":false},"
                + "{\"kind\":\"monthly\",\"percent\":9,\"is_active\":true}],\(spend)}",
            windows: 1, budget: true, unrecognized: ["limit kind monthly"])
        expect(
            "a malformed entry drops itself alone",
            "{\"limits\":[{\"kind\":\"session\",\"percent\":1,\"is_active\":false},"
                + "{\"kind\":\"weekly_all\",\"percent\":{\"nested\":1}}],\(spend)}",
            windows: 1, budget: true, unrecognized: ["1 unreadable limits"])

        // Absent and null are ordinary, not surprises, and must not raise a warning.
        expect("absent halves", "{\(limits)}", windows: 2, budget: false, unrecognized: [])
        expect(
            "null halves", "{\(limits),\"spend\":null,\"extra_usage\":null}",
            windows: 2, budget: false, unrecognized: [])

        // A wire string reaches a 256-byte buffer in the panel, so its length is capped.
        checks += 1
        let long = String(repeating: "z", count: 300)
        let snapshot = try? ClaudeProvider.snapshot(
            from: Data("{\(limits),\"spend\":{\(usedOnly),\"severity\":\"\(long)\"}}".utf8),
            planLabel: nil)
        if snapshot?.unrecognized.first?.count != "spend severity ".count + 48 {
            FileHandle.standardError.write(
                Data("long severity was not clamped: \(snapshot?.unrecognized ?? [])\n".utf8))
            failures += 1
        }

        // A body that is not JSON at all is still an error, not an empty success.
        checks += 1
        if (try? ClaudeProvider.snapshot(from: Data("not json".utf8), planLabel: nil)) != nil {
            FileHandle.standardError.write(Data("a non-JSON body was accepted\n".utf8))
            failures += 1
        }

        if failures != 0 { exit(1) }
        print("\(checks) Claude decode tests passed")
    }
}
