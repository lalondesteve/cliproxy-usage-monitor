import Foundation

/// T11a. Burn rate per account and window, in account-% per hour (plan.md "Forecast").
///
/// - The readings of the last `lookback` (60 min) are merged into one series with one
///   reading per `observedAt`: an account read through several credential files gives
///   the highest `usedPercent` at each time, then the lowest `fileKey`.
/// - Consecutive readings form an interval when they are in the same window
///   (`sameWindow`). Other intervals are skipped and their time isn't counted.
/// - The rate is `sum(w * rise) / sum(w * time)` over the counted intervals: plan.md's
///   `sum(rise in used%) / sum(time)`, smoothed by an exponential weight `w` that halves
///   every `halfLife` (20 min) of age at the interval's midpoint, so the last 30 min
///   carry most of the weight. A steady burn gives the same rate under any weighting.
/// - It needs readings at `minimumTimes` (3) distinct times and at least one counted
///   interval. With `local` history, an interval that overlaps a stored gap is skipped,
///   and the three times must fall after the last gap.
public enum BurnRate {
    public static let lookback: TimeInterval = 60 * 60
    public static let halfLife: TimeInterval = 20 * 60
    /// Derived and upstream reset times jitter; two within this agree.
    public static let resetTolerance: TimeInterval = 60
    public static let minimumTimes = 3

    /// The account's rate for `window`, from the store: every credential file of the
    /// account, the readings of the chosen history, and (local only) the stored gaps.
    public static func perHour(account: MergedAccount, _ window: WindowKind,
                               store: any HistoryStore, history: ForecastHistory,
                               now: Date) throws -> Double? {
        let from = now.addingTimeInterval(-lookback)
        let fileKeys = account.credentials.map(\.fileKey)
        guard !fileKeys.isEmpty else { return nil }
        let rows = try store.readings(fileKeys: fileKeys, window, from: from, to: now)
            .filter { $0.provider == account.id.provider && $0.window == window }
        let gaps = history == .local ? try store.gaps(since: from) : []
        return perHour(rows, history: history, gaps: gaps, now: now)
    }

    /// The rate over `readings` of one account and one window (any of its files).
    /// Readings outside the lookback or from the other history are ignored. `halfLife`
    /// nil weighs every interval the same (plan.md's plain formula).
    public static func perHour(_ readings: [SourceReading], history: ForecastHistory,
                               gaps: [DateInterval], now: Date,
                               halfLife: TimeInterval? = BurnRate.halfLife) -> Double? {
        let from = now.addingTimeInterval(-lookback)
        let series = merged(readings.filter {
            history.accepts($0.source) && $0.observedAt >= from && $0.observedAt <= now
        })
        let gaps = history == .local ? gaps.filter { $0.start < now && $0.end > from } : []

        let lastGapEnd = gaps.map(\.end).max() ?? from
        guard series.filter({ $0.observedAt >= lastGapEnd }).count >= minimumTimes else {
            return nil
        }

        var rise = 0.0
        var time = 0.0
        for (a, b) in zip(series, series.dropFirst()) where sameWindow(a, b) {
            if gaps.contains(where: { $0.start < b.observedAt && $0.end > a.observedAt }) {
                continue
            }
            let dt = b.observedAt.timeIntervalSince(a.observedAt)
            let age = now.timeIntervalSince(a.observedAt.addingTimeInterval(dt / 2))
            let w = halfLife.map { pow(0.5, age / $0) } ?? 1
            rise += w * (b.usedPercent - a.usedPercent)
            time += w * dt
        }
        guard time > 0 else { return nil }
        return rise / time * 3600
    }

    /// One reading per `observedAt`, oldest first: the highest `usedPercent` wins, then
    /// the lowest `fileKey` (then the source, so the result doesn't depend on order).
    public static func merged(_ readings: [SourceReading]) -> [SourceReading] {
        let byTime = Dictionary(grouping: readings, by: \.observedAt)
        return byTime.keys.sorted().map { time in
            byTime[time]!.min { a, b in
                if a.usedPercent != b.usedPercent { return a.usedPercent > b.usedPercent }
                if a.fileKey != b.fileKey { return a.fileKey < b.fileKey }
                return a.source.rawValue < b.source.rawValue
            }!
        }
    }

    /// plan.md: two consecutive readings are in the same window when used% didn't
    /// drop and either their resets agree within 60 s or the earlier one was 0% with an
    /// unset reset.
    public static func sameWindow(_ a: SourceReading, _ b: SourceReading) -> Bool {
        guard b.usedPercent >= a.usedPercent else { return false }
        if let ra = a.resetsAt, let rb = b.resetsAt {
            return abs(ra.timeIntervalSince(rb)) <= resetTolerance
        }
        return a.usedPercent == 0 && a.resetsAt == nil
    }
}
