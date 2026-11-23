import Foundation
import Testing
import UsageCore

// T11a. Expected values come from E12, the T11a acceptance list and hand calculation
// of plan.md's formula, never from running the implementation. A steady burn gives
// the same rate under any weighting, so most cases are exact.

private let file = "claude-aaaa0001-a@example.com.json"
private let reset = t11("17:00")

private func r(_ used: Double, _ hhmm: String, resets: Date? = reset, file f: String = file,
               source: ReadingSource = .passive) -> SourceReading {
    t11Reading(f, used: used, resets: resets, at: t11(hhmm), source: source)
}

private func rate(_ readings: [SourceReading], _ history: ForecastHistory = .local,
                  gaps: [DateInterval] = [], now hhmm: String,
                  halfLife: TimeInterval? = BurnRate.halfLife) -> Double? {
    BurnRate.perHour(readings, history: history, gaps: gaps, now: t11(hhmm), halfLife: halfLife)
}

private func approx(_ value: Double?, _ expected: Double, _ tolerance: Double = 1e-9) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

/// The 20-minute sleep of the acceptance list.
private let sleep = DateInterval(start: t11("12:10"), end: t11("12:30"))

@Suite("T11a burn rate: same-window rule (E12)")
struct T11SameWindowTests {
    @Test func e12SteadyBurnIs12PerHour() {
        // 10 -> 13 -> 16 over 12:00..12:30: 6% in 30 min = 12%/h.
        let readings = [r(10, "12:00"), r(13, "12:15"), r(16, "12:30")]
        #expect(approx(rate(readings, now: "12:30"), 12))
        // Local rows aren't fork history.
        #expect(rate(readings, .fork, now: "12:30") == nil)
    }

    @Test func e12NewResetIntervalIsSkipped() {
        // 16 -> 2 at 12:45 with a new reset: skipped, time not counted. Still 6% in 30 min.
        let readings = [r(10, "12:00"), r(13, "12:15"), r(16, "12:30"),
                        r(2, "12:45", resets: t11("17:45"))]
        #expect(approx(rate(readings, now: "12:45"), 12))
    }

    @Test func resetInTheMiddleDropsThatIntervalAndItsTime() {
        // Counted: 12:00-12:15 (+3), 12:30-12:45 (+3), 12:45-13:00 (+3) = 9% in 45 min
        // = 12%/h. Counting the reset interval's 15 min would give 9% in 60 min = 9%/h.
        let r2 = t11("17:30")
        let readings = [r(10, "12:00"), r(13, "12:15"), r(2, "12:30", resets: r2),
                        r(5, "12:45", resets: r2), r(8, "13:00", resets: r2)]
        #expect(approx(rate(readings, now: "13:00"), 12))
        #expect(approx(rate(readings, now: "13:00", halfLife: nil), 12))
    }

    @Test func aResetMovedPastTheToleranceIsANewWindowEvenWithoutADrop() {
        // 13 -> 30 with the reset 2 h later: skipped. Counted 3% + 3% in 30 min = 12%/h
        // (counting it: 23% in 45 min = 30.7%/h).
        let later = reset.addingTimeInterval(7200)
        let readings = [r(10, "12:00"), r(13, "12:15"), r(30, "12:30", resets: later),
                        r(33, "12:45", resets: later)]
        #expect(approx(rate(readings, now: "12:45"), 12))
    }

    @Test func resetsJitteringWithin60sAgree() {
        // Resets 45 s and 10 s off: same window. 6% in 30 min = 12%/h.
        let readings = [r(10, "12:00"), r(13, "12:15", resets: reset.addingTimeInterval(45)),
                        r(16, "12:30", resets: reset.addingTimeInterval(-10))]
        #expect(approx(rate(readings, now: "12:30"), 12))
    }

    @Test func earlierReadingAtZeroWithUnsetResetStartsTheWindow() {
        // 0 (unset) -> 6 -> 9: all counted, 9% in 30 min = 18%/h.
        let counted = [r(0, "12:00", resets: nil), r(6, "12:15"), r(9, "12:30")]
        #expect(approx(rate(counted, now: "12:30", halfLife: nil), 18))
        // 1 (unset) -> 6: not the same window. Only 6 -> 9: 3% in 15 min = 12%/h.
        let skipped = [r(1, "12:00", resets: nil), r(6, "12:15"), r(9, "12:30")]
        #expect(approx(rate(skipped, now: "12:30"), 12))
    }

