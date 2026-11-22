import Foundation
import Testing
import UsageCore

// Expected values come from docs/implementation-plan.md "Worked examples" and plan.md
// "Pool rules" / "Weekly gauge", not from the engine's output.

private let minute: TimeInterval = 60
private let hour: TimeInterval = 3600
private let day: TimeInterval = 24 * hour

private func t(_ hhmm: String) -> Date { date("2026-11-22T\(hhmm):00Z") }

private func close(_ a: Double?, _ b: Double) -> Bool {
    guard let a else { return false }
    return abs(a - b) < 1e-9
}

private func close(_ r: PercentRange?, _ lower: Double, _ upper: Double) -> Bool {
    close(r?.lower, lower) && close(r?.upper, upper)
}

private let bothOK: [SourceKind: SourceStatus] = [
    .cliproxy: .ok(at: t("12:59")), .ocgo: .ok(at: t("12:59")),
]

private func build(_ ledger: T3FakeLedgerView, now: Date,
                   settings: PoolSettings = PoolSettings(),
                   sources: [SourceKind: SourceStatus] = bothOK) -> DashboardModel {
    PoolEngine.dashboard(ledger: ledger, settings: settings, sources: sources, now: now)
}

@Suite("T3 pool engine")
struct T3PoolEngineTests {
    let now = t("13:00")

    @Test func matchesDashboardBuilder() {
        let builder: DashboardBuilder = PoolEngine.dashboard
        let model = builder(T3FakeLedgerView(), PoolSettings(), bothOK, now)
        #expect(model.generatedAt == now)
        #expect(model.rows.isEmpty)
    }

    // MARK: Pool rules 1 and 3

    @Test func e1UnknownAccountGivesRange() throws {
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "claude-1")
        let b = l.add(.claude, "claude-2")
        l.add(.claude, "claude-3")
        l.set(a, .fiveHour, used: 30, resets: t("15:00"), at: now)
        l.set(b, .fiveHour, used: 47, resets: t("16:00"), at: now)

