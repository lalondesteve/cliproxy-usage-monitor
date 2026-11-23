import Foundation
import Testing
@testable import UsageCore

// T11d backtest (plan.md Phase 3) on the labeled synthetic histories in
// Fixtures/synthetic/T11d. Every expected time and count comes from the hand-worked
// scenarios in that folder's README.md, not from running the forecast.

private func every5Minutes(_ from: String, _ to: String) -> [Date] {
    Backtest.times(from: t11d(from), to: t11d(to), step: 300)
}

@Suite("T11d backtest on the labeled fixtures")
struct T11dBacktestTests {
    static let providers: [Provider] = [.claude, .codex, .go]

    /// The lockout each history shows, found by the harness, is the labeled one.
    @Test(arguments: providers)
    func observedLockoutIsTheLabeledOne(_ provider: Provider) throws {
        let s = try T11dScenario(provider)
        let report = try s.run()
        #expect(report.lockouts == [s.lockout])
        #expect(report.unendedLockout == nil)
        #expect(report.span == DateInterval(start: s.times.first!, end: s.times.last!))
        // The pool-above-0 labels are the span minus the lockout.
        #expect(s.poolAboveZero == [DateInterval(start: s.times.first!, end: s.lockout.start),
                                    DateInterval(start: s.lockout.end, end: s.times.last!)])
    }

    /// From the third sample (three readings in the last hour) until the lockout ends,
    /// every forecast reproduces the lockout and its recovery within 15 minutes. During
    /// the lockout the observed start is the forecast time.
    @Test(arguments: [(Provider.claude, "11:25"), (.codex, "10:25"), (.go, "10:35")])
    func lockoutAndRecoveryAreReproducedWithin15Minutes(_ provider: Provider, lastInLockout: String) throws {
        let s = try T11dScenario(provider)
        let report = try s.run()
        let byTime = Dictionary(uniqueKeysWithValues: report.predictions.map { ($0.at, $0) })

        for t in every5Minutes("08:00", "08:05") {
            #expect(byTime[t]?.forecast == .insufficientData, "\(provider) \(t)")
        }
        let leading = every5Minutes("08:10", lastInLockout)
        for t in leading {
            let p = try #require(byTime[t])
            #expect(p.outcome == .reproduced, "\(provider) at \(t): \(p.forecast)")
            #expect(p.observed == DateInterval(start: max(s.lockout.start, t), end: s.lockout.end))
        }
        // claude 08:10-11:25, codex 08:10-10:25, go 08:10-10:35.
        #expect(leading.count == ["claude": 40, "codex": 28, "go": 30][provider.rawValue])

        // plan.md's check: the forecasts of the hour before the lockout, all reproduce it.
        let checks = report.lockoutChecks()
        #expect(checks.count == 1)
        #expect(checks.first?.lockout == s.lockout)
        #expect(checks.first?.predictions.map(\.at)
                == Backtest.times(from: s.lockout.start.addingTimeInterval(-3600),
                                  to: s.lockout.start.addingTimeInterval(-300), step: 300))
        #expect(checks.first?.predictions.allSatisfy { $0.outcome == .reproduced } == true)
    }

    /// Where the pool stayed above 0 for the hour before and the 5 hours after a
    /// forecast, the forecast is safe; and no forecast anywhere is a false alarm.
    @Test(arguments: [(Provider.claude, "12:30", "14:00"), (.codex, "11:30", "12:25"),
                      (.go, "11:40", "12:40")])
    func noLockoutIsForecastWhileThePoolStaysAboveZero(_ provider: Provider, from: String,
                                                       to: String) throws {
        let report = try T11dScenario(provider).run()
        #expect(report.safeStretchPredictions.map(\.at) == every5Minutes(from, to))
        #expect(report.safeStretchPredictions.allSatisfy { $0.outcome == .safe && $0.forecast == .safe })
        let wrong = report.predictions.filter { [.falseAlarm, .missed, .off].contains($0.outcome) }
        #expect(wrong.isEmpty, "\(wrong)")
        #expect(report.failures().isEmpty, "\(report.failures())")
    }

    /// Session affinity on: the harness gets a withheld forecast at every replay time,
    /// so the lockout can't be reproduced, and a backtest that checked nothing doesn't
    /// pass. The readings are dense: of the 133 replay times 08:00-19:00, all but 08:00
    /// and 08:05 have three readings in the hour before them, so a burn rate; and the
    /// 19 replay times 12:30-14:00 have the pool above 0 around them. No forecast was
    /// checked.
    @Test func sessionAffinityWithholdsEveryForecast() throws {
        let s = try T11dScenario(.claude, sessionAffinity: true)
        let report = try s.run()
        #expect(!report.predictions.isEmpty)
        #expect(report.predictions.allSatisfy {
            $0.forecast == .withheld(reason: "session affinity is on") && $0.outcome == .noForecast
        })
        #expect(report.lockoutChecks().first?.predictions.isEmpty == true)
        #expect(report.readingsInRange == s.readings.count)
        #expect(report.failures() == [
            "lockout 2026-11-22T10:30:00Z to 2026-11-22T11:30:00Z: no forecast in the 60 min before it",
            "131 replay times with a burn rate but no forecast could be checked (fork history)",
            "pool above 0 around 19 replay times with a burn rate but none of their forecasts could be checked",
        ])
    }

    /// The wrong history for the provider (Claude's readings are all the fork's): the
    /// replay sees no readings, which mustn't pass as "nothing went wrong".
    @Test func aHistoryWithoutTheProvidersReadingsFails() throws {
        let s = try T11dScenario(.claude)
        let report = try Backtest.run(.claude, accounts: s.accounts, routing: s.routing, store: s.store,
                                      history: .local, at: s.times)
        #expect(report.span == nil)
        #expect(report.failures() == ["\(s.readings.count) readings in range but none from the local history"])
    }

    /// A replay that stops at 09:00 on a store that goes on to 19:00: the 10:30 lockout
    /// is seen (the series reads past the last replay time) but starts after the
    /// replayed range, so it isn't checked. The 08:10-09:00 forecasts reproduce it
    /// (README: from the third sample on).
    @Test func aLockoutAfterTheReplayedRangeIsNotChecked() throws {
        let s = try T11dScenario(.claude)
        let report = try Backtest.run(.claude, accounts: s.accounts, routing: s.routing, store: s.store,
                                      history: s.history, at: every5Minutes("08:00", "09:00"))
        #expect(report.lockouts == [s.lockout])
        #expect(report.lockoutChecks().isEmpty)
        #expect(report.predictions.filter { $0.at >= t11d("08:10") }.allSatisfy { $0.outcome == .reproduced })
        #expect(report.failures().isEmpty, "\(report.failures())")
    }

    /// The store-only entry point (accounts and routing from the restored ledger, the
    /// history picked as T8 does) gives the same report as the explicit one.
    @Test(arguments: [(Provider.claude, ForecastHistory.fork), (.go, .local)])
    func storeEntryPointRestoresAccountsRoutingAndHistory(_ provider: Provider,
                                                          expected: ForecastHistory) throws {
        let s = try T11dScenario(provider)
        let kind: SourceKind = provider == .go ? .ocgo : .cliproxy
        let end = s.times.last!
        try s.store.saveLastSnapshot(SourceSnapshot(
            source: kind, takenAt: end,
            accounts: s.accounts.map {
                AccountSnapshot(id: $0.id, fileKey: $0.credentials[0].fileKey, email: nil, enabled: true,
                                // Now, not then: the replay must not apply it to the past.
                                unavailable: [.coolingDown(until: end.addingTimeInterval(3600))],
                                requestCounter: kind == .cliproxy ? 0 : nil,
                                routing: AccountRouting(priority: 0, weight: 1),
                                polledAt: nil, pollError: nil)
            },
            readings: [], unclassified: [], routing: s.routing[kind]))
        try s.store.saveForkProviderStates([.claude: .served, .codex: .paused])

        let report = try Backtest.run(provider, store: s.store, from: s.times.first!, to: end)
        let explicit = try s.run()
        #expect(report.history == expected)
        #expect(report.lockouts == explicit.lockouts)
        #expect(report.predictions.map(\.outcome) == explicit.predictions.map(\.outcome))
        #expect(report.failures().isEmpty)
    }
}

