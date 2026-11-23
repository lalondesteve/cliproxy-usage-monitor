import Foundation

/// T11d. Backtest of the 5-hour lockout forecast (plan.md Phase 3): replay one provider's
/// stored history, forecast at each replay time from what was known then, and compare
/// each forecast with what the same history shows happened next.
///
/// - Replay: at time `t` the ledger is rebuilt from the history alone. Each account's
///   latest reading per window is the newest one at or before `t` (an account read
///   through several credential files gives the highest used% at each time, as the
///   burn rate does). No window counts as reset without a newer reading, since the
///   counter marks behind Pool rule 3 aren't replayed. Then `Forecast.summary` runs at
///   `t` on the same store, so the burn rate only sees readings up to `t`.
/// - Observations come from the accounts routing can use only: the enabled accounts
///   with a credential the simulation would route to (enabled, weight above 0 under
///   weighted round-robin, no `outOfRotation`, `notForcedAccount` or
///   `upstreamUnavailable`), and only the forced account when one is set. Their reading
///   times give the span (first reading at or after the first replay time to the last
///   reading) and, with their reset times, the events below.
/// - What happened: the pool was locked out at an event when every routable account
///   was blocked: its newest 5-hour reading at 100% used and that window not yet
///   reset, or a weekly or monthly reading at 100% used and not yet reset. An account
///   with no 5-hour reading isn't blocked (nothing says it was). A lockout ends at the
///   first event when some account isn't blocked, usually the reset of an empty
///   account.
/// - Stored gaps (local history only; the fork kept polling while the Mac slept):
///   - A lockout first seen at the first reading after a gap began somewhere in it:
///     its start is only bounded, after the last reading before the gap and no later
///     than that first locked reading.
///   - A recovery at a reset inside a gap or at its end is confirmed only when an
///     account the reset unblocks (its blocking window resets then) has its own first
///     reading at or after the gap's end showing it unblocked. Otherwise the pool may
///     have recovered and run out again, or never recovered: the lockout runs on, and
///     its recovery is known only to forecasts made from the gap's end on (they saw
///     the pool locked after it).
///   - A recovery first seen at a reading after a gap (no reset behind it) happened
///     somewhere in the gap: unknown. A reset after the gap has ended is a known
///     recovery.
/// - Each forecast is judged as far as the readings cover it (see `Outcome`).
///
/// Accounts and routing are taken as they are now (the history keeps neither over
/// time); `exhausted`, `coolingDown` and `upstreamUnavailable` describe now, not the
/// past, so the store-based `run` drops them.
public enum Backtest {
    public static let tolerance: TimeInterval = 15 * 60
    /// How far before the first replay time the replay looks for latest readings.
    public static let latestLookback: TimeInterval = 7 * 24 * 3600
    /// plan.md's acceptance window for reproducing a lockout: the forecasts made in the
    /// hour before it starts.
    public static let defaultMaxLead: TimeInterval = 3600

    /// How a forecast made at `t` compares with the observations. Forecasts made before
    /// the span starts are `.notEvaluable` whatever they say. A lockout forecast is
    /// matched with the first observed lockout overlapping `[t, t + 5h)` or, failing
    /// that, starting in `[t, from + tolerance]`; a `.safe` one only within
    /// `[t, t + 5h)`. A lockout forecast ending at or before the last reading before a
    /// hidden start lies wholly in observed time and isn't matched with that lockout.
    public enum Outcome: Equatable, Sendable {
        /// A lockout forecast and an observed one, start (clipped to `t`) and recovery
        /// within `tolerance`.
        case reproduced
        /// A lockout forecast and an observed lockout, but the start or the recovery is
        /// further apart. That includes a forecast recovery well before the last
        /// reading, which still shows the pool locked, and a start outside the bounds
        /// of a start hidden in a gap. Against a hidden start, the recovery counts only
        /// when the forecast has the pool locked at the first locked reading.
        case off
        /// An observed lockout overlaps the horizon, ended or not, and the forecast
        /// said `.safe`.
        case missed
        /// A lockout forecast, none matched, and a reading of a routable account within
        /// `tolerance` after the forecast start shows the pool usable with no reset
        /// between the forecast start and that reading (a reset there could hide a
        /// lockout that began and ended between readings).
        case falseAlarm
        /// `.safe`, and gap-free readings through the horizon show no lockout.
        case safe
        /// Withheld or not enough data.
        case noForecast
        /// The observations don't show whether the forecast was right: made before the
        /// span starts, readings ending or a gap before it could be checked, no usable
        /// reading after a forecast start, or a start or recovery hidden in a gap.
        case notEvaluable

