import AppKit
import Foundation
import SwiftUI
import Testing
import UsageCore
@testable import UsageMonitorApp

// T11d: the forecast as text in the dropdown (plan.md "Forecast" outputs). Now is
// Sunday 2026-11-22 13:20 UTC (T9bExamples.clock).

private typealias E = T9bExamples
private let toronto = TimeZone(identifier: "America/Toronto")!   // UTC-5 in November
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!          // UTC+9

/// 2026-11-01 at `hh:mm` UTC.
private func nov1(_ hhmm: String) -> Date { ISO8601DateFormatter().date(from: "2026-11-01T\(hhmm):00Z")! }

private func id(_ s: String) -> AccountID { AccountID(provider: .claude, identity: s) }

private let runOuts = [
    WeeklyRunOut(account: id("a"), alias: "claude-1", runOut: E.at("18:00", day: 25),
                 resets: E.at("09:00", day: 26)),
    WeeklyRunOut(account: id("b"), alias: "claude-2", runOut: nil, resets: E.at("09:00", day: 27)),
    WeeklyRunOut(account: id("c"), alias: "claude-3", runOut: E.at("09:00", day: 24), resets: nil),
]

private func summary(_ burn: Double?, _ lockout: LockoutForecast,
                     weekly: [WeeklyRunOut] = []) -> ForecastSummary {
    ForecastSummary(poolBurnPerHour: burn, lockout: lockout, weekly: weekly)
}

@Suite("T11d forecast text")
struct T11dDropdownTextTests {
    @Test func lockoutLineForEachForecast() {
        let c = E.clock
        #expect(DropdownText.forecastLine(summary(18, .lockout(from: E.at("17:09"), to: E.at("17:20"))), c)
                == "burn 18%/h · lockout at 17:09 to 17:20")
        #expect(DropdownText.forecastLine(summary(4, .safe), c) == "burn 4%/h · safe for 5h")
        #expect(DropdownText.forecastLine(summary(nil, .withheld(reason: "session affinity is on")), c)
                == "no lockout forecast: session affinity is on")
        #expect(DropdownText.forecastLine(summary(12, .withheld(reason: "session affinity is on")), c)
                == "burn 12%/h · no lockout forecast: session affinity is on")
        #expect(DropdownText.forecastLine(summary(nil, .insufficientData), c)
                == "no lockout forecast yet: not enough readings")
        // A lockout past midnight names the day.
        #expect(DropdownText.forecastLine(summary(30, .lockout(from: E.at("23:50"), to: E.at("00:40", day: 23))), c)
                == "burn 30%/h · lockout at 23:50 to Mon 00:40")
    }

    @Test func burnRateRounding() {
        #expect(DropdownText.burn(17.6) == "burn 18%/h")
        #expect(DropdownText.burn(0.3) == "burn <1%/h")
        #expect(DropdownText.burn(0) == "burn 0%/h")
    }

    @Test func weeklyRunOutPerAccountThatRunsOut() {
        // claude-2 lasts until its reset (or has no rate): no line.
        #expect(DropdownText.weeklyRunOuts(summary(nil, .safe, weekly: runOuts), E.clock)
                == ["claude-1 runs out Wed 18:00, resets Thu 09:00", "claude-3 runs out Tue 09:00"])
        #expect(DropdownText.weeklyRunOuts(summary(nil, .safe), E.clock).isEmpty)
    }

    @Test func timesAreInTheUsersTimeZone() {
        let f = summary(18, .lockout(from: E.at("17:09"), to: E.at("17:20")), weekly: runOuts)
        // Toronto: 12:09 the same Sunday; the weekly times move 5 hours back.
        let east = DropdownClock(now: E.now, timeZone: toronto)
        #expect(DropdownText.forecastLine(f, east) == "burn 18%/h · lockout at 12:09 to 12:20")
        #expect(DropdownText.weeklyRunOuts(f, east)
                == ["claude-1 runs out Wed 13:00, resets Thu 04:00", "claude-3 runs out Tue 04:00"])
        // Tokyo: now is Sunday 22:20 there, the lockout Monday 02:09.
        let japan = DropdownClock(now: E.now, timeZone: tokyo)
        #expect(DropdownText.forecastLine(f, japan) == "burn 18%/h · lockout at Mon 02:09 to Mon 02:20")
        #expect(DropdownText.weeklyRunOuts(f, japan).first == "claude-1 runs out Thu 03:00, resets Thu 18:00")
    }

    /// Toronto leaves daylight time on Sunday 2026-11-01: 02:00 EDT becomes 01:00 EST.
    /// A lockout 05:50-06:20 UTC is 01:50 EDT to 01:20 EST; without the zones it would
    /// read as ending before it starts.
    @Test func aClockChangeInsideTheLockoutNamesBothZones() {
        let night = DropdownClock(now: nov1("05:00"), timeZone: toronto)   // 01:00 EDT
        let f = summary(18, .lockout(from: nov1("05:50"), to: nov1("06:20")))
        #expect(DropdownText.forecastLine(f, night) == "burn 18%/h · lockout at 01:50 EDT to 01:20 EST")
        #expect(RowHover.forecast(f, night)?.notes.last == "lockout at 01:50 EDT to 01:20 EST")
        // Both ends in EST, an hour later: no zones.
        let later = summary(18, .lockout(from: nov1("06:50"), to: nov1("07:20")))
        #expect(DropdownText.forecastLine(later, night) == "burn 18%/h · lockout at 01:50 to 02:20")
    }

    /// The hover prints the rate as the row does: below 0.5 it is "<1%", not "0%".
    @Test func hoverBurnRateMatchesTheRow() {
        let notes = RowHover.forecast(summary(0.3, .safe), E.clock)?.notes
        #expect(notes == ["burn <1% of pool per hour", "safe for 5h"])
        #expect(DropdownText.forecastLine(summary(0.3, .safe), E.clock) == "burn <1%/h · safe for 5h")
    }

    @Test func hoverUsesTheSameText() {
        let notes = RowHover.forecast(summary(12, .withheld(reason: "session affinity is on"),
                                              weekly: runOuts), E.clock)?.notes
        #expect(notes == ["burn 12% of pool per hour", "no lockout forecast: session affinity is on",
                          "claude-1: weekly runs out Wed 18:00, resets Thu 09:00",
                          "claude-3: weekly runs out Tue 09:00"])
    }
}