    @Test func needsThreeDistinctTimes() {
        #expect(rate([r(10, "12:00"), r(13, "12:15")], now: "12:15") == nil)
        #expect(rate([r(10, "12:00", source: .forkPoller), r(13, "12:15", source: .forkPoller)],
                     .fork, now: "12:15") == nil)
    }

    @Test func readingsOlderThanTheLookbackAreIgnored() {
        // 11:20 is outside the 60 min before 12:30; 11:30 is inside.
        let readings = [r(0, "11:20"), r(10, "11:30"), r(16, "12:00"), r(22, "12:30")]
        #expect(approx(rate(readings, now: "12:30"), 12))
    }

    @Test func steadyBurnWithEveryIntervalSkippedHasNoRate() {
        let readings = [r(10, "12:00"), r(5, "12:15", resets: t11("17:15")),
                        r(1, "12:30", resets: t11("17:30"))]
        #expect(rate(readings, now: "12:30") == nil)
    }
}

@Suite("T11a burn rate: gaps and history choice")
struct T11GapTests {
    /// 10, 11, 12% at 12:00, 12:05, 12:10; the Mac sleeps 12:10-12:30; 30, 31, 32% at
    /// 12:30, 12:35, 12:40.
    let local = [r(10, "12:00"), r(11, "12:05"), r(12, "12:10"),
                 r(30, "12:30"), r(31, "12:35"), r(32, "12:40")]

    @Test func threeReadingsBeforeAGapAndOneAfterGiveNoRate() {
        let readings = Array(local.prefix(4))
        #expect(rate(readings, gaps: [sleep], now: "12:30") == nil)
    }

    @Test func gapIntervalIsSkippedLocally() {
        // Counted: four intervals of +1% in 5 min = 4% in 20 min = 12%/h. Counting the
        // gap: 22% in 40 min = 33%/h.
        #expect(approx(rate(local, gaps: [sleep], now: "12:40"), 12))
        #expect(approx(rate(local, gaps: [sleep], now: "12:40", halfLife: nil), 12))
        // Without the stored gap the plain formula counts it: 33%/h.
        #expect(approx(rate(local, now: "12:40", halfLife: nil), 33))
    }

    @Test func gapThatEndedBeforeTheLookbackDoesNotMatter() {
        let old = DateInterval(start: t11("10:00"), end: t11("11:00"))
        #expect(approx(rate(local, gaps: [old, sleep], now: "12:40"), 12))
        #expect(approx(rate(Array(local.prefix(3)), gaps: [old], now: "12:10"), 12))
    }

    @Test func forkHistoryKeepsSamplesInsideTheSleep() {
        // The fork kept polling: four samples inside the 12:10-12:30 sleep climb 0.9%/min
        // (12 -> 30 in 20 min), the rest 0.2%/min. Every interval counts.
        let inside = [(15.6, "12:14"), (19.2, "12:18"), (22.8, "12:22"), (26.4, "12:26")]
        let fork = (local + inside.map { r($0.0, $0.1) })
            .map { t11Reading($0.fileKey, used: $0.usedPercent, resets: $0.resetsAt,
                              at: $0.observedAt, source: .forkPoller) }

        // Plain formula: 22% in 40 min = 33%/h.
        #expect(approx(rate(fork, .fork, gaps: [sleep], now: "12:40", halfLife: nil), 33))

        // Weighted, w = 0.5^(age of the interval's midpoint / 20 min), now 12:40:
        //   +1 in 5 min at ages 37.5, 32.5, 7.5, 2.5 -> w 0.2726, 0.3242, 0.7711, 0.9170
        //     (sum 2.2849)
        //   +3.6 in 4 min at ages 28, 24, 20, 16, 12 -> w 0.3789, 0.4353, 0.5000, 0.5743,
        //     0.6598 (sum 2.5483)
        //   sum(w * rise) = 2.2849 + 3.6 * 2.5483 = 11.4588
        //   sum(w * time) = 5 * 2.2849 + 4 * 2.5483 = 21.6177 min
        //   rate = 11.4588 / 21.6177 * 60 = 31.80%/h
        #expect(approx(rate(fork, .fork, gaps: [sleep], now: "12:40"), 31.80, 0.01))
    }

