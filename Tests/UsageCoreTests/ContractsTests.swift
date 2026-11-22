import Foundation
import Testing
import UsageCore

/// The contract types compile, construct, and the persisted ones round-trip.
@Suite("Contracts")
struct ContractsTests {
    let t = Date(timeIntervalSince1970: 1_764_000_000)

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func snapshotRoundTrips() throws {
        let id = AccountID(provider: .claude, identity: "1a2b3c4d")
        let snapshot = SourceSnapshot(
            source: .cliproxy, takenAt: t,
            accounts: [AccountSnapshot(
                id: id, fileKey: "claude-1a2b3c4d-x@example.com.json", email: "x@example.com",
                enabled: true,
                unavailable: [.upstreamUnavailable, .outOfRotation, .exhausted(until: t),
                              .coolingDown(until: nil), .notForcedAccount],
                requestCounter: 1500, routing: AccountRouting(priority: 1, weight: 2),
                polledAt: nil, pollError: nil)],
            readings: [SourceReading(provider: .claude, fileKey: "f", window: .weekly, usedPercent: 53,
                                     resetsAt: nil, observedAt: t, source: .passive)],
            unclassified: [UnclassifiedReading(provider: .codex, fileKey: "c", lengthSeconds: nil,
                                               usedPercent: 4, resetsAt: t, observedAt: t)],
            routing: RoutingConfig(strategy: .weightedRoundRobin, sessionAffinity: true, forcedAccount: id))
        #expect(try roundTrip(snapshot) == snapshot)
        #expect(try roundTrip(CounterMark(fileKey: "f", at: t, value: 3)) == CounterMark(fileKey: "f", at: t, value: 3))
    }

    @Test func providerKeyedDictionariesEncodeAsObjects() throws {
        let states: [Provider: ForkProviderState] = [.claude: .served, .codex: .paused]
        let json = try #require(String(data: JSONEncoder().encode(states), encoding: .utf8))
        #expect(json.hasPrefix("{"))
        #expect(try roundTrip(states) == states)
    }

    @Test func strategyRawValuesMatchCliproxy() {
        #expect(RoutingConfig.Strategy(rawValue: "round-robin") == .roundRobin)
        #expect(RoutingConfig.Strategy(rawValue: "weighted-round-robin") == .weightedRoundRobin)
        #expect(RoutingConfig.Strategy(rawValue: "fill-first") == .fillFirst)
    }