        /// Whether the forecast was checked against what happened.
        public var evaluated: Bool { self != .noForecast && self != .notEvaluable }
    }

    /// A lockout the history shows.
    public struct ObservedLockout: Equatable, Sendable {
        /// When it was first seen. With `earliestStart` set, the latest it can have
        /// started.
        public let start: Date
        /// The first event when a routable account wasn't blocked; nil when the pool
        /// was still locked at the last reading.
        public let end: Date?
        /// Set when the start is hidden in a gap: the last reading before the gap. The
        /// lockout started after it.
        public let earliestStart: Date?
        /// false when a gap hides the recovery (see the type's doc).
        public let recoveryKnown: Bool
        /// With `recoveryKnown` false: the end of the gap after which the pool was seen
        /// locked, when there is one. Forecasts made from then on know the recovery.
        public let recoveryKnownFrom: Date?

        public init(start: Date, end: Date?, earliestStart: Date? = nil, recoveryKnown: Bool = true,
                    recoveryKnownFrom: Date? = nil) {
            self.start = start
            self.end = end
            self.earliestStart = earliestStart
            self.recoveryKnown = recoveryKnown
            self.recoveryKnownFrom = recoveryKnownFrom
        }

        public var startKnown: Bool { earliestStart == nil }

        /// Whether a forecast made at `t` can be checked against the recovery.
        public func recoveryKnown(at t: Date) -> Bool {
            recoveryKnown || recoveryKnownFrom.map { t >= $0 } ?? false
        }

        func overlaps(_ from: Date, _ to: Date) -> Bool { start < to && (end ?? .distantFuture) > from }
    }

    /// What a history shows, as the comparison needs it.
    struct Observations: Equatable, Sendable {
        var span: DateInterval?
        var lockouts: [ObservedLockout]
        var gaps: [DateInterval]
        /// Reading times of routable accounts at which the pool was usable, oldest first.
        var usable: [Date]
        /// Reset times of the routable accounts' windows, oldest first.
        var resets: [Date]

        static let none = Observations(span: nil, lockouts: [], gaps: [], usable: [], resets: [])
    }

    public struct Prediction: Equatable, Sendable {
        public let at: Date
        public let forecast: LockoutForecast
        /// The observed lockout matched with the forecast, start clipped to `at`; nil
        /// when there is none or it hadn't ended by the last reading.
        public let observed: DateInterval?
        public let outcome: Outcome
        /// Some routable account had a 5-hour burn rate at `at` (`BurnRate`'s own
        /// threshold, gaps included): the history was dense enough to forecast.
        public let rated: Bool
    }

    public struct Report: Equatable, Sendable {
        public let provider: Provider
        public let history: ForecastHistory
        /// The routable accounts' first reading at or after the first replay time to
        /// their last reading (which may be past the last replay time); nil without
        /// readings.
        public let span: DateInterval?
        /// Every lockout observed in the span, oldest first.
        public let observed: [ObservedLockout]
        /// The stored gaps the replay honoured (local history only).
        public let gaps: [DateInterval]
        /// The routable accounts' readings from any source between the first and last
        /// replay times, whichever history was replayed.
        public let readingsInRange: Int
        public let predictions: [Prediction]

        public init(provider: Provider, history: ForecastHistory, span: DateInterval?,
                    observed: [ObservedLockout], gaps: [DateInterval] = [], readingsInRange: Int = 0,
                    predictions: [Prediction]) {
            self.provider = provider
            self.history = history
            self.span = span
            self.observed = observed
            self.gaps = gaps
            self.readingsInRange = readingsInRange
            self.predictions = predictions
        }

