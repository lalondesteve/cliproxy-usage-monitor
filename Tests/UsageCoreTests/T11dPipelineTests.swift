import Foundation
import Testing
import UsageCore

// T11d: the coordinator publishes each row's forecast from the history it chose for
// that provider. Expected rates are hand arithmetic on the readings below.

private let claudeFile = "claude-1a2b3c4d-a@example.com.json"
private let claudeID = AccountID(provider: .claude, identity: "1a2b3c4d")
private let codexFile = "codex-5e6f7a8b-b@example.com.json"
private let codexID = AccountID(provider: .codex, identity: "5e6f7a8b")

private func claudeSnapshot(at now: Date, used: Double) -> SourceSnapshot {
    SourceSnapshot(
        source: .cliproxy, takenAt: now,
        accounts: [AccountSnapshot(id: claudeID, fileKey: claudeFile, email: "a@example.com",
                                   enabled: true, unavailable: [], requestCounter: 100,
                                   routing: AccountRouting(priority: 0, weight: 1),
                                   polledAt: nil, pollError: nil)],
        readings: [SourceReading(provider: .claude, fileKey: claudeFile, window: .fiveHour,
                                 usedPercent: used, resetsAt: t11d("15:00"), observedAt: now,
                                 source: .passive)],
        unclassified: [],
        routing: RoutingConfig(strategy: .roundRobin, sessionAffinity: false, forcedAccount: nil))
}

/// Passive readings climb 1 point per 5 minutes from 10% at 12:00: 12%/h.
private func passiveAt12PerHour(_ now: Date) -> Result<SourceSnapshot, SourceError> {
    .success(claudeSnapshot(at: now, used: 10 + now.timeIntervalSince(t11d("12:00")) / 300))
}

private func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

