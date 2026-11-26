import AppKit
import Foundation
import SwiftUI
import Testing
import UsageCore
@testable import UsageMonitorApp

@Suite("T9b dropdown")
struct T9bDropdownTests {
    typealias E = T9bExamples

    // MARK: overlap line

    @Test func overlapRectsFullestFirstSoTheEmptiestIsOnTop() {
        // Input order deliberately mixed: drawing order comes from the values.
        let bars = [E.bar("b", 1, 50), E.bar("a", 0, 80), E.bar("c", 2, 35)]
        let rects = overlapRects(bars: bars, width: 200)
        #expect(rects.map(\.alias) == ["a", "b", "c"])
        #expect(rects.map(\.minX) == [0, 0, 0])
        #expect(rects.map(\.maxX) == [160, 100, 70])
        #expect(rects.allSatisfy { $0.cornerRadius == 0 })
        #expect(rects.map(\.style) == [.series(0), .series(1), .series(2)])
    }

    @Test func blockedSeatsAreTicksAtZeroInTheirOwnColor() {
        // E2: claude-2 (50 left) is blocked by its weekly window, so it counts 0 in the
        // usable share and sits as a 2 pt tick at 0, drawn after the bars, in color 1.
        let rects = overlapRects(bars: E.e2Five.bars, width: 200)
        #expect(rects.map(\.alias) == ["claude-1", "claude-3", "claude-2"])
        #expect(rects.map(\.kind) == [.bar, .bar, .tick])
        #expect(rects.map(\.style) == [.series(0), .series(2), .series(1)])
        #expect(rects.map(\.minX) == [0, 0, 0])
        #expect(rects.map(\.maxX) == [160, 70, 2])
    }

    @Test func overlapRectsClampAndTickEmptySeats() {
        // Two empty seats: ticks side by side at 0, 2 pt wide, 1 pt apart, input order.
        let rects = overlapRects(bars: [E.bar("full", 0, 120), E.bar("empty", 1, 0), E.bar("neg", 2, -5)],
                                 width: 200)
        #expect(rects.map(\.alias) == ["full", "empty", "neg"])
        #expect(rects.map(\.kind) == [.bar, .tick, .tick])
        #expect(rects.map(\.minX) == [0, 0, 3])
        #expect(rects.map(\.maxX) == [200, 2, 5])
        #expect(overlapRects(bars: [], width: 200).isEmpty)
    }

    @Test func equalValuesKeepTheirOrder() {
        // E4: three bars at 100 all span the line; the last one drawn is on top.
        let rects = overlapRects(bars: E.e4Five.bars, width: 200)
        #expect(rects.map(\.alias) == ["claude-1", "claude-2", "claude-3"])
        #expect(rects.allSatisfy { $0.maxX == 200 })
    }

