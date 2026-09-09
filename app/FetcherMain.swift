import Darwin
import Foundation

@main
struct FetcherMain {
    private enum Command {
        case usage
        case status
        case all

        init?(arguments: ArraySlice<String>) {
            switch Array(arguments) {
            case []: self = .usage
            case ["--status-only"]: self = .status
            case ["--all"]: self = .all
            default: return nil
            }
        }

        var wantsUsage: Bool {
            switch self {
            case .usage, .all: return true
            case .status: return false
            }
        }

        var wantsStatus: Bool {
            switch self {
            case .status, .all: return true
            case .usage: return false
            }
        }
    }

    private struct FetchResult: Sendable {
        let provider: Provider
        let result: Result<ProviderSnapshot, Error>
    }

    static func main() async {
        guard let command = Command(arguments: CommandLine.arguments.dropFirst()) else {
            exit(2)
        }

        // Usage and status are independent network work, so a combined run overlaps
        // them. That is what lets the app ask one process for both halves instead of
        // paying a second Foundation + CFNetwork launch to fetch them separately.
        async let status = fetchStatus(command.wantsStatus)
        let usage = command.wantsUsage ? await fetchProviders() : []

        emit("V", "1")
        for result in usage {
            switch result.result {
            case .success(let snapshot): emit(snapshot)
            case .failure(let error): emit(result.provider, error: error)
            }
        }
        if let status = await status { emit(status) }
        emit("D", epoch(Date()))
    }

    private static func fetchStatus(_ wanted: Bool) async -> StatusFetchResult? {
        guard wanted else { return nil }
        return await StatusFetcher.fetch()
    }

    private static func fetchProviders() async -> [FetchResult] {
        let providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider()]
        return await withTaskGroup(of: FetchResult.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return FetchResult(
                            provider: provider.provider,
                            result: .success(try await provider.fetch()))
                    } catch {
                        return FetchResult(provider: provider.provider, result: .failure(error))
                    }
                }
            }

            var collected: [FetchResult] = []
            collected.reserveCapacity(providers.count)
            for await result in group { collected.append(result) }
            return collected.sorted { $0.provider.rawValue < $1.provider.rawValue }
        }
    }

    private static func emit(_ status: StatusFetchResult) {
        emit(
            "S",
            status.indicator.rawValue,
            field(status.description),
            field(status.context),
            epoch(status.fetchedAt)
        )
        for component in status.components {
            emit(
                "T",
                field(component.id),
                field(component.name),
                component.status.rawValue,
                component.tracked ? "1" : "0"
            )
        }
    }

    private static func emit(_ snapshot: ProviderSnapshot) {
        emit("P", snapshot.provider.rawValue, "ready", field(snapshot.planLabel))
        for window in snapshot.windows {
            emit(
                "W",
                snapshot.provider.rawValue,
                field(window.id),
                field(window.label),
                String(format: "%.6f", window.percent),
                epoch(window.resetsAt),
                window.isActive ? "1" : "0"
            )
        }
        if let budget = snapshot.budgetReading {
            let unitKind: String
            let unitCode: String
            switch budget.unit {
            case .currency(let code, _):
                unitKind = "currency"
                unitCode = field(code)
            case .credits:
                unitKind = "credits"
                unitCode = ""
            }
            emit(
                "B",
                snapshot.provider.rawValue,
                integer(budget.spentMinor),
                integer(budget.limitMinor),
                unitKind,
                unitCode,
                String(budget.unit.exponent),
                budget.scope?.rawValue ?? "",
                budgetState(budget.state),
                epoch(budget.resetsAt)
            )
        }
        if let balance = snapshot.creditBalanceMinor, let unit = snapshot.creditUnit {
            emit("C", snapshot.provider.rawValue, String(balance), String(unit.exponent))
        }
        for value in snapshot.unrecognized {
            emit("U", snapshot.provider.rawValue, field(value))
        }
    }

    private static func emit(_ provider: Provider, error: Error) {
        switch error as? UsageError {
        case .notLoggedIn: emit("P", provider.rawValue, "signed_out", "")
        case .notInstalled: emit("P", provider.rawValue, "not_installed", "")
        default: emit("P", provider.rawValue, "failed", field(error.localizedDescription))
        }
    }

    private static func emit(_ fields: String...) {
        FileHandle.standardOutput.write(Data((fields.joined(separator: "\t") + "\n").utf8))
    }

    private static func field(_ value: String?) -> String {
        guard let value else { return "" }
        return value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func integer(_ value: Int?) -> String { value.map(String.init) ?? "" }

    private static func epoch(_ value: Date?) -> String {
        value.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? ""
    }

    private static func budgetState(_ value: BudgetState) -> String {
        switch value {
        case .active: return "active"
        case .limitReached: return "limit_reached"
        case .outOfCredits: return "out_of_credits"
        case .disabled(let reason): return "disabled:\(field(reason))"
        }
    }
}
