import Foundation
import Testing
import UsageCore

// T11c and the per-provider summary. Expected values are worked out by hand.

private let now = t11("12:00")          // Sunday 2026-11-22 12:00 UTC
private let day: TimeInterval = 24 * 3600
private let utc = TimeZone(identifier: "UTC")!

@Suite("T11c weekly run-out")
struct T11WeeklyRunOutTests {
    @Test func fiftyUsedAtTenPerDayRunsOutInFiveDays() throws {
        // 50 left at 10%/day = 5 days, before the reset in 6 days.
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "claude-1")
        l.set(a, .weekly, used: 50, resets: now.addingTimeInterval(6 * day), at: now)
        let r = WeeklyRunOutForecast.runOut(account: l.accounts[0], ledger: l,
                                            ratePerHour: 10.0 / 24, now: now)
        let runOut = try #require(r.runOut)
        #expect(abs(runOut.timeIntervalSince(now.addingTimeInterval(5 * day))) < 1)
        #expect(r.resets == now.addingTimeInterval(6 * day))
        #expect(r.account == a && r.alias == "claude-1")
        // Sun 12:00 + 5 days = Fri 12:00; the reset is Sat 12:00.
        #expect(ForecastText.weekly(r, timeZone: utc) == "runs out Fri 12:00, resets Sat 12:00")
    }

    @Test func resetBeforeRunOutGivesNone() {
        // 50 left at 10%/day needs 5 days; the reset comes in 4.
        #expect(WeeklyRunOutForecast.runOut(remaining: 50, resets: now.addingTimeInterval(4 * day),
                                            ratePerHour: 10.0 / 24, now: now) == nil)
    }

    @Test func noRateOrNoUsageGivesNone() {
        let resets = now.addingTimeInterval(6 * day)
        #expect(WeeklyRunOutForecast.runOut(remaining: 50, resets: resets, ratePerHour: nil, now: now) == nil)
        #expect(WeeklyRunOutForecast.runOut(remaining: 50, resets: resets, ratePerHour: 0, now: now) == nil)
        #expect(WeeklyRunOutForecast.runOut(remaining: nil, resets: resets, ratePerHour: 1, now: now) == nil)
    }

    @Test func alreadyEmptyHasRunOutNow() {
        #expect(WeeklyRunOutForecast.runOut(remaining: 0, resets: now.addingTimeInterval(day),
                                            ratePerHour: 1, now: now) == now)
    }

    @Test func emptyWindowWithoutARateHasNoRunOut() {
        // Item D: the contract's runOut is nil without a burn rate, even at 0 left.
        let resets = now.addingTimeInterval(day)
        #expect(WeeklyRunOutForecast.runOut(remaining: 0, resets: resets, ratePerHour: nil, now: now) == nil)
        #expect(WeeklyRunOutForecast.runOut(remaining: 0, resets: resets, ratePerHour: 0, now: now) == nil)
    }

    @Test func noKnownResetCapsTheRunOutAtAWeek() {
        // Item E: 100 left at 0.2%/h needs 500 h (20.8 days), more than a week (168 h):
        // it can't run out inside the current weekly window.
        #expect(WeeklyRunOutForecast.runOut(remaining: 100, resets: nil, ratePerHour: 0.2, now: now) == nil)
    }

    @Test func noKnownResetRunOutAtExactlyAWeekIsCapped() {
        // Item H: 168 left at 1%/h needs 168 h = 7 * 24 h, exactly a week: a weekly
        // window is at most that long, so it resets no later than then -> no run-out.
        #expect(WeeklyRunOutForecast.runOut(remaining: 168, resets: nil, ratePerHour: 1, now: now) == nil)
    }

    @Test func noKnownResetKeepsTheExtrapolation() {
        // 20 left at 1%/h: 20 h.
        #expect(WeeklyRunOutForecast.runOut(remaining: 20, resets: nil, ratePerHour: 1, now: now)
                == now.addingTimeInterval(20 * 3600))
    }

    @Test func windowPastItsResetWithoutProofIsUnknown() {
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "claude-1")
        l.set(a, .weekly, used: 50, resets: t11("11:00"), at: t11("10:00"))
        let r = WeeklyRunOutForecast.runOut(account: l.accounts[0], ledger: l, ratePerHour: 1, now: now)
        #expect(r.runOut == nil && r.resets == nil)
        #expect(ForecastText.weekly(r, timeZone: utc) == nil)
    }
}

@Suite("T11 forecast summary per provider")
struct T11SummaryTests {
    let db = T5TempDatabase()