@Suite("T11d backtest comparison")
struct T11dBacktestComparisonTests {
    typealias Lockout = Backtest.ObservedLockout

    // Readings every 5 minutes, 08:00-19:00, the pool usable outside the observed
    // lockouts; a reset ends each ended lockout. By default one lockout, 10:30-11:30.
    let observed = [Lockout(start: t11d("10:30"), end: t11d("11:30"))]
    let span = DateInterval(start: t11d("08:00"), end: t11d("19:00"))

    static func observations(_ lockouts: [Lockout], to end: String = "19:00",
                             readings: [Date]? = nil, resets: [String] = []) -> Backtest.Observations {
        let times = readings ?? Backtest.times(from: t11d("08:00"), to: t11d(end), step: 300)
        return Backtest.Observations(
            span: DateInterval(start: times.first!, end: times.last!), lockouts: lockouts, gaps: [],
            usable: times.filter { t in !lockouts.contains { $0.start <= t && ($0.end ?? .distantFuture) > t } },
            resets: (lockouts.compactMap(\.end) + resets.map(t11d)).sorted())
    }

    func outcome(_ f: LockoutForecast, at hhmm: String, _ o: Backtest.Observations? = nil) -> Backtest.Outcome {
        Backtest.compare(f, at: t11d(hhmm), o ?? Self.observations(observed)).outcome
    }

    @Test func fifteenMinutesIsTheTolerance() {
        #expect(outcome(.lockout(from: t11d("10:45"), to: t11d("11:15")), at: "10:00") == .reproduced)
        #expect(outcome(.lockout(from: t11d("10:46"), to: t11d("11:30")), at: "10:00") == .off)
        #expect(outcome(.lockout(from: t11d("10:30"), to: t11d("11:46")), at: "10:00") == .off)
        // During the lockout the observed start is the forecast time.
        #expect(outcome(.lockout(from: t11d("11:00"), to: t11d("11:30")), at: "11:00") == .reproduced)
        #expect(outcome(.lockout(from: t11d("10:30"), to: t11d("11:30")), at: "11:00") == .off)
    }

    @Test func safeMissedFalseAlarmAndTheHorizon() {
        #expect(outcome(.safe, at: "10:00") == .missed)
        #expect(outcome(.safe, at: "12:00") == .safe)
        #expect(outcome(.lockout(from: t11d("13:00"), to: t11d("14:00")), at: "12:00") == .falseAlarm)
        // The horizon runs past the last reading (14:05 + 5h = 19:05): a safe forecast
        // can't be checked; nor can a lockout from 19:01, with no reading after it.
        #expect(outcome(.safe, at: "14:05") == .notEvaluable)
        #expect(outcome(.lockout(from: t11d("19:01"), to: t11d("19:30")), at: "14:05") == .notEvaluable)
        #expect(outcome(.insufficientData, at: "10:00") == .noForecast)
        #expect(outcome(.withheld(reason: "x"), at: "10:00") == .noForecast)
    }

    /// A forecast is judged once the readings cover what it claims, even with its 5
    /// hours running past the last reading.
    @Test func aForecastIsJudgedWhenTheReadingsCoverIt() {
        // The 18:00 and 15:10 readings show the pool usable: false alarms.
        #expect(outcome(.lockout(from: t11d("18:00"), to: t11d("18:30")), at: "14:05") == .falseAlarm)
        #expect(outcome(.lockout(from: t11d("15:10"), to: t11d("15:20")), at: "15:00") == .falseAlarm)

        // A lockout from 18:00 still running at the last reading (19:00).
        let unended = Self.observations(observed + [Lockout(start: t11d("18:00"), end: nil)])
        #expect(outcome(.safe, at: "14:05", unended) == .missed)
        // Start right; recovery at 18:40 (+15 min = 18:55) but still locked at 19:00.
        #expect(outcome(.lockout(from: t11d("18:00"), to: t11d("18:40")), at: "14:05", unended) == .off)
        // Start right; recovery at 19:10 can't be checked yet.
        #expect(outcome(.lockout(from: t11d("18:05"), to: t11d("19:10")), at: "14:05", unended) == .notEvaluable)
        #expect(outcome(.lockout(from: t11d("18:20"), to: t11d("19:10")), at: "14:05", unended) == .off)
    }