/// Renders the dropdown with forecasts to build/review/T11d/ for review, and checks
/// the forecast lines take room under the rows (no new chart).
@Suite("T11d dropdown snapshots")
@MainActor
struct T11dDropdownSnapshotTests {
    static let outputDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/review/T11d")

    static func with(_ row: ProviderRow, _ f: ForecastSummary?) -> ProviderRow {
        ProviderRow(provider: row.provider, fiveHour: row.fiveHour, weekly: row.weekly,
                    monthly: row.monthly, unclassified: row.unclassified, forecast: f)
    }

    /// E.all's rows: Claude locks out with one weekly run-out, Codex is withheld, Go is
    /// safe and waiting for readings for its weekly rate.
    static func model(forecasts: Bool) -> DashboardModel {
        let fs: [ForecastSummary?] = forecasts ? [
            summary(18, .lockout(from: E.at("17:09"), to: E.at("17:20")), weekly: runOuts),
            summary(nil, .withheld(reason: "session affinity is on")),
            summary(4, .safe),
        ] : [nil, nil, nil]
        return DashboardModel(generatedAt: E.now, rows: zip(E.all.rows, fs).map { with($0, $1) },
                              sources: E.all.sources)
    }

    @Test func rendersTheForecastLines() throws {
        let plain = try #require(DropdownSnapshot.png(Self.model(forecasts: false), clock: E.clock, scheme: .light))
        let plainRep = try #require(NSBitmapImageRep(data: plain))
        try FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
        for (scheme, suffix) in [(ColorScheme.light, ""), (.dark, "-dark")] {
            let png = try #require(DropdownSnapshot.png(Self.model(forecasts: true), clock: E.clock, scheme: scheme))
            try png.write(to: Self.outputDir.appendingPathComponent("forecast\(suffix).png"))
            let rep = try #require(NSBitmapImageRep(data: png))
            #expect(rep.pixelsWide == Int(DropdownLayout.width * 2))
            // Five more lines of 11 pt text at 2x: Claude's forecast line and two
            // run-outs, one forecast line each for Codex and Go.
            #expect(rep.pixelsHigh >= plainRep.pixelsHigh + 5 * 2 * 11)
        }
    }
}
