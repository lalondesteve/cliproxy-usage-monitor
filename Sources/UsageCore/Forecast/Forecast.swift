import Foundation

/// T11a to T11c together: the `ForecastSummary` for one provider row, a pure function
/// of the ledger, the stored history and the history choice T8 made for the provider.
///
/// - Demand is the sum of the enabled accounts' 5-hour rates (account-% per hour). An
///   account without a rate yet adds nothing as long as another one has a rate; with
///   no rate at all, demand is unknown and the lockout forecast is
///   `.insufficientData`.
/// - `poolBurnPerHour` is demand divided by the number of enabled accounts (the pool
///   share); the simulation gets the undivided sum.
/// - `weekly` has one entry per enabled account, in ledger order.
public enum Forecast {
    public static func summary(_ provider: Provider, ledger: any LedgerView,
                               store: any HistoryStore, history: ForecastHistory,
                               now: Date) throws -> ForecastSummary {
        let accounts = ledger.accounts.filter { $0.id.provider == provider && $0.enabled }
        let rates = try accounts.map {
            try BurnRate.perHour(account: $0, .fiveHour, store: store, history: history, now: now)
        }
        let known = rates.compactMap { $0 }
        let demand: Double? = known.isEmpty ? nil : known.reduce(0, +)

        let weekly = try accounts.map { account in
            WeeklyRunOutForecast.runOut(
                account: account, ledger: ledger,
                ratePerHour: try BurnRate.perHour(account: account, .weekly, store: store,
                                                  history: history, now: now),
                now: now)
        }
        return ForecastSummary(
            poolBurnPerHour: demand.map { $0 / Double(accounts.count) },
            lockout: LockoutSimulation.forecast(provider, ledger: ledger, demandPerHour: demand,
                                                now: now),
            weekly: weekly)
    }
}
