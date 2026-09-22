import Foundation
import SQLite3

@main
struct CursorDecodeTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            checks += 1
        }
        func decode(_ json: String) throws -> ProviderSnapshot {
            try CursorProvider.decode(Data(json.utf8))
        }
        let pooled = try decode(#"{"membershipType":"enterprise","billingCycleEnd":"2026-01-01T00:00:00.000Z","individualUsage":{"plan":{"enabled":true,"used":1500,"limit":2000,"totalPercentUsed":12.5,"apiPercentUsed":25.5,"autoPercentUsed":5.25}}}"#)
        check(pooled.windows.count == 3, "all reported pools")
        check(pooled.windows[0].percent == 12.5, "use reported percentage, not spend ratio")
        check(pooled.windows[0].id == WindowID.monthly, "monthly headline")
        check(pooled.windows[0].resetsAt != nil, "fractional ISO reset")
        check(pooled.budgetReading == nil, "do not mislabel pooled plan dollars")
        let zero = try decode(#"{"individualUsage":{"plan":{"totalPercentUsed":0,"apiPercentUsed":"0","autoPercentUsed":0}}}"#)
        check(zero.windows.count == 3 && zero.windows.allSatisfy { $0.percent == 0 }, "retain zero meters")
        let overall = try decode(#"{"individualUsage":{"overall":{"used":2500,"limit":10000}}}"#)
        check(overall.windows.first?.percent == 25, "enterprise overall fallback")
        check(overall.budgetReading?.spentMinor == 2500, "overall cents")
        let exceeded = try decode(#"{"individualUsage":{"plan":{"totalPercentUsed":120}}}"#)
        check(exceeded.windows[0].percent == 100 && exceeded.windows[0].isActive, "bounded protocol percentage")
        for invalid in [#"{}"#, #"{"individualUsage":{"plan":{"totalPercentUsed":-1}}}"#,
                        #"{"individualUsage":{"plan":{"enabled":false,"totalPercentUsed":50}}}"#,
                        #"{"individualUsage":{"plan":{"totalPercentUsed":"oops"}}}"#] {
            do { _ = try decode(invalid); preconditionFailure("accepted invalid usage") }
            catch { checks += 1 }
        }
        let payload = Data(#"{"sub":"auth0|user_test"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let token = "header.\(payload).signature"
        let cookie = try CursorProvider.cookie(from: token)
        check(cookie == "user%5Ftest%3A%3A\(token)", "cookie subject extraction and encoding")
        for invalid in ["", "not.jwt", "a.e30.c", token + "; injected=1"] {
            do { _ = try CursorProvider.cookie(from: invalid); preconditionFailure("accepted invalid token") }
            catch { checks += 1 }
        }
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var database: OpaquePointer?
        precondition(sqlite3_open(path, &database) == SQLITE_OK)
        precondition(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT, value TEXT)", nil, nil, nil) == SQLITE_OK)
        precondition(sqlite3_exec(database, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let fromDatabase = try CursorProvider.sessionCookie(databasePath: path)
        check(fromDatabase == cookie, "read IDE SQLite credentials")
        print("\(checks) Cursor tests passed")
    }
}
