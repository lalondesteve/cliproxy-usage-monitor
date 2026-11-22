import Foundation
import UsageCore
@testable import UsageMonitorApp

/// `DashboardModel`s built by hand from the worked examples in
/// docs/implementation-plan.md (not by a pool engine). The 5-hour values follow the
/// examples exactly; weekly lines, emails and reset times the examples leave open are
/// filled in with plausible values so the PNGs show a whole row.
enum T9bExamples {
    static let utc = TimeZone(identifier: "UTC")!

    /// 2026-11-22 at `hhmm` UTC.
    static func at(_ hhmm: String, day: Int = 22) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: "2026-11-\(String(format: "%02d", day))T\(hhmm):00Z")!
    }

    static let now = at("13:20")
    static let clock = DropdownClock(now: now, timeZone: utc)

    static func detail(_ alias: String, _ remaining: Double?, resets: String? = nil,
                       read: String? = "13:18", previous: AccountDetail.Previous? = nil,
                       stale: Bool = false, usable: Bool = true, blocked: String? = nil,
                       resetsDay: Int = 22) -> AccountDetail {
        AccountDetail(alias: alias, email: "\(alias)@example.com", remaining: remaining,
                      previous: previous, resetsAt: resets.map { at($0, day: resetsDay) },
                      observedAt: remaining == nil ? nil : read.map { at($0) },
                      stale: stale, usable: usable, blockedReason: blocked)
    }

    static func bar(_ alias: String, _ color: Int, _ remaining: Double, greyed: Bool = false) -> GaugeBar {
        GaugeBar(alias: alias, colorIndex: color, remaining: remaining, greyed: greyed)
    }

    static func weekly(_ values: [Double], pace: Double?, resetsDay: Int = 26) -> WindowGauge {
        let aliases = ["claude-1", "claude-2", "claude-3"]
        let q = PercentRange(exact: values.reduce(0, +) / Double(values.count))
        return WindowGauge(
            window: .weekly, known: values.count, total: values.count, quota: q, usable: q,
            bars: zip(aliases, values).enumerated().map { bar($1.0, $0, $1.1) }
                .sorted { $0.remaining > $1.remaining },
            nextRefill: nil, allFull: false, pace: pace,
            accounts: zip(aliases, values).map { detail($0, $1, resets: "09:00", resetsDay: resetsDay) })
    }

    static func claude(_ five: WindowGauge, weekly: WindowGauge) -> DashboardModel {
        DashboardModel(
            generatedAt: now,
            rows: [ProviderRow(provider: .claude, fiveHour: five, weekly: weekly, monthly: nil,
                               unclassified: [], forecast: nil)],
            sources: [.cliproxy: .ok(at: at("13:19")), .ocgo: .notConfigured])
    }

    /// E1: remaining 70 and 53, third unknown: quota 41-74% (123/3, 223/3), "2 of 3
    /// known", two bars.
    static let e1Five = WindowGauge(
        window: .fiveHour, known: 2, total: 3,
        quota: PercentRange(lower: 123.0 / 3, upper: 223.0 / 3),
        usable: PercentRange(lower: 123.0 / 3, upper: 223.0 / 3),
        bars: [bar("claude-1", 0, 70), bar("claude-2", 1, 53)],
        nextRefill: .init(at: at("14:40"), poolGain: 30.0 / 3), allFull: false, pace: nil,
        accounts: [detail("claude-1", 70, resets: "14:40"), detail("claude-2", 53, resets: "15:05"),
                   detail("claude-3", nil)])
    static let e1 = claude(e1Five, weekly: weekly([80, 62, 35], pace: 0.6))

    /// E2: A 80 usable, B 50 blocked by weekly, C 35 usable: quota 55%, usable 38%
    /// (115/3), B greyed, both numbers shown.
    static let e2Five = WindowGauge(
        window: .fiveHour, known: 3, total: 3,
        quota: PercentRange(exact: 165.0 / 3), usable: PercentRange(exact: 115.0 / 3),
        bars: [bar("claude-1", 0, 80), bar("claude-2", 1, 50, greyed: true), bar("claude-3", 2, 35)],
        nextRefill: .init(at: at("14:10"), poolGain: 65.0 / 3), allFull: false, pace: nil,
        accounts: [detail("claude-1", 80, resets: "15:30"),
                   detail("claude-2", 50, resets: "14:45", usable: false, blocked: "weekly limit until Thu 09:00"),
                   detail("claude-3", 35, resets: "14:10")])
    static let e2 = claude(e2Five, weekly: weekly([40, 0, 30], pace: 0.5))

    /// E3: A 20 (resets 14:10), B 60 (15:30), C 100, all usable: next refill 14:10,
    /// +27% of pool (80/3). At 13:20 that is "reset in 50m".
    static let e3Five = WindowGauge(
        window: .fiveHour, known: 3, total: 3,
        quota: PercentRange(exact: 60), usable: PercentRange(exact: 60),
        bars: [bar("claude-3", 2, 100), bar("claude-2", 1, 60), bar("claude-1", 0, 20)],
        nextRefill: .init(at: at("14:10"), poolGain: 80.0 / 3), allFull: false, pace: nil,
        accounts: [detail("claude-1", 20, resets: "14:10"), detail("claude-2", 60, resets: "15:30"),
                   detail("claude-3", 100)])
    static let e3 = claude(e3Five, weekly: weekly([55, 70, 90], pace: 0.75))

    /// E4: every 5-hour window at 100, all usable: `allFull`, "reset in 5h", no
    /// `nextRefill`.
    static let e4Five = WindowGauge(
        window: .fiveHour, known: 3, total: 3,
        quota: PercentRange(exact: 100), usable: PercentRange(exact: 100),
        bars: [bar("claude-1", 0, 100), bar("claude-2", 1, 100), bar("claude-3", 2, 100)],
        nextRefill: nil, allFull: true, pace: nil,
        accounts: [detail("claude-1", 100), detail("claude-2", 100), detail("claude-3", 100)])
    static let e4 = claude(e4Five, weekly: weekly([62, 48, 75], pace: 0.4))

    /// E4b: all at 100 at 13:00, B cooling down until 13:40: not `allFull`, next
    /// refill 13:40 +33%, "reset in 40m".
    static let e4bFive = WindowGauge(
        window: .fiveHour, known: 3, total: 3,
        quota: PercentRange(exact: 100), usable: PercentRange(exact: 200.0 / 3),
        bars: [bar("claude-1", 0, 100), bar("claude-2", 1, 100, greyed: true), bar("claude-3", 2, 100)],
        nextRefill: .init(at: at("13:40"), poolGain: 100.0 / 3), allFull: false, pace: nil,
        accounts: [detail("claude-1", 100), detail("claude-2", 100, usable: false, blocked: "cooling down until 13:40"),
                   detail("claude-3", 100)])

    /// E8: Codex primary window of 10080 minutes (weekly), no secondary; another
    /// reading with no length goes to `unclassified`, for an account with no bar.
    static let e8Codex = ProviderRow(
        provider: .codex,
        fiveHour: WindowGauge(
            window: .fiveHour, known: 0, total: 2,
            quota: PercentRange(lower: 0, upper: 100), usable: PercentRange(lower: 0, upper: 100),
            bars: [], nextRefill: nil, allFull: false, pace: nil,
            accounts: [detail("codex-1", nil), detail("codex-2", nil)]),
        weekly: WindowGauge(
            window: .weekly, known: 1, total: 2,
            quota: PercentRange(lower: 30, upper: 80), usable: PercentRange(lower: 30, upper: 80),
            bars: [bar("codex-1", 0, 60)], nextRefill: nil, allFull: false, pace: 0.4,
            accounts: [detail("codex-1", 60, resets: "09:00", resetsDay: 25), detail("codex-2", nil)]),
        monthly: nil,
        unclassified: [UnclassifiedDetail(alias: "codex-2", lengthSeconds: nil, usedPercent: 12,
                                          resetsAt: nil, observedAt: at("13:17"))],
        forecast: nil)

    /// Review round 1: the longest aux line ("2 of 3 known · stale, read 2h 05m ago"
    /// beside "reset in 1h 35m") must wrap on the left, not truncate the countdown.
    /// Color indexes 0, 6 and 7 (account turnover) must give three distinct colors;
    /// weekly gets the oldest-reading age too.
    static let longAux: DashboardModel = {
        let five = WindowGauge(
            window: .fiveHour, known: 2, total: 3,
            quota: PercentRange(lower: 110.0 / 3, upper: 210.0 / 3),
            usable: PercentRange(lower: 110.0 / 3, upper: 210.0 / 3),
            bars: [bar("claude-7", 6, 75), bar("claude-8", 7, 35)],
            nextRefill: .init(at: at("14:55"), poolGain: 65.0 / 3), allFull: false, pace: nil,
            accounts: [detail("claude-7", 75, resets: "16:00", read: "11:15", stale: true),
                       detail("claude-8", 35, resets: "14:55"),
                       AccountDetail(alias: "claude-1", email: nil, remaining: nil,
                                     previous: .init(value: 60, observedAt: at("11:50")),
                                     resetsAt: at("12:00"), observedAt: nil, stale: true, usable: true,
                                     blockedReason: nil)])
        let weekly = WindowGauge(
            window: .weekly, known: 2, total: 3,
            quota: PercentRange(lower: 30, upper: 63.3), usable: PercentRange(lower: 30, upper: 63.3),
            bars: [bar("claude-1", 0, 50), bar("claude-7", 6, 40)], nextRefill: nil, allFull: false,
            pace: 0.6,
            accounts: [detail("claude-1", 50, resets: "09:00", read: "13:10", resetsDay: 26),
                       detail("claude-7", 40, resets: "09:00", read: "11:15", stale: true, resetsDay: 25),
                       detail("claude-8", nil)])
        return DashboardModel(
            generatedAt: now,
            rows: [ProviderRow(provider: .claude, fiveHour: five, weekly: weekly, monthly: nil,
                               unclassified: [], forecast: nil)],
            sources: [.cliproxy: .ok(at: at("13:19")), .ocgo: .notConfigured])
    }()

    /// Everything at once for review: E2's Claude row, E8's Codex row with cliproxy
    /// failing, and a Go row with a monthly line, a stale account and a forecast.
    static let all = DashboardModel(
        generatedAt: now,
        rows: [
            ProviderRow(provider: .claude, fiveHour: e2Five, weekly: weekly([40, 0, 30], pace: 0.5),
                        monthly: nil, unclassified: [],
                        forecast: ForecastSummary(poolBurnPerHour: 18, lockout: .lockout(from: at("17:09"), to: at("17:20")),
                                                  weekly: [])),
            e8Codex,
            ProviderRow(
                provider: .go,
                fiveHour: WindowGauge(
                    window: .fiveHour, known: 2, total: 2,
                    quota: PercentRange(exact: 89), usable: PercentRange(exact: 89),
                    bars: [bar("go-1", 0, 90), bar("go-2", 1, 88)],
                    nextRefill: .init(at: at("14:00"), poolGain: 5), allFull: false, pace: nil,
                    accounts: [detail("go-1", 90, resets: "14:00", read: "12:40", stale: true),
                               detail("go-2", 88, resets: "16:10")]),
                weekly: WindowGauge(
                    window: .weekly, known: 2, total: 2,
                    quota: PercentRange(exact: 64), usable: PercentRange(exact: 64),
                    bars: [bar("go-1", 0, 70), bar("go-2", 1, 58)], nextRefill: nil, allFull: false,
                    pace: 0.55,
                    accounts: [detail("go-1", 70, resets: "09:00", read: "12:40", stale: true, resetsDay: 25),
                               detail("go-2", 58, resets: "09:00", resetsDay: 26)]),
                monthly: WindowGauge(
                    window: .monthly, known: 2, total: 2,
                    quota: PercentRange(exact: 81), usable: PercentRange(exact: 81),
                    bars: [bar("go-1", 0, 84), bar("go-2", 1, 78)], nextRefill: nil, allFull: false,
                    pace: nil,
                    accounts: [detail("go-1", 84, read: "12:40", stale: true), detail("go-2", 78)]),
                unclassified: [],
                forecast: ForecastSummary(poolBurnPerHour: 4, lockout: .safe, weekly: [])),
        ],
        sources: [.cliproxy: .failing(.unreachable, since: at("13:02")), .ocgo: .ok(at: at("13:19"))])
}