        /// Observed lockouts that ended, with a known start and recovery.
        public var lockouts: [DateInterval] {
            observed.compactMap { o in
                guard o.startKnown, o.recoveryKnown, let end = o.end else { return nil }
                return DateInterval(start: o.start, end: end)
            }
        }

        /// The start of an observed lockout still running at the end of the span.
        public var unendedLockout: Date? { observed.last.flatMap { $0.end == nil ? $0.start : nil } }

        /// plan.md Phase 3, first half. For each observed lockout (ended, start and
        /// recovery known) that starts after the span does (so the pool was seen above
        /// 0 first) and no later than the last replay time: the forecasts made in the
        /// `maxLead` before it starts and at or after the span starts, leaving out
        /// `.noForecast`. Lockouts the series shows past the replayed range aren't
        /// checked, nor one whose replay times in the `maxLead` before it all come
        /// before the span.
        public func lockoutChecks(maxLead: TimeInterval = Backtest.defaultMaxLead)
            -> [(lockout: DateInterval, predictions: [Prediction])] {
            guard let span, let last = predictions.map(\.at).max() else { return [] }
            return lockouts.filter { $0.start > span.start && $0.start <= last }.compactMap { l in
                let lead = predictions.filter { $0.at >= l.start.addingTimeInterval(-maxLead) && $0.at < l.start }
                let covered = lead.filter { $0.at >= span.start }
                if covered.isEmpty && !lead.isEmpty { return nil }
                return (l, covered.filter { $0.outcome != .noForecast })
            }
        }

        /// The forecasts made while the observed pool stayed above 0, with gap-free
        /// readings, from `BurnRate.lookback` before to the horizon after (so the burn
        /// rate saw no lockout either), and no lockout starting within `tolerance`
        /// after the horizon (a lockout forecast may match it), whatever they said.
        public var safeStretchCandidates: [Prediction] {
            guard let span else { return [] }
            return predictions.filter { p in
                let from = p.at.addingTimeInterval(-BurnRate.lookback)
                let to = p.at.addingTimeInterval(LockoutSimulation.horizon)
                return from >= span.start && to <= span.end
                    && !observed.contains { $0.start <= to.addingTimeInterval(tolerance) && $0.overlaps(from, .distantFuture) }
                    && !gaps.contains { $0.start < to && $0.end > from }
            }
        }

        /// plan.md Phase 3, second half: `safeStretchCandidates` leaving out
        /// `.noForecast`. Each must be `.safe`.
        public var safeStretchPredictions: [Prediction] {
            safeStretchCandidates.filter { $0.outcome != .noForecast }
        }