@Suite("T11d forecast in the published dashboard")
struct T11dPipelineTests {
    @Test func eachRowGetsItsForecastFromTheHistoryChosenForItsProvider() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t11d("12:00"))
        rig.cliproxy.answer(passiveAt12PerHour)
        // The fork's samples climb 2 points per 5 minutes: 24%/h.
        let forkHistory = [("11:50", 20.0), ("11:55", 22.0), ("12:00", 24.0)].map {
            SourceReading(provider: .claude, fileKey: claudeFile, window: .fiveHour, usedPercent: $0.1,
                          resetsAt: t11d("15:00"), observedAt: t11d($0.0), source: .forkPoller)
        }
        rig.fork.answer(.success(ForkHistoryResponse(providers: [.claude: .served, .codex: .served],
                                                     current: [], history: forkHistory)))
        await rig.coordinator.tick()
        for _ in 0..<2 {
            rig.clock.advance(300)
            await rig.coordinator.tick()
        }

        // 12:10, fork served: 24%/h over one account. 88 left at 0.4 per minute lasts
        // past the 15:00 reset (170 min, 68 used), then a fresh window to 17:10: safe.
        #expect(await rig.coordinator.historyOrigin(.claude) == .fork)
        let model = try #require(await rig.coordinator.model)
        #expect(model.generatedAt == t11d("12:10"))
        #expect(model.rows.map(\.provider) == [.claude])
        let forecast = try #require(model.row(.claude)?.forecast)
        #expect(near(forecast.poolBurnPerHour, 24))
        #expect(forecast.lockout == .safe)
        #expect(forecast.weekly.map(\.account) == [claudeID])
        #expect(forecast.weekly.first?.runOut == nil)   // no weekly readings

        // Paused on the fork: the app's own passive readings, 10 to 13 at 12:00-12:15.
        rig.fork.answer(.success(ForkHistoryResponse(providers: [.claude: .paused], current: [],
                                                     history: [])))
        rig.clock.advance(300)
        await rig.coordinator.tick()
        #expect(await rig.coordinator.historyOrigin(.claude) == .local)
        let local = try #require(await rig.coordinator.model?.row(.claude)?.forecast)
        #expect(near(local.poolBurnPerHour, 12))
        #expect(local.lockout == .safe)
    }

    /// One tick publishes Claude from the fork and Codex from the app's own readings.
    /// Each history has a different rate for each provider, so a row that read the
    /// other history shows the other number.
    @Test func oneTickPublishesTwoProvidersFromDifferentHistories() async throws {
        let db = T5TempDatabase()
        let rig = try T8Rig(db: db, at: t11d("12:00"))
        // Passive: Claude 10 + 1 per 5 min (12%/h), Codex 30 + 0.5 per 5 min (6%/h).
        rig.cliproxy.answer { now in
            let steps = now.timeIntervalSince(t11d("12:00")) / 300
            let s = claudeSnapshot(at: now, used: 10 + steps)
            let codex = AccountSnapshot(id: codexID, fileKey: codexFile, email: "b@example.com",
                                        enabled: true, unavailable: [], requestCounter: 50,
                                        routing: AccountRouting(priority: 0, weight: 1),
                                        polledAt: nil, pollError: nil)
            let reading = SourceReading(provider: .codex, fileKey: codexFile, window: .fiveHour,
                                        usedPercent: 30 + 0.5 * steps, resetsAt: t11d("15:00"),
                                        observedAt: now, source: .passive)
            return .success(SourceSnapshot(source: .cliproxy, takenAt: now,
                                           accounts: s.accounts + [codex],
                                           readings: s.readings + [reading], unclassified: [],
                                           routing: s.routing))
        }
        // Fork: Claude 2 points per 5 min (24%/h), Codex 4 (48%/h); Claude served,
        // Codex paused.
        let fork = [("11:50", 20.0, 40.0), ("11:55", 22.0, 44.0), ("12:00", 24.0, 48.0)].flatMap { t, c, x in
            [SourceReading(provider: .claude, fileKey: claudeFile, window: .fiveHour, usedPercent: c,
                           resetsAt: t11d("15:00"), observedAt: t11d(t), source: .forkPoller),
             SourceReading(provider: .codex, fileKey: codexFile, window: .fiveHour, usedPercent: x,
                           resetsAt: t11d("15:00"), observedAt: t11d(t), source: .forkPoller)]
        }
        rig.fork.answer(.success(ForkHistoryResponse(providers: [.claude: .served, .codex: .paused],
                                                     current: [], history: fork)))
        await rig.coordinator.tick()
        for _ in 0..<2 {
            rig.clock.advance(300)
            await rig.coordinator.tick()
        }

        #expect(await rig.coordinator.historyOrigin(.claude) == .fork)
        #expect(await rig.coordinator.historyOrigin(.codex) == .local)
        let model = try #require(await rig.coordinator.model)
        #expect(model.generatedAt == t11d("12:10"))
        #expect(model.rows.map(\.provider) == [.claude, .codex])
        #expect(near(model.row(.claude)?.forecast?.poolBurnPerHour, 24))
        // Codex: 30, 30.5, 31 at 12:00-12:10.
        #expect(near(model.row(.codex)?.forecast?.poolBurnPerHour, 6))
    }

    @Test func aStoreErrorLeavesTheRowWithoutAForecastAndPublishingGoesOn() async throws {
        let db = T5TempDatabase()
        let clock = T8Clock(t11d("12:00"))
        let cliproxy = T8FakeSource(.cliproxy, log: T8Log(), clock: clock)
        cliproxy.answer(passiveAt12PerHour)
        let store = T11dFailingReadsStore(try SQLiteHistoryStore(path: db.path, now: clock))
        store.failing.set(true)
        let coordinator = PollCoordinator(
            setup: PollSetup(savedConfig: { $0 == .cliproxy ? T8Rig.cliproxyConfig : nil },
                             makeSource: { _, _ in cliproxy }, makeForkSource: { _ in nil }),
            ledger: Ledger(store: store, settings: PoolSettings()), store: store,
            settings: PoolSettings(), clock: clock, scheduler: T8BlockingScheduler())

        for _ in 0..<3 {
            await coordinator.tick()
            let model = try #require(await coordinator.model)
            #expect(model.generatedAt == clock.now)
            let row = try #require(model.row(.claude))
            #expect(row.fiveHour?.quota != nil)
            #expect(row.forecast == nil)
            clock.advance(300)
        }
        #expect(await coordinator.lastStoreError != nil)

        // Reads work again: 10, 11, 12, 13 at 12:00-12:15 give 12%/h (local history).
        store.failing.set(false)
        await coordinator.tick()
        #expect(near(await coordinator.model?.row(.claude)?.forecast?.poolBurnPerHour, 12))
    }
}

/// plan.md Phase 3: routing the simulation doesn't model (session affinity on) gives a
/// withheld lockout forecast, through the real sources, coordinator, ledger and pool
/// engine on the T10 synthetic capture.
@Suite("T11d session affinity through the pipeline")
struct T11dSessionAffinityPipelineTests {
    static let folder = Fixtures.url("synthetic/T10")

    func publish(config: Data?) async throws -> DashboardModel {
        let base = T10FolderTransport(folder: Self.folder)
        let transport = T11dOverridingTransport(
            base: base, overrides: config.map { ["/v0/management/config": $0] } ?? [:])
        let pipeline = try T10Pipeline(transport: transport, clock: T8Clock(date("2026-11-22T12:00:00Z")))
        await pipeline.coordinator.tick()
        return try #require(await pipeline.coordinator.model)
    }

    @Test func sessionAffinityOnWithholdsTheLockoutForecast() async throws {
        let on = try await publish(config: Data(#"{"routing": {"strategy": "round-robin", "session-affinity": true}}"#.utf8))
        #expect(on.rows.map(\.provider) == [.claude, .codex, .go])
        for p in [Provider.claude, .codex] {
            #expect(on.row(p)?.forecast?.lockout == .withheld(reason: "session affinity is on"), "\(p)")
        }
        // ocgo's routing has no session affinity: one reading per account, no rate yet.
        #expect(on.row(.go)?.forecast?.lockout == .insufficientData)

        // The capture as is (affinity off): the same rows aren't withheld.
        let off = try await publish(config: nil)
        #expect(off.row(.claude)?.forecast?.lockout == .insufficientData)
        #expect(off.row(.codex)?.forecast?.lockout == .insufficientData)
    }
}