    /// I. Sol's case: at 15:00 the pool has 5% left and burns 30%/h, so it runs out at
    /// 15:10 until a reset at 15:20; the next reading is 15:25, usable. A lockout
    /// 15:10-15:20 fits between the readings, so the forecast can't be called a false
    /// alarm. A reading at 15:12 showing the pool usable, with no reset since 15:10,
    /// does.
    @Test func aFalseAlarmNeedsAReadingShowingThePoolUsable() {
        let readings = Backtest.times(from: t11d("08:00"), to: t11d("15:00"), step: 300)
            + Backtest.times(from: t11d("15:25"), to: t11d("19:00"), step: 300)
        let f = LockoutForecast.lockout(from: t11d("15:10"), to: t11d("15:20"))
        #expect(outcome(f, at: "15:00", Self.observations([], readings: readings, resets: ["15:20"])) == .notEvaluable)
        let read1512 = (readings + [t11d("15:12")]).sorted()
        #expect(outcome(f, at: "15:00", Self.observations([], readings: read1512, resets: ["15:20"])) == .falseAlarm)

        // Before the first reading (08:00) nothing covers the forecast's first minutes:
        // not evaluable, whatever it says.
        #expect(outcome(.safe, at: "07:00") == .notEvaluable)
        #expect(outcome(.lockout(from: t11d("07:30"), to: t11d("08:00")), at: "07:00") == .notEvaluable)
    }

    /// J. A lockout forecast is matched with a lockout starting just past its horizon,
    /// within 15 minutes of its start; `.safe` keeps the 5 hours.
    @Test func aLockoutForecastMatchesALockoutJustPastItsHorizon() {
        // Sol's case: 14:05 + 5h = 19:05; the lockout 19:10-19:45 (readings to 20:00).
        let late = Self.observations(observed + [Lockout(start: t11d("19:10"), end: t11d("19:45"))], to: "20:00")
        #expect(outcome(.lockout(from: t11d("19:00"), to: t11d("19:45")), at: "14:05", late) == .reproduced)
        // Neon's case: a lockout first seen at the last reading, 19:00. The forecast
        // start 18:45 is within 15 minutes; the recovery can't be checked.
        let atEnd = Self.observations(observed + [Lockout(start: t11d("19:00"), end: nil)])
        #expect(outcome(.lockout(from: t11d("18:45"), to: t11d("19:30")), at: "14:00", atEnd) == .notEvaluable)
        #expect(outcome(.safe, at: "14:00", atEnd) == .safe)

        // 14:00's 5 hours end at 19:00 and the 19:10 lockout starts within 15 minutes
        // of that, so 14:00 isn't a safe-stretch time; 13:50 (to 18:50, + 15 min =
        // 19:05) is.
        let report = Backtest.Report(
            provider: .claude, history: .fork, span: late.span, observed: late.lockouts,
            predictions: [Backtest.compare(.safe, at: t11d("13:50"), late),
                          Backtest.compare(.safe, at: t11d("14:00"), late)])
        #expect(report.safeStretchCandidates.map(\.at) == [t11d("13:50")])
    }