        /// Why the history fails plan.md's acceptance; empty when it passes:
        /// - a checked lockout without a forecast before it, or with one that doesn't
        ///   reproduce it;
        /// - an `.off` forecast made in the `maxLead` before any observed lockout (ended
        ///   or not, in or past the replayed range); with a start hidden in a gap, made
        ///   in the `maxLead` before its latest start and no later than the last
        ///   reading before the gap. Forecasts made further ahead aren't held to
        ///   plan.md's hour;
        /// - a forecast in a safe stretch that isn't `.safe`;
        /// - any other false alarm or missed lockout;
        /// - a backtest that checked nothing: routable readings in range but none from
        ///   the chosen history inside the replayed range (no span, or one starting
        ///   after the last replay time); or, counting only replay times with a burn
        ///   rate (`Prediction.rated`), rated replay times but none evaluated, or rated
        ///   safe-stretch candidates but none evaluated. A history too sparse for any
        ///   rate isn't held to this.
        public func failures(maxLead: TimeInterval = Backtest.defaultMaxLead) -> [String] {
            var result: [String] = []
            var named = Set<Date>()
            for (l, ps) in lockoutChecks(maxLead: maxLead) {
                if ps.isEmpty {
                    result.append("lockout \(Backtest.text(l)): no forecast in the \(Int(maxLead / 60)) min before it")
                }
                for p in ps where p.outcome != .reproduced {
                    result.append("lockout \(Backtest.text(l)): forecast at \(Backtest.text(p.at)) gave \(p.forecast)")
                    named.insert(p.at)
                }
            }
            for o in observed {
                // A hidden start: the forecasts up to the last reading before the gap.
                func ahead(_ at: Date) -> Bool { o.earliestStart.map { at <= $0 } ?? (at < o.start) }
                for p in predictions where p.outcome == .off && !named.contains(p.at)
                    && p.at >= o.start.addingTimeInterval(-maxLead) && ahead(p.at) {
                    result.append("lockout from \(Backtest.text(o.start)): forecast at \(Backtest.text(p.at)) "
                                  + "gave \(p.forecast)")
                    named.insert(p.at)
                }
            }
            for p in safeStretchPredictions where p.outcome != .safe && !named.contains(p.at) {
                result.append("pool above 0 around \(Backtest.text(p.at)): forecast gave \(p.forecast)")
                named.insert(p.at)
            }
            for p in predictions where (p.outcome == .falseAlarm || p.outcome == .missed) && !named.contains(p.at) {
                result.append("forecast at \(Backtest.text(p.at)) gave \(p.forecast): \(p.outcome)")
            }
            let lastReplay = predictions.map(\.at).max()
            let chosenInRange = span.map { s in lastReplay.map { s.start <= $0 } ?? false } ?? false
            if readingsInRange > 0 && !chosenInRange {
                result.append("\(readingsInRange) readings in range but none from the \(history) history")
            }
            let rated = predictions.filter(\.rated)
            if !rated.isEmpty && !rated.contains(where: \.outcome.evaluated) {
                result.append("\(rated.count) replay times with a burn rate but no forecast could be checked "
                              + "(\(history) history)")
            }
            let candidates = safeStretchCandidates.filter(\.rated)
            if !candidates.isEmpty && !candidates.contains(where: \.outcome.evaluated) {
                result.append("pool above 0 around \(candidates.count) replay times with a burn rate but none "
                              + "of their forecasts could be checked")
            }
            return result
        }
    }

    // MARK: Run

    /// Replays `provider` on `store` with the accounts and routing a restored `Ledger`
    /// has now, at every `step` from `from` through `to`. `history` is the caller's
    /// choice; without one it is the fork's when the store's last history response
    /// served the provider (as T8 picks it), the app's own otherwise. Dynamic
    /// unavailability (`exhausted`, `coolingDown`, `upstreamUnavailable`) is dropped.
    public static func run(_ provider: Provider, store: any HistoryStore,
                           settings: PoolSettings = PoolSettings(), history: ForecastHistory? = nil,
                           from: Date, to: Date, step: TimeInterval = 300) throws -> Report {
        let ledger = Ledger(store: store, settings: settings)
        try ledger.restore()
        let served = try store.forkProviderStates()[provider] == .served
        let accounts = ledger.accounts.filter { $0.id.provider == provider }.map(withoutDynamicUnavailability)
        return try run(provider, accounts: accounts, routing: ledger.routing, store: store,
                       history: history ?? (provider != .go && served ? .fork : .local),
                       at: times(from: from, to: to, step: step))
    }

