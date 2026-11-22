import Foundation
import Testing
@testable import UsageCore

@Suite("T1 ocgo source")
struct OcgoSourceT1Tests {
    let fixture = "synthetic/T1/ocgo-status.json"
    let now = FixedNowProvider(date("2026-11-22T12:00:00Z"))
    let config = SourceConfig(url: URL(string: "http://ocgo.test:8320")!, secret: "tok")

    @Test func parsesRollingWindowOfEachAccount() async throws {
        let transport = RecordingTransport(body: try Fixtures.data(fixture))
        let source = OcgoSource(config: config, transport: transport, now: now)
        let snapshot = try await source.fetch(since: nil).get()

        #expect(snapshot.source == .ocgo)
        #expect(snapshot.takenAt == now.now)
        #expect(snapshot.accounts.map(\.fileKey) == ["team-a", "team-b", "team-c"])
        #expect(snapshot.accounts.allSatisfy { $0.id.provider == .go && $0.id.identity == $0.fileKey })
        #expect(snapshot.accounts.allSatisfy { $0.enabled && $0.unavailable.isEmpty && $0.requestCounter == nil })
        #expect(snapshot.routing?.strategy == .mostHeadroom)
        #expect(snapshot.routing?.forcedAccount == nil)

        #expect(snapshot.readings.map(\.usedPercent) == [52, 40, 64])
        #expect(snapshot.readings.allSatisfy { $0.window == .fiveHour && $0.source == .ocgo && $0.provider == .go })

        let a = try #require(snapshot.readings.first { $0.fileKey == "team-a" })
        #expect(abs(a.observedAt.timeIntervalSince(date("2026-11-22T11:58:30.123Z"))) < 0.001)
        #expect(a.resetsAt == date("2026-11-22T14:10:00Z"))
        let b = try #require(snapshot.readings.first { $0.fileKey == "team-b" })
        #expect(b.resetsAt == date("2026-11-22T15:30:00Z"))
        let c = try #require(snapshot.readings.first { $0.fileKey == "team-c" })
        #expect(c.resetsAt == nil, "Go zero time means unset")
        #expect(snapshot.accounts.first?.polledAt == a.observedAt)
        #expect(snapshot.accounts.allSatisfy { $0.pollError == nil })
    }

    @Test func sendsOneBearerRequestToStatusPath() async throws {
        let transport = RecordingTransport(body: try Fixtures.data(fixture))
        let source = OcgoSource(config: config, transport: transport, now: now)
        _ = await source.fetch(since: nil)

        #expect(transport.requests.count == 1)
        let r = try #require(transport.requests.first)
        #expect(r.url?.absoluteString == "http://ocgo.test:8320/_ocgo/status")
        #expect(r.httpMethod == "GET")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func unauthorizedIsOneRequest() async {
        let transport = RecordingTransport(status: 401)
        let source = OcgoSource(config: config, transport: transport, now: now)
        #expect(await source.test(config) == .failure(.unauthorized))
        #expect(await source.fetch(since: nil).failureValue == .unauthorized)
        #expect(transport.requests.count == 2)
    }

    @Test(arguments: [
        (URLError.Code.timedOut, SourceError.timeout),
        (.serverCertificateUntrusted, .tlsUntrusted),
        (.cannotConnectToHost, .unreachable),
    ])
    func mapsTransportErrors(code: URLError.Code, expected: SourceError) async {
        let transport = RecordingTransport(error: URLError(code))
        let source = OcgoSource(config: config, transport: transport, now: now)
        #expect(await source.fetch(since: nil).failureValue == expected)
    }

    @Test func otherStatusAndBadBody() async {
        let s500 = OcgoSource(config: config, transport: RecordingTransport(status: 500), now: now)
        #expect(await s500.fetch(since: nil).failureValue == .http(500))
        let bad = OcgoSource(config: config, transport: RecordingTransport(body: Data("{}".utf8)), now: now)
        guard case .decoding = await bad.fetch(since: nil).failureValue else {
            Issue.record("expected a decoding error")
            return
        }
    }

    @Test func neverPolledAndNonOkWindowsGiveNoReading() throws {
        let body = """
        { "accounts": [
          { "name": "fresh", "available": true, "headroom": 100,
            "windows": { "rolling": { "status": "ok", "percent": 0 } } },
          { "name": "err", "available": true, "polled_at": "2026-11-22T11:00:00Z",
            "windows": { "rolling": { "status": "error", "percent": 0 } } }
        ] }
        """
        let snapshot = try OcgoStatusParser.snapshot(from: Data(body.utf8), takenAt: now.now).get()
        #expect(snapshot.accounts.count == 2)
        #expect(snapshot.readings.isEmpty)
    }

    @Test func testReportsAccountCount() async throws {
        let source = OcgoSource(config: config, transport: RecordingTransport(body: try Fixtures.data(fixture)), now: now)
        #expect(try await source.test(config).get() == "ocgo-proxy answered with 3 account(s)")
    }
}

@Suite("Wire dates")
struct WireDateTests {
    @Test func unsetValues() {
        #expect(WireDate.parse(nil) == nil)
        #expect(WireDate.parse("") == nil)
        #expect(WireDate.parse("0001-01-01T00:00:00Z") == nil)
        #expect(WireDate.parse("1970-01-01T00:00:00Z") == nil)
        #expect(WireDate.parse("not a date") == nil)
    }

    @Test func offsetsAndFractions() {
        #expect(WireDate.parse("2026-11-22T13:00:00+01:00") == date("2026-11-22T12:00:00Z"))
        let nanos = WireDate.parse("2026-11-22T12:00:00.5Z")
        #expect(nanos == date("2026-11-22T12:00:00.500Z"))
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
