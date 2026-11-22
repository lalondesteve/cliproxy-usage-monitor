import Foundation
import Testing
@testable import UsageCore

/// A transport that answers every request with the body currently set.
final class T10SwitchingTransport: HTTPTransport, @unchecked Sendable {
    private let body: T8Box<Data>
    private let requests = T8Box<[URLRequest]>([])

    init(_ body: Data) { self.body = T8Box(body) }

    func set(_ data: Data) { body.set(data) }
    var paths: [String] { requests.get.map { $0.url?.path ?? "" } }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.update { $0.append(r) }
        return (body.get, HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// T10's E16 pipeline test: the two raw synthetic `/_ocgo/status` responses go through
/// T7 (OcgoSource), T8 (PollCoordinator, with SQLite history), T4 (Ledger) and T3
/// (PoolEngine). Expected values come from E16 in docs/implementation-plan.md and
/// plan.md Pool rules 1 and 3, not from running the code.
@Suite("T10 E16 pipeline")
struct T10PipelineTests {
    @Test func e16ThroughTheCoordinator() async throws {
        let transport = T10SwitchingTransport(try Fixtures.data("synthetic/T7/e16-1150.json"))
        let clock = T8Clock(date("2026-11-22T11:50:00Z"))
        let pipeline = try T10Pipeline(transport: transport, clock: clock, configured: [.ocgo])

        await pipeline.coordinator.tick()
        let first = try #require(await pipeline.coordinator.model?.row(.go))
        // 11:50: rolling 60% used, weekly 30% used, both fresh.
        #expect(first.fiveHour?.quota == PercentRange(exact: 40))
        #expect(first.weekly?.quota == PercentRange(exact: 70))

        transport.set(try Fixtures.data("synthetic/T7/e16-1202.json"))
        clock.set(date("2026-11-22T12:02:00Z"))
        await pipeline.coordinator.tick()
        let model = try #require(await pipeline.coordinator.model)
        #expect(transport.paths == ["/_ocgo/status", "/_ocgo/status"])
        #expect(model.sources[.ocgo] == .ok(at: date("2026-11-22T12:02:00Z")))
        #expect(model.sources[.cliproxy] == .notConfigured)
        #expect(model.rows.map(\.provider) == [.go])
        let row = try #require(model.row(.go))

        // Rolling: a fresh ok reading after the 12:00 reset, 5% used: 95% left.
        let fiveHour = try #require(row.fiveHour)
        #expect(fiveHour.known == 1 && fiveHour.total == 1)
        #expect(fiveHour.quota == PercentRange(exact: 95))
        #expect(fiveHour.usable == PercentRange(exact: 95))
        #expect(fiveHour.accounts.first?.remaining == 95)
        #expect(fiveHour.accounts.first?.observedAt == date("2026-11-22T12:02:00Z"))

        // Weekly: the 12:02 window is status "error", and 11:50's reading is past its
        // 12:00 reset with no proof the account was unused since: unknown, so the pool
        // is the 0-100 range (Pool rule 3), and the hover keeps 70% from 11:50.
        let weekly = try #require(row.weekly)
        #expect(weekly.known == 0 && weekly.total == 1)
        #expect(weekly.quota == PercentRange(lower: 0, upper: 100))
        #expect(weekly.bars.isEmpty)
        let hover = try #require(weekly.accounts.first)
        #expect(hover.alias == "team-a")
        #expect(hover.remaining == nil)
        #expect(hover.previous?.value == 70)
        #expect(hover.previous?.observedAt == date("2026-11-22T11:50:00Z"))
        #expect(row.forecast == nil)
    }
}

/// T10 review: the saved configuration is read again when a Test succeeds with values
/// the coordinator doesn't poll with (a Keychain read denied at launch cached a nil key).
@Suite("T10 coordinator re-reads the saved config")
struct T10SavedConfigTests {
    static let url = URL(string: "https://cliproxy.test")!

    @Test func successfulTestOfNewlySavedKeyClearsTheLatch() async throws {
        let db = T5TempDatabase()
        let noKey = SourceConfig(url: Self.url, secret: nil)
        let key = SourceConfig(url: Self.url, secret: "saved-key")
        let rig = try T8Rig(db: db, at: date("2026-11-22T12:00:00Z"), configs: [.cliproxy: noKey])
        rig.cliproxy.answer(.failure(.unauthorized))
        await rig.coordinator.tick()
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .authStopped(.unauthorized))

        // The key isn't saved yet: a successful Test of it leaves polling latched.
        rig.cliproxy.answer { now in
            .success(SourceSnapshot(source: .cliproxy, takenAt: now, accounts: [], readings: [],
                                    unclassified: [], routing: nil))
        }
        #expect(await rig.coordinator.test(.cliproxy, key) == .success("ok"))
        #expect(rig.log.count(.fetch(.cliproxy)) == 1)

        // Saved now (the Keychain read succeeds), but the Test sends other values: latched.
        rig.configs.set([.cliproxy: key])
        _ = await rig.coordinator.test(.cliproxy, SourceConfig(url: Self.url, secret: "typed-key"))
        #expect(rig.log.count(.fetch(.cliproxy)) == 1)
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .authStopped(.unauthorized))

        // A Test of the saved values clears the latch and polls at once.
        rig.clock.advance(60)
        #expect(await rig.coordinator.test(.cliproxy, key) == .success("ok"))
        #expect(rig.log.count(.fetch(.cliproxy)) == 2)
        #expect(await rig.coordinator.model?.sources[.cliproxy] == .ok(at: date("2026-11-22T12:01:00Z")))
        rig.clock.advance(60)
        await rig.coordinator.tick()
        #expect(rig.log.count(.fetch(.cliproxy)) == 3)
    }
}