    /// Replays `provider` at `times` with the given accounts and routing.
    public static func run(_ provider: Provider, accounts: [MergedAccount],
                           routing: [SourceKind: RoutingConfig], store: any HistoryStore,
                           history: ForecastHistory, at times: [Date]) throws -> Report {
        let times = times.sorted()
        let accounts = accounts.filter { $0.id.provider == provider }
        guard let first = times.first, let last = times.last else {
            return Report(provider: provider, history: history, span: nil, observed: [], predictions: [])
        }
        // Everything after the last replay time too: what happened next.
        let from = first.addingTimeInterval(-latestLookback)
        let horizonEnd = last.addingTimeInterval(LockoutSimulation.horizon * 2)
        let series = try Series(accounts, store: store, history: history, from: from, to: horizonEnd)
        let gaps = history == .local
            ? try store.gaps(since: from).filter { $0.end > from && $0.start < horizonEnd }.sorted { $0.start < $1.start }
            : []
        let routable = routable(accounts, routing[provider == .go ? .ocgo : .cliproxy])
        let observations = observe(series, accounts: routable, from: first, gaps: gaps)
        let inRange = try store.readings(fileKeys: routable.flatMap { $0.credentials.map(\.fileKey) }, nil,
                                         from: first, to: last)
            .filter { $0.provider == provider }.count

        var predictions: [Prediction] = []
        for t in times {
            let ledger = ReplayLedger(accounts: accounts, routing: routing, series: series, now: t)
            let summary = try Forecast.summary(provider, ledger: ledger, store: store,
                                               history: history, now: t)
            let rated = try routable.contains {
                try BurnRate.perHour(account: $0, .fiveHour, store: store, history: history, now: t) != nil
            }
            predictions.append(compare(summary.lockout, at: t, observations, rated: rated))
        }
        return Report(provider: provider, history: history, span: observations.span,
                      observed: observations.lockouts, gaps: gaps, readingsInRange: inRange,
                      predictions: predictions)
    }

    public static func times(from: Date, to: Date, step: TimeInterval) -> [Date] {
        guard step > 0, from <= to else { return [] }
        return Array(stride(from: from.timeIntervalSinceReferenceDate,
                            through: to.timeIntervalSinceReferenceDate, by: step))
            .map(Date.init(timeIntervalSinceReferenceDate:))
    }

    // MARK: Comparison

    static func compare(_ forecast: LockoutForecast, at t: Date, _ o: Observations,
                        rated: Bool = true) -> Prediction {
        let end = t.addingTimeInterval(LockoutSimulation.horizon)
        // A lockout forecast over before the last reading before a hidden start lies
        // wholly in observed time: not that lockout.
        let candidates = o.lockouts.filter { l in
            guard case .lockout(_, let to) = forecast, let earliest = l.earliestStart else { return true }
            return to > earliest
        }
        var hit = candidates.first { $0.overlaps(t, end) }
        if hit == nil, case .lockout(let from, _) = forecast {
            hit = candidates.first { $0.start >= t && $0.start <= from.addingTimeInterval(tolerance) }
        }
        func hidden(_ from: Date, _ to: Date) -> Bool { o.gaps.contains { $0.start < to && $0.end > from } }
        let outcome: Outcome
        switch forecast {
        case .withheld, .insufficientData:
            outcome = .noForecast
        case _ where o.span.map({ t < $0.start }) ?? true:
            // Before the first reading: the observations don't cover [t, span start).
            outcome = .notEvaluable
        case .safe:
            if hit != nil { outcome = .missed }
            else if let span = o.span, end <= span.end, !hidden(t, end) { outcome = .safe }
            else { outcome = .notEvaluable }
        case .lockout(let from, let to):
            if let hit {
                outcome = judge(from: from, to: to, against: hit, at: t, span: o.span)
            } else if let seen = o.usable.first(where: { $0 >= from && $0 <= from.addingTimeInterval(tolerance) }),
                      !o.resets.contains(where: { $0 >= from && $0 <= seen }),
                      !hidden(from.addingTimeInterval(-tolerance), from.addingTimeInterval(tolerance)) {
                // A reading shows the pool usable just after the forecast start, and no
                // reset since that start could hide a lockout between readings.
                outcome = .falseAlarm
            } else {
                outcome = .notEvaluable
            }
        }
        let clipped = hit.flatMap { h in h.end.map { DateInterval(start: max(h.start, t), end: $0) } }
        return Prediction(at: t, forecast: forecast, observed: clipped, outcome: outcome, rated: rated)
    }