    /// K. Sol's case: the only checked forecast, at 17:30, gets the 18:00 start right
    /// but has the pool usable from 18:40, while it is still locked at 19:00. And a
    /// replay ending at 09:55, before a 10:00-11:00 lockout: the 09:30 forecast's start
    /// is 30 minutes late. Both are in the hour before the lockout; the 08:30 forecast
    /// is further ahead and isn't held to it.
    @Test func anOffForecastInTheHourBeforeALockoutFails() {
        let unended = Self.observations([Lockout(start: t11d("18:00"), end: nil)])
        let report = Backtest.Report(
            provider: .claude, history: .fork, span: span, observed: unended.lockouts,
            predictions: [Backtest.compare(.lockout(from: t11d("18:00"), to: t11d("18:40")),
                                           at: t11d("17:30"), unended)])
        #expect(report.predictions.map(\.outcome) == [.off])
        #expect(report.failures() == ["lockout from 2026-11-22T18:00:00Z: forecast at 2026-11-22T17:30:00Z gave "
                                      + "lockout(from: 2026-11-22 18:00:00 +0000, to: 2026-11-22 18:40:00 +0000)"])

        let ten = Self.observations([Lockout(start: t11d("10:00"), end: t11d("11:00"))])
        let late = LockoutForecast.lockout(from: t11d("10:30"), to: t11d("11:00"))
        let early = Backtest.Report(
            provider: .claude, history: .fork, span: span, observed: ten.lockouts,
            predictions: [Backtest.compare(late, at: t11d("08:30"), ten),
                          Backtest.compare(late, at: t11d("09:30"), ten),
                          Backtest.compare(.lockout(from: t11d("10:00"), to: t11d("11:00")), at: t11d("09:55"), ten)])
        #expect(early.predictions.map(\.outcome) == [.off, .off, .reproduced])
        #expect(early.lockoutChecks().isEmpty)
        #expect(early.failures() == ["lockout from 2026-11-22T10:00:00Z: forecast at 2026-11-22T09:30:00Z gave "
                                     + "lockout(from: 2026-11-22 10:30:00 +0000, to: 2026-11-22 11:00:00 +0000)"])
    }

    /// O. A start hidden in a gap still has bounds: after the last reading before the
    /// gap, no later than the first locked reading.
    @Test func aStartHiddenInAGapStillRulesOutForecasts() {
        // Sol's case: usable at 12:00, asleep, locked at 12:10, the last reading. A
        // forecast start of 12:30 is past 12:10 + 15 min; 12:05 could be right.
        let sol = Self.observations([Lockout(start: t11d("12:10"), end: nil, earliestStart: t11d("12:00"))],
                                    readings: every5Minutes("08:00", "12:00") + [t11d("12:10")])
        #expect(outcome(.lockout(from: t11d("12:30"), to: t11d("13:00")), at: "11:30", sol) == .off)
        #expect(outcome(.lockout(from: t11d("12:05"), to: t11d("13:00")), at: "11:30", sol) == .notEvaluable)
        // Neon's case: first seen locked at 12:40 (last reading before the gap 11:55),
        // recovered at 14:00. A 13:10 start is past 12:55; a 12:20 start fits but a
        // 16:00 recovery is two hours off; 12:20-14:10 can't be ruled out. Nor can
        // 12:00-12:20: it ends before the 12:40 reading, so it may be another lockout
        // inside the gap.
        let neon = Self.observations([Lockout(start: t11d("12:40"), end: t11d("14:00"), earliestStart: t11d("11:55"))])
        #expect(outcome(.lockout(from: t11d("13:10"), to: t11d("16:00")), at: "11:30", neon) == .off)
        #expect(outcome(.lockout(from: t11d("12:20"), to: t11d("16:00")), at: "11:30", neon) == .off)
        #expect(outcome(.lockout(from: t11d("12:20"), to: t11d("14:10")), at: "11:30", neon) == .notEvaluable)
        #expect(outcome(.lockout(from: t11d("12:00"), to: t11d("12:20")), at: "11:30", neon) == .notEvaluable)
    }

    /// N. Neon's case: locked at 11:55, asleep to 12:40, locked from then to 17:00. A
    /// forecast made at 14:00 saw the pool locked after the gap, so its recovery is
    /// checked: 15:00 is two hours early. One made at 11:30 can't be.
    @Test func aRecoveryIsKnownToForecastsMadeAfterTheGap() {
        let neon = Self.observations([Lockout(start: t11d("11:55"), end: t11d("17:00"), recoveryKnown: false,
                                              recoveryKnownFrom: t11d("12:40"))])
        #expect(outcome(.lockout(from: t11d("14:00"), to: t11d("15:00")), at: "14:00", neon) == .off)
        #expect(outcome(.lockout(from: t11d("14:00"), to: t11d("17:00")), at: "14:00", neon) == .reproduced)
        #expect(outcome(.lockout(from: t11d("11:55"), to: t11d("12:00")), at: "11:30", neon) == .notEvaluable)
    }

    /// Q. The first reading is at 08:01 and a lockout runs 08:05-09:00. The only replay
    /// time in the hour before it, 08:00, comes before the first reading, so its
    /// forecast can't be checked, and the lockout isn't checked either (not "no
    /// forecast" or a failed forecast). At 08:05 the forecast is the running lockout.
    @Test func aLockoutWithNoReplayTimeAfterTheFirstReadingIsntChecked() {
        let readings = [t11d("08:01")] + every5Minutes("08:05", "19:00")
        let o = Backtest.Observations(
            span: DateInterval(start: t11d("08:01"), end: t11d("19:00")),
            lockouts: [Lockout(start: t11d("08:05"), end: t11d("09:00"))], gaps: [],
            usable: readings.filter { $0 < t11d("08:05") || $0 >= t11d("09:00") }, resets: [t11d("09:00")])
        let f = LockoutForecast.lockout(from: t11d("08:05"), to: t11d("09:00"))
        let report = Backtest.Report(
            provider: .claude, history: .fork, span: o.span, observed: o.lockouts,
            predictions: [Backtest.compare(f, at: t11d("08:00"), o), Backtest.compare(f, at: t11d("08:05"), o)])
        #expect(report.predictions.map(\.outcome) == [.notEvaluable, .reproduced])
        #expect(report.lockoutChecks().isEmpty)
        #expect(report.failures().isEmpty, "\(report.failures())")
    }

    /// S, Sol's case. Usable at 11:45 and 12:00, asleep 12:02-12:40, first seen locked
    /// at 12:40: the lockout started after 12:00. The 11:30 forecast 11:45-11:55 is over
    /// before 12:00, so it isn't that lockout, and the 11:45 reading shows the pool
    /// usable: a false alarm. One running past 12:00 is still matched with it.
    @Test func aForecastOverBeforeAHiddenStartIsJudgedOnTheReadings() {
        let o = Backtest.Observations(
            span: DateInterval(start: t11d("08:00"), end: t11d("12:40")),
            lockouts: [Lockout(start: t11d("12:40"), end: nil, earliestStart: t11d("12:00"))],
            gaps: [DateInterval(start: t11d("12:02"), end: t11d("12:40"))],
            usable: every5Minutes("08:00", "12:00"), resets: [])
        #expect(outcome(.lockout(from: t11d("11:45"), to: t11d("11:55")), at: "11:30", o) == .falseAlarm)
        #expect(outcome(.lockout(from: t11d("11:45"), to: t11d("12:05")), at: "11:30", o) == .notEvaluable)
    }

    /// U, Fable's case. Usable at 12:00, asleep, first seen locked at 12:10: the start
    /// is hidden in (12:00, 12:10]. Forecasts made 11:05-11:55 start at 12:30, past
    /// 12:10 + 15 min, so all are off. Those made in the hour before the latest start
    /// (11:10 on) and before the gap fail; 11:05 is further ahead.
    @Test func anOffForecastBeforeAHiddenStartFails() {
        let o = Self.observations([Lockout(start: t11d("12:10"), end: nil, earliestStart: t11d("12:00"))],
                                  readings: every5Minutes("08:00", "12:00") + [t11d("12:10")])
        let f = LockoutForecast.lockout(from: t11d("12:30"), to: t11d("13:00"))
        let report = Backtest.Report(provider: .claude, history: .fork, span: o.span, observed: o.lockouts,
                                     predictions: every5Minutes("11:05", "11:55").map { Backtest.compare(f, at: $0, o) })
        #expect(report.predictions.count == 11)
        #expect(report.predictions.allSatisfy { $0.outcome == .off })
        #expect(report.failures() == every5Minutes("11:10", "11:55").map {
            "lockout from 2026-11-22T12:10:00Z: forecast at \(Backtest.text($0)) gave "
                + "lockout(from: 2026-11-22 12:30:00 +0000, to: 2026-11-22 13:00:00 +0000)"
        })
    }

    /// Both kinds of wrong forecast count as failures outside the plan's two checks.
    /// 08:30 has no hour of readings before it (not a safe-stretch time); its 5 hours
    /// end at 13:30, before the 18:00 lockout, and the readings show 08:40 usable. The
    /// 14:05 forecast's 5 hours see the 18:00 lockout start.
    @Test func falseAlarmsAndMissesOutsideTheChecksAreFailures() {
        let unended = Self.observations([Lockout(start: t11d("18:00"), end: nil)])
        let report = Backtest.Report(
            provider: .claude, history: .fork, span: span, observed: unended.lockouts,
            predictions: [Backtest.compare(.lockout(from: t11d("08:40"), to: t11d("08:50")),
                                           at: t11d("08:30"), unended),
                          Backtest.compare(.safe, at: t11d("14:05"), unended)])
        #expect(report.safeStretchCandidates.isEmpty)
        #expect(report.predictions.map(\.outcome) == [.falseAlarm, .missed])
        #expect(report.failures() == [
            "forecast at 2026-11-22T08:30:00Z gave lockout(from: 2026-11-22 08:40:00 +0000, to: 2026-11-22 08:50:00 +0000): falseAlarm",
            "forecast at 2026-11-22T14:05:00Z gave safe: missed",
        ])
    }

    @Test func failuresNameEachWrongForecast() {
        let o = Self.observations(observed)
        func p(_ hhmm: String, _ f: LockoutForecast) -> Backtest.Prediction {
            Backtest.compare(f, at: t11d(hhmm), o)
        }
        let report = Backtest.Report(
            provider: .claude, history: .fork, span: span, observed: observed,
            predictions: [p("09:30", .lockout(from: t11d("10:30"), to: t11d("11:30"))),
                          p("10:00", .safe),
                          p("12:30", .lockout(from: t11d("15:00"), to: t11d("16:00"))),
                          p("13:00", .safe)])
        // 10:00 missed the lockout. 12:30's hour before and 5 hours after (11:30-17:30)
        // stay clear of the lockout, so its forecast should have been safe.
        #expect(report.failures().count == 2)
        #expect(report.safeStretchPredictions.map(\.at) == [t11d("12:30"), t11d("13:00")])
    }
}

