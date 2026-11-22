import Foundation

/// T11c. Weekly run-out: each account's own weekly burn rate, extrapolated linearly to
/// that account's weekly reset (plan.md "Forecast"). Separate from the 5-hour
/// simulation.
public enum WeeklyRunOutForecast {
    /// The run-out for one account, from its weekly window now (Pool rule 3) and its
    /// weekly rate in account-% per hour.
    public static func runOut(account: MergedAccount, ledger: any LedgerView,
                              ratePerHour: Double?, now: Date) -> WeeklyRunOut {
        let weekly = ForecastWindow(ledger, account.id, .weekly, now: now)
        return WeeklyRunOut(
            account: account.id, alias: account.alias,
            runOut: runOut(remaining: weekly.remaining, resets: weekly.resetsAt,
                           ratePerHour: ratePerHour, now: now),
            resets: weekly.resetsAt)
    }

    /// A weekly window is at most this long, so a run-out further away can't happen
    /// inside it.
    public static let week: TimeInterval = 7 * 24 * 3600

    /// When `remaining` reaches 0 at `ratePerHour`. nil when the window is unknown,
    /// there is no positive rate (even for a window already at 0: the contract's
    /// `runOut` is nil without a rate), or the reset comes first. A window already at 0
    /// with a rate has run out now. With no known reset, a run-out more than a week
    /// away is nil.
    public static func runOut(remaining: Double?, resets: Date?, ratePerHour: Double?,
                              now: Date) -> Date? {
        guard let remaining, let rate = ratePerHour, rate > 0 else { return nil }
        if remaining <= 0 { return now }
        let at = now.addingTimeInterval(remaining / rate * 3600)
        if let resets {
            return at < resets ? at : nil
        }
        return at < now.addingTimeInterval(week) ? at : nil
    }
}
