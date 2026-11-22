import Foundation
import Testing
import UsageCore

@Suite("T1 tracer pool (Pool rule 1)")
struct TracerPoolTests {
    let now = date("2026-11-22T12:00:00Z")

    private func dashboard(_ snapshot: SourceSnapshot,
                           sources: [SourceKind: SourceStatus]? = nil) -> DashboardModel {
        TracerPool.dashboard(TracerLedger(snapshot: snapshot), PoolSettings(),
                             sources ?? [.ocgo: .ok(at: now), .cliproxy: .notConfigured], now)
    }

    @Test func fixtureGives48Percent() async throws {
        let transport = RecordingTransport(body: try Fixtures.data("synthetic/T1/ocgo-status.json"))
        let source = OcgoSource(config: SourceConfig(url: URL(string: "http://x")!, secret: nil),
                                transport: transport, now: FixedNowProvider(now))
        let model = dashboard(try await source.fetch(since: nil).get())

        #expect(model.rows.map(\.provider) == [.go])
        let gauge = try #require(model.row(.go)?.fiveHour)
        #expect(gauge.usable == PercentRange(exact: 48))   // (48 + 60 + 36) / 3
        #expect(gauge.quota == PercentRange(exact: 48))
        #expect(gauge.known == 3 && gauge.total == 3)
        #expect(gauge.bars.map(\.remaining) == [60, 48, 36])
        #expect(gauge.bars.map(\.alias) == ["team-b", "team-a", "team-c"])
        #expect(!gauge.allFull)
        #expect(model.sources[.cliproxy] == .notConfigured)
    }

    @Test func unknownAccountGivesRange() {
        // E1: remaining 70 and 53, third unknown -> 41-74%.
        let snapshot = Self.snapshot(used: [30, 47, nil], at: now)
        let gauge = dashboard(snapshot).row(.go)?.fiveHour
        #expect(gauge?.known == 2)
        #expect(gauge?.total == 3)
        #expect(gauge?.usable == PercentRange(lower: 123.0 / 3, upper: 223.0 / 3))
        #expect(gauge?.bars.count == 2)
    }

    @Test func notConfiguredSourceGivesNoRow() {
        let snapshot = Self.snapshot(used: [10], at: now)
        #expect(dashboard(snapshot, sources: [.ocgo: .notConfigured]).rows.isEmpty)
    }

    static func snapshot(used: [Double?], at now: Date) -> SourceSnapshot {
        let names = used.indices.map { "acct-\($0)" }
        return SourceSnapshot(
            source: .ocgo, takenAt: now,
            accounts: names.map {
                AccountSnapshot(id: AccountID(provider: .go, identity: $0), fileKey: $0, email: nil,
                                enabled: true, unavailable: [], requestCounter: nil, routing: nil,
                                polledAt: now, pollError: nil)
            },
            readings: zip(names, used).compactMap { name, u in
                u.map { SourceReading(provider: .go, fileKey: name, window: .fiveHour, usedPercent: $0,
                                      resetsAt: nil, observedAt: now, source: .ocgo) }
            },
            unclassified: [], routing: nil)
    }
}