    @Test func colorIndexesPastThePaletteGetTheirOwnColors() {
        // The store never reuses a color index, so 0 and 6 can be on screen together.
        func rgb(_ c: Color) -> (Double, Double, Double) {
            let n = NSColor(c).usingColorSpace(.sRGB)!
            return (n.redComponent, n.greenComponent, n.blueComponent)
        }
        func distance(_ a: Color, _ b: Color) -> Double {
            let (x, y) = (rgb(a), rgb(b))
            return abs(x.0 - y.0) + abs(x.1 - y.1) + abs(x.2 - y.2)
        }
        // The user's four colors (2026-11-23), in order, in both schemes.
        let four: [(Double, Double, Double)] = [(0xFF, 0x9E, 0x64), (0x7A, 0xA2, 0xF7), (0x9E, 0xCE, 0x6A),
                                                (0xBB, 0x9A, 0xF7)].map { ($0.0 / 255, $0.1 / 255, $0.2 / 255) }
        for p in [DropdownPalette.light, .dark] {
            #expect(p.series.count == 4)
            for (c, want) in zip(p.series, four) {
                let got = rgb(c)
                // Swift 6.2 times out type-checking this sum inside #expect, so it is computed first.
                let error: Double = abs(got.0 - want.0) + abs(got.1 - want.1) + abs(got.2 - want.2)
                #expect(error < 0.01)
            }
            for i in 0..<p.series.count { #expect(p.fill(.series(i)) == p.series[i]) }
            #expect(distance(p.fill(.series(0)), p.fill(.series(6))) > 0.3)
            #expect(distance(p.fill(.series(6)), p.fill(.series(7))) > 0.3)
            // Stable: the same index always gives the same color.
            #expect(rgb(p.fill(.series(9))) == rgb(p.fill(.series(9))))
        }
    }

    @Test func weeklyPlacesThePaceMarker() {
        // E11: pace 75% of the week left -> marker at 75% of the scale. No pace, no marker.
        let g = WindowGauge(window: .weekly, known: 2, total: 2, quota: PercentRange(exact: 59),
                            usable: PercentRange(exact: 59), bars: [], nextRefill: nil, allFull: false,
                            pace: 0.75, accounts: [])
        #expect(paceX(g, width: 200) == 150)
        #expect(paceX(E.e4bFive, width: 200) == nil)
    }

    // MARK: numbers and countdown

    @Test func pooledNumbers() {
        // E1: range; E2: usable beside the line, both numbers below it.
        #expect(DropdownText.headline(E.e1Five) == "41-74%")
        #expect(DropdownText.known(E.e1Five) == "2 of 3 known")
        #expect(DropdownText.headline(E.e2Five) == "38%")
        #expect(DropdownText.usableAndQuota(E.e2Five) == "usable 38%, quota 55%")
        #expect(DropdownText.usableAndQuota(E.e3Five) == nil)
        #expect(DropdownText.known(E.e3Five) == nil)
        // Weekly and monthly show the quota.
        #expect(DropdownText.headline(E.e8Codex.weekly) == "30-80%")
        #expect(DropdownText.headline(nil) == "--")
    }

    @Test func countdownFromNextRefillOrAllFull() {
        // E3: next refill 14:10, at 13:20.
        #expect(DropdownText.countdown(E.e3Five, now: E.now) == "reset in 50m")
        // E4: all full and usable.
        #expect(DropdownText.countdown(E.e4Five, now: E.now) == "reset in 5h")
        // E4b at 13:00: B cools down until 13:40.
        #expect(DropdownText.countdown(E.e4bFive, now: E.at("13:00")) == "reset in 40m")
        // plan.md "Gauge design": "reset in 1h 35m".
        let later = WindowGauge(window: .fiveHour, known: 1, total: 1, quota: PercentRange(exact: 50),
                                usable: PercentRange(exact: 50), bars: [],
                                nextRefill: .init(at: E.at("14:55"), poolGain: 50), allFull: false,
                                pace: nil, accounts: [])
        #expect(DropdownText.countdown(later, now: E.now) == "reset in 1h 35m")
        // E8: no refill known and not full: nothing.
        #expect(DropdownText.countdown(E.e8Codex.fiveHour, now: E.now) == nil)
        #expect(DropdownText.countdown(nil, now: E.now) == nil)
    }

    @Test func weeklyResetCountdownUsesTheSoonestResetAhead() {
        // E1 weekly: every account resets Thu 26 09:00; now is Sun 22 13:20.
        #expect(DropdownText.resetCountdown(E.e1.rows[0].weekly, now: E.now) == "reset in 3d 19h")
        // Past resets don't count; with none ahead there's nothing to show.
        #expect(DropdownText.resetCountdown(E.e1.rows[0].weekly, now: E.at("10:00", day: 26)) == nil)
        #expect(DropdownText.resetCountdown(nil, now: E.now) == nil)
    }

    @Test func nextRefillGainInHover() {
        let hover = RowHover(row: E.e3.rows[0], clock: E.clock)
        #expect(hover.sections[0].notes.contains("next refill 14:10, +27% of pool"))
        let full = RowHover(row: E.e4.rows[0], clock: E.clock)
        #expect(full.sections[0].notes == ["all full: a new window starts with the next request"])
    }

    // MARK: hover

    @MainActor @Test func unclassifiedReadingIsReachableFromTheRowHover() {
        // E8: codex-2 has no bar in any window, only an unclassified reading.
        let row = E.e8Codex
        let allBars = [row.fiveHour, row.weekly, row.monthly].compactMap { $0 }.flatMap(\.bars)
        #expect(!allBars.contains { $0.alias == "codex-2" })

        let view = ProviderRowView(row: row, clock: E.clock)
        let section = view.hover.sections.first { $0.title.hasPrefix("Unclassified") }
        let line = section?.lines.first
        #expect(line?.label == "codex-2")
        #expect(line?.value == "12% used")
        #expect(line?.detail == "no window length · read 3m ago")
        #expect(line?.swatch == nil)
    }

    @Test func hoverShowsUnknownsWithTheirPreviousValueAndAge() {
        // E5b: A used 40 at 11:50, resets 12:00; at 12:05 the counter moved, so A is
        // unknown, the hover shows the previous 60% with its age, and the unproven
        // 12:00 reset reads as past.
        let a = AccountDetail(alias: "claude-1", email: nil, remaining: nil,
                              previous: .init(value: 60, observedAt: E.at("11:50")),
                              resetsAt: E.at("12:00"), observedAt: nil, stale: false, usable: true,
                              blockedReason: nil)
        let at1205 = DropdownClock(now: E.at("12:05"), timeZone: E.utc)
        let line = RowHover.account(a, bar: nil, at1205)
        #expect(line.value == "unknown")
        #expect(line.detail == "was 60% 15m ago · reset 12:00 passed")
        // A future reset keeps the future tense.
        #expect(DropdownText.reset(E.at("12:30"), at1205) == "resets 12:30")
        #expect(DropdownText.reset(E.at("12:05"), at1205) == "reset 12:05 passed")
        let never = RowHover.account(E.detail("claude-3", nil), bar: nil, E.clock)
        #expect(never.detail == "claude-3@example.com · never read")
    }

    @Test func weeklyRunOutListsOnlyAccountsWithARunOutTime() {
        // runOut nil means "lasts until reset" or "no burn rate": not shown at all.
        let id = { AccountID(provider: .claude, identity: $0) }
        let f = ForecastSummary(poolBurnPerHour: nil, lockout: .safe, weekly: [
            WeeklyRunOut(account: id("a"), alias: "claude-1", runOut: E.at("18:00", day: 25),
                         resets: E.at("09:00", day: 26)),
            WeeklyRunOut(account: id("b"), alias: "claude-2", runOut: nil, resets: E.at("09:00", day: 27)),
        ])
        let notes = RowHover.forecast(f, E.clock)?.notes ?? []
        #expect(notes == ["safe for 5h", "claude-1: weekly runs out Wed 18:00, resets Thu 09:00"])
        #expect(!notes.contains { $0.contains("claude-2") })
        // A forecast with only a nil run-out: that account is left out, the lockout
        // note stays.
        let none = ForecastSummary(poolBurnPerHour: nil, lockout: .insufficientData, weekly: [
            WeeklyRunOut(account: id("b"), alias: "claude-2", runOut: nil, resets: nil),
        ])
        #expect(RowHover.forecast(none, E.clock)?.notes == ["no lockout forecast yet: not enough readings"])
    }

    @Test func hoverPerAccountValuesFreshnessAndBlocks() {
        let hover = RowHover(row: E.e2.rows[0], clock: E.clock)
        let five = hover.sections[0]
        #expect(five.title == "5-hour: 38% usable, quota 55%")
        #expect(five.lines.map(\.label) == ["claude-1", "claude-2", "claude-3"])
        #expect(five.lines.map(\.value) == ["80%", "50%", "35%"])
        #expect(five.lines[1].swatch == .series(1))
        #expect(five.lines[1].detail.contains("weekly limit until Thu 09:00"))
        #expect(five.lines[2].detail.contains("resets 14:10"))
        #expect(five.lines[2].detail.contains("read 2m ago"))
        #expect(hover.sections[1].title == "Weekly: 23% left, pace 50%")
    }

    @Test func staleUnknownAccountDoesNotMarkTheNumber() {
        // One known account read 2m ago, one unknown whose previous reading is old (T3
        // marks it stale). The number isn't stale; the unknown's hover line warns.
        let g = WindowGauge(
            window: .fiveHour, known: 1, total: 2,
            quota: PercentRange(lower: 40, upper: 90), usable: PercentRange(lower: 40, upper: 90),
            bars: [E.bar("codex-1", 0, 80)], nextRefill: nil, allFull: false, pace: nil,
            accounts: [E.detail("codex-1", 80),
                       AccountDetail(alias: "codex-2", email: nil, remaining: nil,
                                     previous: .init(value: 60, observedAt: E.at("11:50")),
                                     resetsAt: nil, observedAt: nil, stale: true, usable: true,
                                     blockedReason: nil)])
        #expect(!DropdownText.isStale(g))
        #expect(DropdownText.oldestReading(g) == E.at("13:18"))
        let lines = RowHover.window(g, name: "5-hour", E.clock).lines
        #expect(lines[0].warning == false)
        #expect(lines[1].label == "codex-2")
        #expect(lines[1].warning == true)
        #expect(lines[1].detail == "was 60% 1h 30m ago · stale")
    }

    @Test func staleAccountsAreMarked() {
        let go = E.all.row(.go)!
        #expect(DropdownText.isStale(go.fiveHour))
        #expect(DropdownText.oldestReading(go.fiveHour) == E.at("12:40"))
        let line = RowHover(row: go, clock: E.clock).sections[0].lines[0]
        #expect(line.warning)
        #expect(line.detail.hasSuffix("read 40m ago · stale"))
    }

    // MARK: sources

    @Test func sourceStates() {
        let c = E.clock
        #expect(DropdownText.sourceStatus(.ocgo, .ok(at: E.at("13:17")), c).text == "ocgo: updated 3m ago")
        let auth = DropdownText.sourceStatus(.cliproxy, .authStopped(.unauthorized), c)
        #expect(auth.text == "cliproxy: unauthorized, polling stopped. Fix it in Setup.")
        #expect(auth.severity == .error)
        let failing = DropdownText.sourceStatus(.cliproxy, .failing(.unreachable, since: E.at("13:02")), c)
        #expect(failing.text == "cliproxy: unreachable since 13:02, retrying")
        #expect(failing.severity == .warning)
        #expect(DropdownText.sourceStatus(.ocgo, .notConfigured, c).text == "ocgo: not configured")
        #expect(DropdownText.source(for: .go) == .ocgo)
        #expect(DropdownText.source(for: .codex) == .cliproxy)
    }

    @Test func durationsAndClock() {
        #expect(DropdownText.duration(minutes: 40) == "40m")
        #expect(DropdownText.duration(minutes: 65) == "1h 05m")
        #expect(DropdownText.duration(minutes: 300) == "5h")
        #expect(DropdownText.duration(minutes: 10080) == "7d")
        #expect(DropdownText.windowLength(5400) == "1h 30m window")
        #expect(DropdownText.age(E.at("13:19"), now: E.at("13:19").addingTimeInterval(30)) == "just now")
        #expect(DropdownText.clock(E.at("14:10"), E.clock) == "14:10")
        #expect(DropdownText.clock(E.at("09:00", day: 26), E.clock) == "Thu 09:00")
    }
}