    @Test func eachHistoryReadsOnlyItsOwnRows() {
        // Local rows climb 12%/h; fork rows for the same file climb 24%/h.
        let forkRows = [r(10, "12:00", source: .forkPoller), r(12, "12:05", source: .forkPoller),
                        r(14, "12:10", source: .forkPoller)]
        let localRows = [r(10, "12:00"), r(11, "12:05"), r(12, "12:10")]
        #expect(approx(rate(forkRows + localRows, .local, now: "12:10"), 12))
        #expect(approx(rate(forkRows + localRows, .fork, now: "12:10"), 24))
    }
}

@Suite("T11a burn rate: accounts with several credential files")
struct T11MergedSeriesTests {
    let db = T5TempDatabase()
    let fileA = "claude-aaaa0001-a@example.com.json"
    let fileB = "claude-aaaa0001-b@example.com.json"

    var account: MergedAccount {
        MergedAccount(id: AccountID(provider: .claude, identity: "aaaa0001"), alias: "claude-1",
                      email: nil, enabled: true, unavailable: [],
                      credentials: [t11Route(fileA), t11Route(fileB)], colorIndex: 0)
    }

    func store(_ readings: [SourceReading], gaps: [DateInterval] = [sleep]) throws -> SQLiteHistoryStore {
        let s = try SQLiteHistoryStore(path: db.path, retention: nil)
        try s.append(readings)
        for g in gaps { try s.recordGap(from: g.start, to: g.end) }
        return s
    }

    /// Readings before the sleep, so only the post-gap rule decides.
    var beforeSleep: [SourceReading] {
        [r(10, "12:00", file: fileA), r(11, "12:05", file: fileA), r(12, "12:10", file: fileA)]
    }

    @Test func twoFilesAtTwoTimesAfterAGapGiveNoRate() throws {
        // Four rows, two distinct times after the gap.
        let s = try store(beforeSleep + [r(30, "12:30", file: fileA), r(30, "12:30", file: fileB),
                                         r(31, "12:35", file: fileA), r(31, "12:35", file: fileB)])
        #expect(try BurnRate.perHour(account: account, .fiveHour, store: s, history: .local,
                                     now: t11("12:35")) == nil)
    }

    @Test func highestUsedWinsAtEachTime() throws {
        // a: 30, 30, 30; b: 30, 31, 32 at 12:30, 12:35, 12:40. Highest wins: 30, 31, 32 ->
        // 2% in 10 min = 12%/h. Lowest-wins or a-first would give 0%/h.
        // Six rows, three times, all after the gap.
        let s = try store([
            r(30, "12:30", file: fileA), r(30, "12:35", file: fileA), r(30, "12:40", file: fileA),
            r(30, "12:30", file: fileB), r(31, "12:35", file: fileB), r(32, "12:40", file: fileB),
        ])
        let value = try BurnRate.perHour(account: account, .fiveHour, store: s, history: .local,
                                         now: t11("12:40"))
        #expect(approx(value, 12))
    }

    @Test func otherAccountsFilesAndOtherProvidersAreIgnored() throws {
        // A Codex row and another Claude account's row with steep rises don't leak in.
        let s = try store([
            r(10, "12:00", file: fileA), r(11, "12:05", file: fileA), r(12, "12:10", file: fileA),
            r(90, "12:05", file: "claude-bbbb0002-x@example.com.json"),
            t11Reading(fileA, used: 99, resets: reset, at: t11("12:07"), provider: .codex),
        ], gaps: [])
        let value = try BurnRate.perHour(account: account, .fiveHour, store: s, history: .local,
                                         now: t11("12:10"))
        #expect(approx(value, 12))
    }

    @Test func mergeTieBreaksOnTheLowestFileKey() {
        // Same time, same used%: the lower fileKey's reset is kept.
        let a = t11Reading(fileA, used: 30, resets: t11("17:00"), at: t11("12:30"))
        let b = t11Reading(fileB, used: 30, resets: t11("17:01"), at: t11("12:30"))
        #expect(BurnRate.merged([b, a]) == [a])
    }
}