/// The same backtest on a real store, when one is present: a copy of the app's
/// history.sqlite at Fixtures/live/history.sqlite, or the path in
/// USAGE_MONITOR_BACKTEST_DB. The file is copied first: opening the store migrates it.
/// USAGE_MONITOR_BACKTEST_HISTORY picks the history per provider ("claude=fork,
/// codex=local"); the others use the store's saved fork states, as T8 does. Every
/// provider with readings is replayed, and one whose forecasts couldn't be checked
/// fails (`Report.failures`).
@Suite("T11d backtest on real history")
struct T11dRealHistoryBacktestTests {
    static var source: URL? {
        if let path = ProcessInfo.processInfo.environment["USAGE_MONITOR_BACKTEST_DB"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let live = Fixtures.url("live/history.sqlite")
        return FileManager.default.fileExists(atPath: live.path) ? live : nil
    }

    /// "claude=fork,codex=local" to a history per provider.
    static func histories(_ text: String?) throws -> [Provider: ForecastHistory] {
        var result: [Provider: ForecastHistory] = [:]
        for pair in (text ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let p = Provider(rawValue: parts[0]),
                  let h = ForecastHistory(rawValue: parts[1]) else {
                throw T11dScenario.FixtureError("bad USAGE_MONITOR_BACKTEST_HISTORY entry: \(pair)")
            }
            result[p] = h
        }
        return result
    }

    @Test func historyChoicesParse() throws {
        #expect(try Self.histories("claude=local, codex=fork") == [.claude: .local, .codex: .fork])
        #expect(try Self.histories(nil).isEmpty)
        #expect(throws: T11dScenario.FixtureError.self) { try Self.histories("claude=cloud") }
    }

    @Test(.enabled(if: source != nil,
                   "No real history: set USAGE_MONITOR_BACKTEST_DB or add Fixtures/live/history.sqlite"))
    func realHistoryPassesThePlansBacktest() throws {
        let source = try #require(Self.source)
        let chosen = try Self.histories(ProcessInfo.processInfo.environment["USAGE_MONITOR_BACKTEST_HISTORY"])
        let db = T5TempDatabase()
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: db.path + suffix))
            }
        }
        let result = try Self.backtest(try SQLiteHistoryStore(path: db.path, retention: nil), histories: chosen)
        #expect(result.replayed > 0)
        #expect(result.problems.isEmpty, "\(result.problems)")
    }

    /// Replays the last 7 days of every provider with readings from any source. A
    /// provider's problems: its `failures()`, or none of its readings under the
    /// restored accounts' credential files (nothing to replay).
    static func backtest(_ store: SQLiteHistoryStore, histories: [Provider: ForecastHistory]) throws
        -> (replayed: Int, problems: [String]) {
        var replayed = 0
        var problems: [String] = []
        for provider in Provider.allCases {
            let last = try ReadingSource.allCases.compactMap { try store.lastObservation(provider, source: $0) }.max()
            guard let last else { continue }
            let report = try Backtest.run(provider, store: store, history: histories[provider],
                                          from: last.addingTimeInterval(-7 * 24 * 3600), to: last)
            replayed += 1
            if report.readingsInRange == 0 {
                problems.append("\(provider): readings up to \(Backtest.text(last)) but none under the "
                                + "restored accounts' credential files")
            }
            problems += report.failures().map { "\(provider) (\(report.history)): \($0)" }
        }
        return (replayed, problems)
    }

    /// The real-history check on the labeled Claude history: without a saved snapshot
    /// the ledger restores no accounts, which is a problem rather than a pass; with
    /// one, the 7 days before 19:00 replay clean (the labeled backtest above).
    @Test func theRealHistoryCheckNeedsAccountsAndPassesTheLabeledHistory() throws {
        let s = try T11dScenario(.claude)
        let bare = try Self.backtest(s.store, histories: [:])
        #expect(bare.replayed == 1)
        #expect(bare.problems == ["claude: readings up to 2026-11-22T19:00:00Z but none under the "
                                  + "restored accounts' credential files"])

        try s.store.saveLastSnapshot(SourceSnapshot(
            source: .cliproxy, takenAt: t11d("19:00"),
            accounts: s.accounts.map {
                AccountSnapshot(id: $0.id, fileKey: $0.credentials[0].fileKey, email: nil, enabled: true,
                                unavailable: [], requestCounter: 0,
                                routing: AccountRouting(priority: 0, weight: 1), polledAt: nil, pollError: nil)
            },
            readings: [], unclassified: [], routing: s.routing[.cliproxy]))
        try s.store.saveForkProviderStates([.claude: .served])
        let restored = try Self.backtest(s.store, histories: [:])
        #expect(restored.replayed == 1)
        #expect(restored.problems.isEmpty, "\(restored.problems)")
        // The wrong history, chosen by the caller: nothing could be checked.
        #expect(try Self.backtest(s.store, histories: [.claude: .local]).problems
                == ["claude (local): \(s.readings.count) readings in range but none from the local history"])
    }
}

/// Short histories written out by hand in each test, for cases the labeled fixtures
/// don't have: accounts routing can't use, and stored gaps on local history.
@Suite("T11d backtest on hand-written histories")
struct T11dHandHistoryBacktestTests {
    typealias H = T11dHandHistory