        let g = try #require(build(l, now: now).row(.claude)?.fiveHour)
        #expect(close(g.quota, 123.0 / 3, 223.0 / 3))   // 41-74%
        #expect(close(g.usable, 123.0 / 3, 223.0 / 3))
        #expect(g.known == 2 && g.total == 3)
        #expect(g.bars.map(\.alias) == ["claude-1", "claude-2"])
        #expect(g.bars.map(\.remaining) == [70, 53])
        let unknown = try #require(g.accounts.first { $0.alias == "claude-3" })
        #expect(unknown.remaining == nil && unknown.previous == nil)
    }

    // MARK: Pool rule 4

    @Test func e2BlockedByWeeklyIsGreyedAndZeroInUsable() throws {
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "A"), b = l.add(.claude, "B"), c = l.add(.claude, "C")
        l.set(a, .fiveHour, used: 20, resets: t("15:00"), at: now)
        l.set(b, .fiveHour, used: 50, resets: t("15:00"), at: now)
        l.set(b, .weekly, used: 100, resets: t("18:00") + 2 * day, at: now)
        l.set(c, .fiveHour, used: 65, resets: t("15:00"), at: now)

        let g = try #require(build(l, now: now).row(.claude)?.fiveHour)
        #expect(close(g.quota, 55, 55))
        #expect(close(g.usable, 115.0 / 3, 115.0 / 3))   // 38%
        #expect(g.bars.map(\.alias) == ["A", "B", "C"])
        #expect(g.bars.map(\.greyed) == [false, true, false])
        let bDetail = try #require(g.accounts.first { $0.alias == "B" })
        #expect(!bDetail.usable)
        #expect(bDetail.blockedReason?.contains("weekly") == true)
        #expect(bDetail.remaining == 50)
    }

    @Test func goMonthlyBlocksFiveHourUsableLikeWeekly() throws {
        var l = T3FakeLedgerView()
        let a = l.add(.go, "team-a"), b = l.add(.go, "team-b")
        l.set(a, .fiveHour, used: 20, resets: t("15:00"), at: now)
        l.set(a, .weekly, used: 50, resets: t("13:00") + 3 * day, at: now)
        l.set(a, .monthly, used: 100, resets: t("13:00") + 10 * day, at: now)
        l.set(b, .fiveHour, used: 40, resets: t("15:00"), at: now)

        let row = try #require(build(l, now: now).row(.go))
        let g = try #require(row.fiveHour)
        #expect(close(g.quota, 70, 70))      // (80 + 60) / 2
        #expect(close(g.usable, 30, 30))     // (0 + 60) / 2
        #expect(g.bars.map(\.greyed) == [true, false])
        #expect(g.accounts.first?.blockedReason?.contains("monthly") == true)
        // Blocked until the monthly reset, ten days out: B's 15:00 reset comes first.
        #expect(g.nextRefill == WindowGauge.NextRefill(at: t("15:00"), poolGain: 20))
        #expect(row.monthly?.total == 2)
        #expect(row.weekly?.usable == row.weekly?.quota)
    }

    @Test func monthlyGaugeOnlyForGo() {
        var l = T3FakeLedgerView()
        l.add(.claude, "claude-1")
        l.add(.go, "team-a")
        let model = build(l, now: now)
        #expect(model.row(.claude)?.monthly == nil)
        #expect(model.row(.claude)?.weekly != nil)
        #expect(model.row(.go)?.monthly != nil)
    }

    // MARK: Pool rule 5

    @Test func e3NextRefill() throws {
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "A"), b = l.add(.claude, "B"), c = l.add(.claude, "C")
        l.set(a, .fiveHour, used: 80, resets: t("14:10"), at: now)
        l.set(b, .fiveHour, used: 40, resets: t("15:30"), at: now)
        l.set(c, .fiveHour, used: 0, resets: t("17:00"), at: now)

        let g = try #require(build(l, now: now).row(.claude)?.fiveHour)
        let refill = try #require(g.nextRefill)
        #expect(refill.at == t("14:10"))
        #expect(close(refill.poolGain, 80.0 / 3))   // +27%
        #expect(!g.allFull)
    }

    @Test func e3bBlockedResetIsNotARefill() throws {
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "A"), b = l.add(.claude, "B"), c = l.add(.claude, "C")
        l.set(a, .fiveHour, used: 80, resets: t("14:10"), at: now)
        l.set(a, .weekly, used: 100, resets: t("16:00"), at: now)
        l.set(b, .fiveHour, used: 40, resets: t("15:30"), at: now)
        l.set(c, .fiveHour, used: 0, resets: t("17:00"), at: now)

        let refill = try #require(build(l, now: now).row(.claude)?.fiveHour?.nextRefill)
        #expect(refill.at == t("15:30"))
        #expect(close(refill.poolGain, 40.0 / 3))   // +13%
    }

    /// A is empty (5-hour 0% left, reset 15:00) and weekly-blocked until 14:00. When the
    /// block ends it is still empty, so its usable quota first rises at 15:00, by 100.
    /// C is full and usable. B, when present, is usable at 60 left.
    static let blockedEmptyCases: [(bReset: String?, at: String, gain: Double)] = [
        (nil, "15:00", 100.0 / 3),           // A the only non-full account
        ("15:00", "15:00", 140.0 / 3),       // A (+100) and B (+40) refill together
        ("16:00", "15:00", 100.0 / 3),       // A's 15:00 comes before B's 16:00
    ]

    @Test(arguments: blockedEmptyCases)
    func blockedEmptyAccountRefillsAtLaterFiveHourReset(bReset: String?, at: String,
                                                        gain: Double) throws {
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "A"), b = l.add(.claude, "B"), c = l.add(.claude, "C")
        l.set(a, .fiveHour, used: 100, resets: t("15:00"), at: now)
        l.set(a, .weekly, used: 100, resets: t("14:00"), at: now)
        l.set(b, .fiveHour, used: bReset == nil ? 0 : 40, resets: t(bReset ?? "17:00"), at: now)
        l.set(c, .fiveHour, used: 0, resets: t("17:00"), at: now)

        let refill = try #require(build(l, now: now).row(.claude)?.fiveHour?.nextRefill)
        #expect(refill.at == t(at))
        #expect(close(refill.poolGain, gain))
    }

    @Test func e4AllFullAndUsable() throws {
        var l = T3FakeLedgerView()
        for name in ["A", "B", "C"] {
            l.set(l.add(.claude, name), .fiveHour, used: 0, resets: t("17:00"), at: now)
        }
        let g = try #require(build(l, now: now).row(.claude)?.fiveHour)
        #expect(g.allFull)
        #expect(g.nextRefill == nil)
        #expect(close(g.usable, 100, 100))
    }

    @Test func e4bCoolingDownAccountIsNotAllFull() throws {
        var l = T3FakeLedgerView()
        l.set(l.add(.claude, "A"), .fiveHour, used: 0, resets: t("17:00"), at: now)
        l.set(l.add(.claude, "B", unavailable: [.coolingDown(until: t("13:40"))]),
              .fiveHour, used: 0, resets: t("17:00"), at: now)
        l.set(l.add(.claude, "C"), .fiveHour, used: 0, resets: t("17:00"), at: now)

        let g = try #require(build(l, now: now).row(.claude)?.fiveHour)
        #expect(!g.allFull)
        #expect(close(g.usable, 200.0 / 3, 200.0 / 3))   // 67%
        #expect(close(g.quota, 100, 100))
        let refill = try #require(g.nextRefill)
        #expect(refill.at == t("13:40"))                  // "reset in 40m"
        #expect(close(refill.poolGain, 100.0 / 3))        // +33%
    }

    @Test func e4cAllDisabledGivesNoQuotaNoCountdown() throws {
        var l = T3FakeLedgerView()
        for name in ["A", "B", "C"] {
            l.set(l.add(.claude, name, enabled: false), .fiveHour, used: 0, resets: t("17:00"),
                  at: now)
        }
        let g = try #require(build(l, now: now).row(.claude)?.fiveHour)
        #expect(!g.allFull)
        #expect(g.quota == nil)
        #expect(g.usable == nil)
        #expect(g.nextRefill == nil)
        #expect(g.total == 0)
    }

    @Test func disabledAccountsLeftOutOfTotal() throws {
        var l = T3FakeLedgerView()
        l.set(l.add(.claude, "A"), .fiveHour, used: 20, resets: t("15:00"), at: now)
        l.set(l.add(.claude, "B", enabled: false), .fiveHour, used: 0, resets: t("15:00"), at: now)
        l.add(.claude, "C", enabled: false)   // unknown, but disabled: no range

        let g = try #require(build(l, now: now).row(.claude)?.fiveHour)
        #expect(g.total == 1 && g.known == 1)
        #expect(close(g.quota, 80, 80))
        #expect(g.bars.map(\.alias) == ["A"])
        #expect(g.accounts.map(\.alias) == ["A"])
    }

    // MARK: Pool rule 3, reset proof (E5 to E5e as the ledger answers them)

    /// E5..E5e: A used 40, resets 12:00, read at 11:50; the dashboard is built at 12:05.
    /// The ledger's proof answer per example: E5 true, every other one false.
    @Test(arguments: [("E5", true), ("E5b", false), ("E5c", false), ("E5d", false),
                      ("E5e", false)])
    func e5ResetProof(example: String, proven: Bool) throws {
        let now = t("12:05")
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "A")
        l.set(a, .fiveHour, used: 40, resets: t("12:00"), at: t("11:50"))
        l.prove(a, .fiveHour, resetAt: t("12:00"), proven)

        let g = try #require(build(l, now: now).row(.claude)?.fiveHour, "\(example)")
        let detail = try #require(g.accounts.first)
        if proven {
            #expect(detail.remaining == 100, "\(example)")
            #expect(detail.previous == nil, "\(example)")
            #expect(close(g.quota, 100, 100), "\(example)")
            #expect(g.known == 1, "\(example)")
        } else {
            #expect(detail.remaining == nil, "\(example)")
            #expect(detail.previous == AccountDetail.Previous(value: 60, observedAt: t("11:50")),
                    "\(example)")
            #expect(close(g.quota, 0, 100), "\(example)")
            #expect(g.known == 0 && g.bars.isEmpty, "\(example)")
        }
    }

    @Test func unprovenWeeklyResetDoesNotBlock() throws {
        // Weekly at 100% used but past its reset with no proof: unknown, not a block.
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "A")
        l.set(a, .fiveHour, used: 50, resets: t("15:00"), at: now)
        l.set(a, .weekly, used: 100, resets: t("12:00"), at: t("11:00"))
        let g = try #require(build(l, now: now).row(.claude)?.fiveHour)
        #expect(g.accounts.first?.usable == true)
        #expect(close(g.usable, 50, 50))
    }

    // MARK: Pool rule 6

    @Test func staleAtThresholdWithDefault() throws {
        var l = T3FakeLedgerView()
        l.set(l.add(.claude, "fresh"), .fiveHour, used: 10, resets: t("15:00"),
              at: now - 29 * minute)
        l.set(l.add(.claude, "stale"), .fiveHour, used: 10, resets: t("15:00"),
              at: now - 31 * minute)

        let g = try #require(build(l, now: now).row(.claude)?.fiveHour)
        #expect(g.accounts.map(\.stale) == [false, true])
        #expect(g.accounts.map(\.observedAt) == [now - 29 * minute, now - 31 * minute])
        // An old reading still counts (Pool rule 3): both are known.
        #expect(g.known == 2)

        let short = try #require(build(l, now: now, settings: PoolSettings(staleAfter: 600))
            .row(.claude)?.fiveHour)
        #expect(short.accounts.map(\.stale) == [true, true])
    }

    @Test func unknownAccountStalenessFollowsPreviousReading() throws {
        // Both past their 12:00 reset with no proof: unknown, hover shows the old value.
        var l = T3FakeLedgerView()
        l.set(l.add(.claude, "old"), .fiveHour, used: 40, resets: t("12:00"),
              at: now - 40 * minute)
        l.set(l.add(.claude, "recent"), .fiveHour, used: 40, resets: t("12:00"),
              at: now - 20 * minute)

        let g = try #require(build(l, now: now).row(.claude)?.fiveHour)
        #expect(g.accounts.map(\.remaining) == [nil, nil])
        #expect(g.accounts.map(\.previous?.observedAt) == [now - 40 * minute, now - 20 * minute])
        #expect(g.accounts.map(\.stale) == [true, false])
        #expect(g.known == 0)
    }

    // MARK: Weekly pace

    @Test func e11PaceMarker() throws {
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "A"), b = l.add(.claude, "B")
        l.set(a, .weekly, used: 30, resets: now + 3.5 * day, at: now)
        l.set(b, .weekly, used: 50, resets: t("12:00"), at: t("11:00"))
        l.prove(b, .weekly, resetAt: t("12:00"), true)

        let g = try #require(build(l, now: now).row(.claude)?.weekly)
        #expect(close(g.pace, 0.75))   // (0.5 + 1) / 2
        #expect(close(g.quota, 85, 85))
        #expect(g.nextRefill == nil)
    }

    @Test func e11KnownUsageWithoutResetHidesPace() throws {
        var l = T3FakeLedgerView()
        let a = l.add(.claude, "A"), c = l.add(.claude, "C")
        l.set(a, .weekly, used: 30, resets: now + 3.5 * day, at: now)
        l.set(c, .weekly, used: 10, resets: nil, at: now)
        #expect(build(l, now: now).row(.claude)?.weekly?.pace == nil)
    }

    @Test func paceUnsetResetAtZeroUsedCountsAsFullWeekAndUnknownIsSkipped() throws {
        var l = T3FakeLedgerView()
        let a = l.add(.codex, "A"), b = l.add(.codex, "B")
        l.add(.codex, "C")   // unknown: not in the marker
        l.set(a, .weekly, used: 30, resets: now + 3.5 * day, at: now)
        l.set(b, .weekly, used: 0, resets: nil, at: now)
        let g = try #require(build(l, now: now).row(.codex)?.weekly)
        #expect(close(g.pace, 0.75))
        #expect(build(l, now: now).row(.codex)?.fiveHour?.pace == nil)
    }

    // MARK: E8, dashboard half

    @Test func e8UnclassifiedInHoverEvenWithoutABar() throws {
        var l = T3FakeLedgerView()
        let a = l.add(.codex, "codex-1"), b = l.add(.codex, "codex-2")
        l.set(a, .weekly, used: 20, resets: now + 2 * day, at: now)
        l.unclassifiedReadings[b] = [UnclassifiedReading(
            provider: .codex, fileKey: "codex-2", lengthSeconds: nil, usedPercent: 12,
            resetsAt: nil, observedAt: now)]

        let row = try #require(build(l, now: now).row(.codex))
        #expect(row.unclassified == [UnclassifiedDetail(
            alias: "codex-2", lengthSeconds: nil, usedPercent: 12, resetsAt: nil,
            observedAt: now)])
        #expect(row.weekly?.bars.map(\.alias) == ["codex-1"])
        #expect(row.fiveHour?.bars.isEmpty == true)
        #expect(row.fiveHour?.known == 0)
        #expect(row.forecast == nil)
    }

    // MARK: Sources

    @Test func notConfiguredOcgoGivesNoGoRowAndSourcesPassThrough() {
        var l = T3FakeLedgerView()
        l.set(l.add(.go, "team-a"), .fiveHour, used: 10, resets: t("15:00"), at: now)
        l.set(l.add(.claude, "claude-1"), .fiveHour, used: 10, resets: t("15:00"), at: now)
        let sources: [SourceKind: SourceStatus] = [
            .ocgo: .notConfigured,
            .cliproxy: .failing(.timeout, since: t("12:30")),
        ]
        let model = build(l, now: now, sources: sources)
        #expect(model.row(.go) == nil)
        #expect(model.rows.map(\.provider) == [.claude])
        #expect(model.sources == sources)
    }

    @Test func rowsInProviderOrder() {
        var l = T3FakeLedgerView()
        l.add(.go, "team-a")
        l.add(.codex, "codex-1")
        l.add(.claude, "claude-1")
        #expect(build(l, now: now).rows.map(\.provider) == [.claude, .codex, .go])
    }
}