    private static func judge(from: Date, to: Date, against o: ObservedLockout, at t: Date,
                              span: DateInterval?) -> Outcome {
        let recoveryKnown = o.recoveryKnown(at: t)
        // The forecast recovery is wrong: more than `tolerance` from the observed one,
        // or well before the last reading, which still shows the pool locked.
        let recoveryOff: Bool? = if !recoveryKnown { nil }
            else if let end = o.end { abs(to.timeIntervalSince(end)) > tolerance }
            else if let span, to.addingTimeInterval(tolerance) < span.end { true }
            else { nil }
        if let earliest = o.earliestStart, o.start > t {
            // The start is hidden in a gap: only its bounds can rule the forecast out,
            // and the recovery when the forecast has the pool locked at the first locked
            // reading (one ending before it may be another lockout, inside the gap).
            if from < earliest.addingTimeInterval(-tolerance) || from > o.start.addingTimeInterval(tolerance)
                || (to >= o.start && recoveryOff == true) {
                return .off
            }
            return .notEvaluable
        }
        // Already locked at `t`: the start is `t`, whatever hid the real one.
        guard abs(from.timeIntervalSince(max(o.start, t))) <= tolerance else { return .off }
        switch recoveryOff {
        case true?: return .off
        case false?: return .reproduced
        case nil: return .notEvaluable
        }
    }

    // MARK: What happened

    /// The enabled accounts routing can send traffic to (see the type's doc).
    static func routable(_ accounts: [MergedAccount], _ routing: RoutingConfig?) -> [MergedAccount] {
        accounts.filter { a in
            guard a.enabled, routing?.forcedAccount.map({ $0 == a.id }) ?? true else { return false }
            let strategy = routing?.strategy ?? .roundRobin
            return a.credentials.contains { LockoutSimulation.usableFrom($0, strategy: strategy) != nil }
        }
    }

    /// The routable accounts' span, lockouts, usable reading times and resets (see the
    /// type's doc).
    static func observe(_ series: Series, accounts: [MergedAccount], from first: Date,
                        gaps: [DateInterval]) -> Observations {
        var readers: [Date: Set<AccountID>] = [:]
        var resetTimes = Set<Date>()
        for a in accounts {
            for rs in (series.readings[a.id] ?? [:]).values {
                for r in rs {
                    readers[r.observedAt, default: []].insert(a.id)
                    if let reset = r.resetsAt { resetTimes.insert(reset) }
                }
            }
        }
        let readings = readers.keys.sorted()
        guard let start = readings.first(where: { $0 >= first }), let last = readings.last else {
            return Observations(span: nil, lockouts: [], gaps: gaps, usable: [], resets: [])
        }
        let span = DateInterval(start: start, end: last)
        func locked(_ x: Date) -> Bool { accounts.allSatisfy { series.blocked($0.id, at: x) } }
        // The last reading before `x` when a gap lies between it and `x`: a change
        // first seen at the reading `x` happened somewhere in that gap.
        func hiddenSince(_ x: Date) -> Date? {
            guard let previous = readings.last(where: { $0 < x }),
                  gaps.contains(where: { $0.start < x && $0.end > previous }) else { return nil }
            return previous
        }

        var lockouts: [ObservedLockout] = []
        var open: (start: Date, earliest: Date?, recoveryKnown: Bool, knownFrom: Date?)?
        for x in Set(readings).union(resetTimes).filter({ span.contains($0) }).sorted() {
            if locked(x) {
                if open == nil { open = (x, hiddenSince(x), true, nil) }
                continue
            }
            guard var o = open else { continue }
            if resetTimes.contains(x) {
                if let gap = gaps.first(where: { $0.start <= x && x <= $0.end }) {
                    // A reset while asleep: confirmed only by the own first reading, from
                    // the gap's end on, of an account the reset unblocks, showing it
                    // unblocked.
                    let confirmed = accounts.contains { a in
                        guard series.unblocked(a.id, byResetAt: x),
                              let n = readings.first(where: { $0 >= gap.end && readers[$0]!.contains(a.id) })
                        else { return false }
                        return !series.blocked(a.id, at: n)
                    }
                    if !confirmed {
                        o.recoveryKnown = false
                        o.knownFrom = gap.end
                        open = o
                        continue
                    }
                }
            } else if hiddenSince(x) != nil {
                o.recoveryKnown = false
                o.knownFrom = nil
            }
            lockouts.append(ObservedLockout(start: o.start, end: x, earliestStart: o.earliest,
                                            recoveryKnown: o.recoveryKnown, recoveryKnownFrom: o.knownFrom))
            open = nil
        }
        if let o = open {
            lockouts.append(ObservedLockout(start: o.start, end: nil, earliestStart: o.earliest,
                                            recoveryKnown: o.recoveryKnown, recoveryKnownFrom: o.knownFrom))
        }
        return Observations(span: span, lockouts: lockouts, gaps: gaps,
                            usable: readings.filter { span.contains($0) && !locked($0) },
                            resets: resetTimes.sorted())
    }