    /// Two accounts. `busy`: 64% used at 08:00, +3 per 5 minutes (36%/h), 100% at 09:00
    /// until its 10:00 reset, then 0% and +3 per 5 minutes again to 10:30. `idle`: 10%
    /// throughout (reset 12:00). Routing can't send anything to `idle` (Go forced to
    /// `busy`; Claude weighted round-robin with `idle`'s credential at weight 0), so
    /// the pool is locked 09:00-10:00 although `idle` has 90% left.
    ///
    /// Forecast at 08:10 + 5k (k = 0...9): `busy` has 30 - 3k left at 0.6 per minute,
    /// 50 - 5k minutes, so it runs out at 09:00 every time, until its 10:00 reset. At
    /// 09:00 the pool is already locked, to the same reset.
    @Test(arguments: [Provider.go, .claude])
    func anAccountRoutingCantUseDoesntHoldThePoolOpen(_ provider: Provider) throws {
        let source: ReadingSource = provider == .go ? .ocgo : .passive
        let busyKey = "\(provider.rawValue)-busy.json", idleKey = "\(provider.rawValue)-idle.json"
        let busy = H.account(provider, "busy", busyKey)
        let idle = H.account(provider, "idle", idleKey, weight: provider == .go ? 1 : 0, index: 1)
        let routing: [SourceKind: RoutingConfig] = provider == .go
            ? [.ocgo: RoutingConfig(strategy: .mostHeadroom, sessionAffinity: false, forcedAccount: busy.id)]
            : [.cliproxy: RoutingConfig(strategy: .weightedRoundRobin, sessionAffinity: false, forcedAccount: nil)]
        let readings =
            H.every5Minutes(provider, busyKey, source, from: "08:00", to: "09:55", resetsAt: "10:00") {
                min(64 + 3 * Double($0), 100)
            }
            + H.every5Minutes(provider, busyKey, source, from: "10:00", to: "10:30", resetsAt: "15:00") {
                3 * Double($0)
            }
            + H.every5Minutes(provider, idleKey, source, from: "08:00", to: "10:30", resetsAt: "12:00") { _ in 10 }
        let history = try H(readings)

        let report = try Backtest.run(provider, accounts: [busy, idle], routing: routing, store: history.store,
                                      history: .local, at: every5Minutes("08:00", "09:00"))
        let lockout = DateInterval(start: t11d("09:00"), end: t11d("10:00"))
        #expect(report.lockouts == [lockout])
        #expect(report.predictions.prefix(2).allSatisfy { $0.forecast == .insufficientData })
        for p in report.predictions.dropFirst(2) {
            #expect(p.outcome == .reproduced, "\(provider) at \(p.at): \(p.forecast)")
            #expect(p.observed == DateInterval(start: max(t11d("09:00"), p.at), end: t11d("10:00")))
        }
        #expect(report.lockoutChecks().map(\.lockout) == [lockout])
        #expect(report.failures().isEmpty, "\(report.failures())")
    }

    enum Wake: String, CaseIterable, Sendable {
        /// Last reading 11:55 at 100%; asleep 11:56-12:40; 12:40-12:50 at 100% (reset 17:00).
        case stillLocked
        /// The same, but 12:40-12:50 at 20%: the 12:00 reset happened.
        case recovered
        /// Last reading 11:50 at 97.5%; asleep 11:51-12:40; 12:40-12:50 at 100%.
        case lockedWhileAsleep
    }

    /// Codex, one account, fill-first, local passive readings: 57.5% at 10:30, +2.5 per
    /// 5 minutes (30%/h), reset 12:00. Forecast at 10:40 + 5k (k = 0...14): 37.5 - 2.5k
    /// left at 0.5 per minute lasts 75 - 5k minutes, so it runs out at 11:55 every time,
    /// to the 12:00 reset. The Mac then sleeps through that reset:
    /// - still locked when it wakes: the pool may have recovered at 12:00 and run out
    ///   again, or not recovered at all, so the recovery is unknown and the forecasts
    ///   can't be checked against it;
    /// - recovered when it wakes: the reset is shown, the lockout is 11:55-12:00 and the
    ///   forecasts reproduce it;
    /// - asleep before 11:55: the lockout first seen at 12:40 began somewhere in the
    ///   gap, so its start is unknown too.
    @Test(arguments: Wake.allCases)
    func aRecoveryOrStartHiddenInAGapIsntJudged(_ wake: Wake) throws {
        let key = "codex-a.json"
        let a = H.account(.codex, "a", key)
        let routing: [SourceKind: RoutingConfig] =
            [.cliproxy: RoutingConfig(strategy: .fillFirst, sessionAffinity: false, forcedAccount: nil)]
        let lastBefore = wake == .lockedWhileAsleep ? "11:50" : "11:55"
        let sleep = DateInterval(start: t11d(wake == .lockedWhileAsleep ? "11:51" : "11:56"), end: t11d("12:40"))
        let readings =
            H.every5Minutes(.codex, key, .passive, from: "10:30", to: lastBefore, resetsAt: "12:00") {
                57.5 + 2.5 * Double($0)
            }
            + H.every5Minutes(.codex, key, .passive, from: "12:40", to: "12:50", resetsAt: "17:00") { _ in
                wake == .recovered ? 20 : 100
            }
        let history = try H(readings, gaps: [sleep])

        let report = try Backtest.run(.codex, accounts: [a], routing: routing, store: history.store,
                                      history: .local, at: every5Minutes("10:30", "11:50"))
        #expect(report.gaps == [sleep])
        let observed: [Backtest.ObservedLockout]
        let outcome: Backtest.Outcome
        switch wake {
        case .stillLocked:
            // Forecasts made from the 12:40 wake-up on would know the recovery.
            observed = [.init(start: t11d("11:55"), end: nil, recoveryKnown: false, recoveryKnownFrom: t11d("12:40"))]
            outcome = .notEvaluable
        case .recovered:
            observed = [.init(start: t11d("11:55"), end: t11d("12:00"))]
            outcome = .reproduced
        case .lockedWhileAsleep:
            // Started after the 11:50 reading. The forecast 11:55-12:00 ends before the
            // 12:40 reading, so it may be another lockout inside the gap.
            observed = [.init(start: t11d("12:40"), end: nil, earliestStart: t11d("11:50"))]
            outcome = .notEvaluable
        }
        #expect(report.observed == observed)
        #expect(report.predictions.prefix(2).allSatisfy { $0.forecast == .insufficientData })
        for p in report.predictions.dropFirst(2) {
            #expect(p.outcome == outcome, "\(wake) at \(p.at): \(p.forecast)")
        }
        // The 11:55 lockout starts after the last replay time (11:50): never checked.
        #expect(report.lockoutChecks().isEmpty)
    }

    static let fillFirst: [SourceKind: RoutingConfig] =
        [.cliproxy: RoutingConfig(strategy: .fillFirst, sessionAffinity: false, forcedAccount: nil)]