    @Test func settingsDefaultsAndPartialDecode() throws {
        let s = AppSettings()
        #expect(s.menubarStyle == .normal && !s.activeCallsEnabled && s.pool.staleAfter == 1800)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)) == s)
        let partial = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"menubarStyle":"compact","pool":{"identityAliases":{"a":"b"}}}"#.utf8))
        #expect(partial.menubarStyle == .compact)
        #expect(partial.pool == PoolSettings(staleAfter: 1800, identityAliases: ["a": "b"]))
        var full = AppSettings(cliproxyURL: URL(string: "http://c"), ocgoURL: URL(string: "http://o"))
        full.pool.staleAfter = 600
        full.activeCallsEnabled = true
        #expect(try roundTrip(full) == full)
    }

    @Test func dashboardTypesConstruct() {
        let detail = AccountDetail(alias: "claude-1", email: nil, remaining: nil,
                                   previous: .init(value: 60, observedAt: t), resetsAt: nil,
                                   observedAt: t, stale: true, usable: false, blockedReason: "weekly")
        let gauge = WindowGauge(window: .fiveHour, known: 1, total: 2,
                                quota: PercentRange(lower: 20, upper: 70), usable: PercentRange(exact: 20),
                                bars: [GaugeBar(alias: "claude-1", colorIndex: 0, remaining: 40, greyed: true)],
                                nextRefill: .init(at: t, poolGain: 27), allFull: false, pace: nil,
                                accounts: [detail])
        let claude1 = AccountID(provider: .claude, identity: "1a2b3c4d")
        let claude2 = AccountID(provider: .claude, identity: "5e6f7a8b")
        let forecast = ForecastSummary(
            poolBurnPerHour: 12, lockout: .lockout(from: t, to: t),
            weekly: [WeeklyRunOut(account: claude1, alias: "claude-1", runOut: t, resets: t.addingTimeInterval(86_400)),
                     WeeklyRunOut(account: claude2, alias: "claude-2", runOut: nil, resets: nil)])
        let row = ProviderRow(provider: .claude, fiveHour: gauge, weekly: nil, monthly: nil,
                              unclassified: [UnclassifiedDetail(alias: "codex-1", lengthSeconds: nil,
                                                                usedPercent: 3, resetsAt: nil, observedAt: t)],
                              forecast: forecast)
        let model = DashboardModel(generatedAt: t, rows: [row],
                                   sources: [.cliproxy: .failing(.timeout, since: t), .ocgo: .authStopped(.unauthorized)])
        #expect(model.row(.claude) == row)
        #expect(model == model)
        #expect(gauge.nextRefill?.poolGain == 27)
        #expect(detail.previous?.value == 60)
        #expect(row.forecast?.weekly.map(\.alias) == ["claude-1", "claude-2"])
        #expect(row.forecast?.weekly.last?.runOut == nil)
        #expect([LockoutForecast.safe, .withheld(reason: "affinity"), .insufficientData].count == 3)
        #expect(SourceError.ipBanned.isAuthError && !SourceError.http(404).isAuthError)
    }

    // Protocol conformances compile: fakes later tasks can copy.
    @Test func protocolsAreImplementable() async throws {
        let store: any HistoryStore = FakeStore()
        let alias = try store.alias(for: AccountID(provider: .go, identity: "a"))
        #expect(alias.alias == "go-1" && alias.colorIndex == 0)
        let fork: any ForkHistorySource = FakeFork()
        #expect(await fork.fetch(range: 3600) == .failure(.http(404)))
        let control: any PollControl = FakeControl()
        await control.poolSettingsChanged(PoolSettings())
        let ledger: any LedgerUpdating = FakeLedger()
        ledger.apply(readings: [])
        let builder: DashboardBuilder = TracerPool.dashboard
        #expect(builder(ledger, PoolSettings(), [:], t).rows.isEmpty)
        let _: any NowProvider = SystemNowProvider()
        let _: any HTTPTransport = URLSessionTransport()
    }
}

private struct FakeStore: HistoryStore {
    func append(_ readings: [SourceReading]) throws {}
    func appendCounterMarks(_ marks: [CounterMark]) throws {}
    func saveLastSnapshot(_ s: SourceSnapshot) throws {}
    func lastSnapshots() throws -> [SourceSnapshot] { [] }
    func readings(fileKeys: [String], _ w: WindowKind?, from: Date, to: Date) throws -> [SourceReading] { [] }
    func latestReadings() throws -> [SourceReading] { [] }
    func counterMarks(since: Date) throws -> [CounterMark] { [] }
    func alias(for id: AccountID) throws -> (alias: String, colorIndex: Int) { ("go-1", 0) }
    func lastObservation(_ p: Provider, source: ReadingSource) throws -> Date? { nil }
    func saveForkProviderStates(_ s: [Provider: ForkProviderState]) throws {}
    func forkProviderStates() throws -> [Provider: ForkProviderState] { [:] }
    func recordGap(from: Date, to: Date) throws {}
    func gaps(since: Date) throws -> [DateInterval] { [] }
    func prune(olderThan: Date) throws {}
}

private struct FakeFork: ForkHistorySource {
    func fetch(range: TimeInterval) async -> Result<ForkHistoryResponse, SourceError> { .failure(.http(404)) }
}

private struct FakeControl: PollControl {
    func test(_ kind: SourceKind, _ config: SourceConfig) async -> Result<String, SourceError> { .success("ok") }
    func configChanged(_ kind: SourceKind) async {}
    func poolSettingsChanged(_ settings: PoolSettings) async {}
}

private final class FakeLedger: LedgerUpdating, @unchecked Sendable {
    var accounts: [MergedAccount] { [] }
    var routing: [SourceKind: RoutingConfig] { [:] }
    func latest(_ id: AccountID, _ w: WindowKind) -> WindowReading? { nil }
    func resetProven(_ id: AccountID, _ w: WindowKind, resetAt: Date) -> Bool { false }
    func unclassified(_ id: AccountID) -> [UnclassifiedReading] { [] }
    func updateSettings(_ settings: PoolSettings) {}
    func apply(_ s: SourceSnapshot) {}
    func apply(readings: [SourceReading]) {}
    func restore() throws {}
}