    static func text(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }

    static func text(_ i: DateInterval) -> String { "\(text(i.start)) to \(text(i.end))" }

    private static func withoutDynamicUnavailability(_ a: MergedAccount) -> MergedAccount {
        func keep(_ u: [Unavailability]) -> [Unavailability] {
            u.filter { $0 == .outOfRotation || $0 == .notForcedAccount }
        }
        return MergedAccount(
            id: a.id, alias: a.alias, email: a.email, enabled: a.enabled,
            unavailable: keep(a.unavailable),
            credentials: a.credentials.map {
                CredentialRoute(fileKey: $0.fileKey, priority: $0.priority, weight: $0.weight,
                                enabled: $0.enabled, unavailable: keep($0.unavailable))
            },
            colorIndex: a.colorIndex)
    }

    // MARK: Replay state

    /// Each account's readings per window from the chosen history, merged across its
    /// credential files (`BurnRate.merged`), oldest first.
    struct Series: Sendable {
        let readings: [AccountID: [WindowKind: [SourceReading]]]

        init(_ accounts: [MergedAccount], store: any HistoryStore, history: ForecastHistory,
             from: Date, to: Date) throws {
            var readings: [AccountID: [WindowKind: [SourceReading]]] = [:]
            for a in accounts {
                let rows = try store.readings(fileKeys: a.credentials.map(\.fileKey), nil, from: from, to: to)
                    .filter { $0.provider == a.id.provider && history.accepts($0.source) }
                readings[a.id] = Dictionary(grouping: rows, by: \.window).mapValues(BurnRate.merged)
            }
            self.readings = readings
        }


        func latest(_ id: AccountID, _ w: WindowKind, at t: Date) -> SourceReading? {
            guard let rs = readings[id]?[w] else { return nil }
            // Binary search for the first reading after `t`.
            var lo = 0, hi = rs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if rs[mid].observedAt <= t { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 ? rs[lo - 1] : nil
        }

        /// The account can't take traffic at `t` by what its newest readings say.
        func blocked(_ id: AccountID, at t: Date) -> Bool {
            WindowKind.allCases.contains { w in
                guard let r = latest(id, w, at: t), r.usedPercent >= 100 - LockoutSimulation.epsilon else {
                    return false
                }
                return r.resetsAt.map { $0 > t } ?? true
            }
        }

        /// The reset at `x` ends a block of the account's: its newest reading of some
        /// window before `x` is at 100% used and resets at `x`.
        func unblocked(_ id: AccountID, byResetAt x: Date) -> Bool {
            WindowKind.allCases.contains { w in
                guard let r = readings[id]?[w]?.last(where: { $0.observedAt < x }) else { return false }
                return r.usedPercent >= 100 - LockoutSimulation.epsilon && r.resetsAt == x
            }
        }
    }

    /// The ledger as the history alone describes it at `now`.
    struct ReplayLedger: LedgerView {
        let accounts: [MergedAccount]
        let routing: [SourceKind: RoutingConfig]
        let series: Series
        let now: Date

        func latest(_ id: AccountID, _ w: WindowKind) -> WindowReading? {
            series.latest(id, w, at: now).map { WindowReading(account: id, reading: $0) }
        }

        func resetProven(_ id: AccountID, _ w: WindowKind, resetAt: Date) -> Bool { false }
        func unclassified(_ id: AccountID) -> [UnclassifiedReading] { [] }
    }
}