    /// I, Neon's case. Codex, one account: 45% at 07:01, +5 per 5 minutes, 100% at
    /// 07:56 until its 08:01 reset, then 0%. Replayed at 08:00 only: the pool is locked
    /// until 08:01, so the forecast is a lockout 08:00-08:01. The readings from 08:01 on
    /// show the pool usable, but nothing covers 08:00-08:01: not a false alarm.
    @Test func aForecastBeforeTheFirstReadingIsntAFalseAlarm() throws {
        let key = "codex-a.json"
        let readings =
            H.every5Minutes(.codex, key, .passive, from: "07:01", to: "07:56", resetsAt: "08:01") {
                45 + 5 * Double($0)
            }
            + H.every5Minutes(.codex, key, .passive, from: "08:01", to: "08:31", resetsAt: "13:01") { _ in 0 }
        let history = try H(readings)
        let report = try Backtest.run(.codex, accounts: [H.account(.codex, "a", key)], routing: Self.fillFirst,
                                      store: history.store, history: .local, at: [t11d("08:00")])
        #expect(report.span == DateInterval(start: t11d("08:01"), end: t11d("08:31")))
        #expect(report.predictions.map(\.forecast) == [.lockout(from: t11d("08:00"), to: t11d("08:01"))])
        #expect(report.predictions.map(\.outcome) == [.notEvaluable])
        // Twelve readings in the hour before 08:00 give a burn rate, so the replay time
        // counts as one that should have been checked.
        #expect(report.failures() == ["1 replay times with a burn rate but no forecast could be checked "
                                      + "(local history)"])
    }

    /// L, Sol's case. Go forced to `a`: `a` 57.5% at 10:30, +2.5 per 5 minutes, 100% at
    /// 11:55 until its 12:00 reset; `b` at 10% throughout. Asleep 11:56-12:40. `b` is
    /// read at 12:40, `a` at 12:45, still 100% (reset 17:00). `b` can't take traffic,
    /// so its 12:40 reading doesn't show the pool recovered; `a`'s at 12:45 shows it
    /// locked. The 12:00 recovery is unknown, known to forecasts made from 12:40 on.
    @Test func onlyRoutableAccountsConfirmARecoveryAfterAGap() throws {
        let keyA = "go-a.json", keyB = "go-b.json"
        let a = H.account(.go, "a", keyA), b = H.account(.go, "b", keyB, index: 1)
        let routing: [SourceKind: RoutingConfig] =
            [.ocgo: RoutingConfig(strategy: .mostHeadroom, sessionAffinity: false, forcedAccount: a.id)]
        let readings =
            H.every5Minutes(.go, keyA, .ocgo, from: "10:30", to: "11:55", resetsAt: "12:00") { 57.5 + 2.5 * Double($0) }
            + H.every5Minutes(.go, keyA, .ocgo, from: "12:45", to: "12:45", resetsAt: "17:00") { _ in 100 }
            + H.every5Minutes(.go, keyB, .ocgo, from: "10:30", to: "11:55", resetsAt: "15:00") { _ in 10 }
            + H.every5Minutes(.go, keyB, .ocgo, from: "12:40", to: "12:40", resetsAt: "15:00") { _ in 10 }
        let sleep = DateInterval(start: t11d("11:56"), end: t11d("12:40"))
        let history = try H(readings, gaps: [sleep])
        let report = try Backtest.run(.go, accounts: [a, b], routing: routing, store: history.store,
                                      history: .local, at: every5Minutes("10:30", "11:50"))
        #expect(report.observed == [.init(start: t11d("11:55"), end: nil, recoveryKnown: false,
                                          recoveryKnownFrom: t11d("12:40"))])
        #expect(report.span == DateInterval(start: t11d("10:30"), end: t11d("12:45")))
        // `a`'s 17 readings 10:30-11:50; `b`'s 18 aren't counted.
        #expect(report.readingsInRange == 17)
    }

    /// M. Codex, one account, 57.5% at 10:30, +2.5 per 5 minutes, 100% at 11:55 until
    /// its 12:40 reset; asleep 11:56-12:40; read at 12:40 at 20%. The reset is at the
    /// gap's end and the 12:40 reading shows the account usable: a known recovery. The
    /// forecasts from 10:40 on (37.5 - 2.5k left at 0.5 per minute) run out at 11:55
    /// until 12:40 and reproduce it.
    @Test func aResetAtTheGapsEndConfirmedByItsReadingIsKnown() throws {
        let key = "codex-a.json"
        let readings =
            H.every5Minutes(.codex, key, .passive, from: "10:30", to: "11:55", resetsAt: "12:40") {
                57.5 + 2.5 * Double($0)
            }
            + H.every5Minutes(.codex, key, .passive, from: "12:40", to: "12:50", resetsAt: "17:00") { _ in 20 }
        let history = try H(readings, gaps: [DateInterval(start: t11d("11:56"), end: t11d("12:40"))])
        let report = try Backtest.run(.codex, accounts: [H.account(.codex, "a", key)], routing: Self.fillFirst,
                                      store: history.store, history: .local, at: every5Minutes("10:30", "11:50"))
        #expect(report.observed == [.init(start: t11d("11:55"), end: t11d("12:40"))])
        for p in report.predictions.dropFirst(2) {
            #expect(p.outcome == .reproduced, "at \(p.at): \(p.forecast)")
        }
    }

    /// M, Neon's case. Codex, one account, 40% at 09:00, +5 per 5 minutes, 100% at 10:00
    /// until its 11:00 reset; asleep 10:05-10:30; next read at 11:05, at 5%. The reset
    /// comes after the gap, so the recovery at 11:00 is known. The forecasts from 09:10
    /// on (50 - 5k left at 1 per minute) run out at 10:00 until 11:00 and reproduce it.
    @Test func aResetAfterTheGapIsAKnownRecovery() throws {
        let key = "codex-a.json"
        let readings =
            H.every5Minutes(.codex, key, .passive, from: "09:00", to: "10:00", resetsAt: "11:00") {
                40 + 5 * Double($0)
            }
            + H.every5Minutes(.codex, key, .passive, from: "11:05", to: "11:30", resetsAt: "16:00") {
                5 + Double($0)
            }
        let history = try H(readings, gaps: [DateInterval(start: t11d("10:05"), end: t11d("10:30"))])
        let report = try Backtest.run(.codex, accounts: [H.account(.codex, "a", key)], routing: Self.fillFirst,
                                      store: history.store, history: .local, at: every5Minutes("09:00", "09:55"))
        #expect(report.observed == [.init(start: t11d("10:00"), end: t11d("11:00"))])
        for p in report.predictions.dropFirst(2) {
            #expect(p.outcome == .reproduced, "at \(p.at): \(p.forecast)")
        }
        #expect(report.failures().isEmpty, "\(report.failures())")
    }

    /// P. Codex, one account, passive readings twice a day (08:00 at 10%, 20:00 at
    /// 20%): no hour holds the three readings a burn rate needs, so every forecast is
    /// short of data. The 2 readings are in range and the replay times 09:00-15:00 have
    /// the pool above 0 around them, but with no rate anywhere the backtest isn't held
    /// to checking something.
    @Test func aHistoryTooSparseForABurnRateIsntAFailure() throws {
        let key = "codex-a.json"
        let readings = H.every5Minutes(.codex, key, .passive, from: "08:00", to: "08:00", resetsAt: "13:00") { _ in 10 }
            + H.every5Minutes(.codex, key, .passive, from: "20:00", to: "20:00", resetsAt: "23:00") { _ in 20 }
        let history = try H(readings)
        let report = try Backtest.run(.codex, accounts: [H.account(.codex, "a", key)], routing: Self.fillFirst,
                                      store: history.store, history: .local, at: every5Minutes("08:00", "20:00"))
        #expect(report.readingsInRange == 2)
        #expect(report.safeStretchCandidates.map(\.at) == every5Minutes("09:00", "15:00"))
        #expect(report.predictions.allSatisfy { $0.forecast == .insufficientData && !$0.rated })
        #expect(report.failures().isEmpty, "\(report.failures())")
    }

    /// R, Sol's case. Codex, fill-first, two accounts. `a` 57.5% at 10:30, +2.5 per 5
    /// minutes, 100% at 11:55 until its 12:00 reset; `b` at 100% until its 12:30 reset.
    /// Asleep 11:56-12:40. `b` is read at 12:40 at 10%, `a` at 12:45 at 100% (reset
    /// 17:00). The 12:00 reset is `a`'s, and `a`'s own first reading after the gap shows
    /// it blocked: it may have run out again, keeping the pool locked to `b`'s 12:30
    /// reset, which `b`'s 12:40 reading confirms. So the recovery (12:00 or 12:30) is
    /// unknown, known to forecasts made from 12:40 on, and a forecast of 11:55-12:30
    /// isn't off. The forecasts from 10:40 on run out at 11:55 and can't be checked.
    @Test func aResetIsConfirmedOnlyByItsOwnAccountsReading() throws {
        let keyA = "codex-a.json", keyB = "codex-b.json"
        let a = H.account(.codex, "a", keyA), b = H.account(.codex, "b", keyB, index: 1)
        let readings =
            H.every5Minutes(.codex, keyA, .passive, from: "10:30", to: "11:55", resetsAt: "12:00") { 57.5 + 2.5 * Double($0) }
            + H.every5Minutes(.codex, keyA, .passive, from: "12:45", to: "12:45", resetsAt: "17:00") { _ in 100 }
            + H.every5Minutes(.codex, keyB, .passive, from: "10:30", to: "11:55", resetsAt: "12:30") { _ in 100 }
            + H.every5Minutes(.codex, keyB, .passive, from: "12:40", to: "12:40", resetsAt: "17:30") { _ in 10 }
        let history = try H(readings, gaps: [DateInterval(start: t11d("11:56"), end: t11d("12:40"))])
        let report = try Backtest.run(.codex, accounts: [a, b], routing: Self.fillFirst, store: history.store,
                                      history: .local, at: every5Minutes("10:30", "11:50"))
        #expect(report.observed == [.init(start: t11d("11:55"), end: t11d("12:30"), recoveryKnown: false,
                                          recoveryKnownFrom: t11d("12:40"))])
        let o = Backtest.Observations(span: report.span, lockouts: report.observed, gaps: report.gaps,
                                      usable: [], resets: [])
        #expect(Backtest.compare(.lockout(from: t11d("11:55"), to: t11d("12:30")), at: t11d("11:30"), o).outcome
                == .notEvaluable)
        for p in report.predictions.dropFirst(2) {
            #expect(p.outcome == .notEvaluable, "at \(p.at): \(p.forecast)")
        }
    }

    /// R, Fable's case. The same `a`; `b` at 100% until its 15:00 reset, read at 12:40
    /// still at 100%; `a` read at 12:45 at 5% (reset 17:00). The first reading after the
    /// gap is `b`'s, blocked, but the 12:00 reset is `a`'s and `a`'s own reading shows
    /// it usable: the lockout is 11:55-12:00, and the forecasts from 10:40 on (`a` runs
    /// out at 11:55 to its 12:00 reset, `b` blocked to 15:00) reproduce it.
    @Test func aResetConfirmedByItsOwnAccountAfterAnotherIsKnown() throws {
        let keyA = "codex-a.json", keyB = "codex-b.json"
        let a = H.account(.codex, "a", keyA), b = H.account(.codex, "b", keyB, index: 1)
        let readings =
            H.every5Minutes(.codex, keyA, .passive, from: "10:30", to: "11:55", resetsAt: "12:00") { 57.5 + 2.5 * Double($0) }
            + H.every5Minutes(.codex, keyA, .passive, from: "12:45", to: "12:45", resetsAt: "17:00") { _ in 5 }
            + H.every5Minutes(.codex, keyB, .passive, from: "10:30", to: "11:55", resetsAt: "15:00") { _ in 100 }
            + H.every5Minutes(.codex, keyB, .passive, from: "12:40", to: "12:40", resetsAt: "15:00") { _ in 100 }
        let history = try H(readings, gaps: [DateInterval(start: t11d("11:56"), end: t11d("12:40"))])
        let report = try Backtest.run(.codex, accounts: [a, b], routing: Self.fillFirst, store: history.store,
                                      history: .local, at: every5Minutes("10:30", "11:50"))
        #expect(report.observed == [.init(start: t11d("11:55"), end: t11d("12:00"))])
        #expect(report.predictions.count == 17)
        for p in report.predictions.dropFirst(2) {
            #expect(p.outcome == .reproduced, "at \(p.at): \(p.forecast)")
        }
    }

    /// T, Sol's case. Codex, one account: local readings every 5 minutes 08:00-09:00,
    /// fork readings from 09:05 to 10:00. Replayed 08:00-09:00 on the fork history, whose
    /// first reading is past the last replay time: nothing could be checked, and the 13
    /// local readings in range show the history was the wrong choice.
    @Test func aChosenHistoryStartingAfterTheReplayFails() throws {
        let key = "codex-a.json"
        let readings =
            H.every5Minutes(.codex, key, .passive, from: "08:00", to: "09:00", resetsAt: "13:00") { 10 + Double($0) }
            + H.every5Minutes(.codex, key, .forkPoller, from: "09:05", to: "10:00", resetsAt: "13:00") { 23 + Double($0) }
        let history = try H(readings)
        let report = try Backtest.run(.codex, accounts: [H.account(.codex, "a", key)], routing: Self.fillFirst,
                                      store: history.store, history: .fork, at: every5Minutes("08:00", "09:00"))
        #expect(report.span == DateInterval(start: t11d("09:05"), end: t11d("10:00")))
        #expect(report.readingsInRange == 13)
        #expect(report.failures() == ["13 readings in range but none from the fork history"])
    }
}