    /// Three Claude accounts, each 40% used (60 left) and climbing 20%/h in the last
    /// 30 min (30, 35, 40 at 11:30, 11:45, 12:00). 5-hour resets 16:00, 16:10, 16:20.
    /// A's weekly is 50% used, climbing 10%/day, resetting in 6 days; B's weekly is 20%
    /// with no history; C has no weekly reading.
    func setUp() throws -> (T3FakeLedgerView, SQLiteHistoryStore) {
        var l = T3FakeLedgerView()
        let store = try SQLiteHistoryStore(path: db.path, retention: nil)
        let resets = ["a": t11("16:00"), "b": t11("16:10"), "c": t11("16:20")]
        var rows: [SourceReading] = []
        for name in ["a", "b", "c"] {
            let id = l.add(.claude, name)
            l.set(id, .fiveHour, used: 40, resets: resets[name], at: now)
            for (used, hhmm) in [(30.0, "11:30"), (35, "11:45"), (40, "12:00")] {
                rows.append(t11Reading(name, used: used, resets: resets[name], at: t11(hhmm)))
            }
            // Fork rows with a much steeper climb, which local history must ignore.
            rows.append(t11Reading(name, used: 0, resets: resets[name], at: t11("11:58"),
                                   source: .forkPoller))
        }
        let weeklyReset = now.addingTimeInterval(6 * day)
        l.set(AccountID(provider: .claude, identity: "a"), .weekly, used: 50, resets: weeklyReset, at: now)
        l.set(AccountID(provider: .claude, identity: "b"), .weekly, used: 20,
              resets: now.addingTimeInterval(2 * day), at: now)
        for (used, hhmm) in [(50 - 10.0 / 24, "11:00"), (50 - 10.0 / 48, "11:30"), (50, "12:00")] {
            rows.append(t11Reading("a", .weekly, used: used, resets: weeklyReset, at: t11(hhmm)))
        }
        try store.append(rows)
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        return (l, store)
    }

    @Test func localHistoryGivesBurnLockoutAndWeekly() throws {
        let (l, store) = try setUp()
        let s = try Forecast.summary(.claude, ledger: l, store: store, history: .local, now: now)

        // Demand 3 x 20 = 60 account-%/h; pool share 60 / 3 = 20%/h.
        #expect(abs((s.poolBurnPerHour ?? 0) - 20) < 1e-9)
        // 1 per minute, 1/3 each: 60 left lasts 180 min, so all three empty at 15:00;
        // A's reset at 16:00 ends it.
        #expect(s.lockout == .lockout(from: t11("15:00"), to: t11("16:00")))
        // A: 50 left at 10%/day = 5 days. B: no weekly rate. C: no weekly reading.
        #expect(s.weekly.map(\.alias) == ["a", "b", "c"])
        let aRunOut = try #require(s.weekly[0].runOut)
        #expect(abs(aRunOut.timeIntervalSince(now.addingTimeInterval(5 * day))) < 1)
        #expect(s.weekly[1].runOut == nil && s.weekly[1].resets == now.addingTimeInterval(2 * day))
        #expect(s.weekly[2].runOut == nil && s.weekly[2].resets == nil)
    }

    @Test func forkHistoryWithoutEnoughSamplesHasNoRate() throws {
        // Fork history holds one sample per account: no rate, so no demand.
        let (l, store) = try setUp()
        let s = try Forecast.summary(.claude, ledger: l, store: store, history: .fork, now: now)
        #expect(s.poolBurnPerHour == nil)
        #expect(s.lockout == .insufficientData)
        #expect(s.weekly.allSatisfy { $0.runOut == nil })
    }

    @Test func steadyFullUseReportsTheCurrentLockout() throws {
        // Item A through the summary: both accounts read 100% used at 11:30, 11:45 and
        // 12:00 (reset 14:00), so the burn is 0%/h, yet nothing is usable now: locked
        // out 12:00 until 14:00.
        var l = T3FakeLedgerView()
        let store = try SQLiteHistoryStore(path: db.path, retention: nil)
        for name in ["a", "b"] {
            let id = l.add(.claude, name)
            l.set(id, .fiveHour, used: 100, resets: t11("14:00"), at: now)
            try store.append(["11:30", "11:45", "12:00"].map {
                t11Reading(name, used: 100, resets: t11("14:00"), at: t11($0))
            })
        }
        l.routing[.cliproxy] = t11Routing(.roundRobin)
        let s = try Forecast.summary(.claude, ledger: l, store: store, history: .local, now: now)
        #expect(s.poolBurnPerHour == 0)
        #expect(s.lockout == .lockout(from: t11("12:00"), to: t11("14:00")))
    }

    @Test func sessionAffinityWithholdsButKeepsBurnAndWeekly() throws {
        var (l, store) = try setUp()
        l.routing[.cliproxy] = t11Routing(.roundRobin, affinity: true)
        let s = try Forecast.summary(.claude, ledger: l, store: store, history: .local, now: now)
        #expect(s.lockout == .withheld(reason: "session affinity is on"))
        #expect(abs((s.poolBurnPerHour ?? 0) - 20) < 1e-9)
        #expect(s.weekly[0].runOut != nil)
    }
}
