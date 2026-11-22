import Foundation
import Testing
@testable import UsageCore

@Suite("T6 cliproxy source")
struct T6CliproxySourceTests {
    static let base = "http://cliproxy.test:8317"
    let now = FixedNowProvider(date("2025-11-24T12:45:00Z"))
    let config = SourceConfig(url: URL(string: "\(Self.base)/management.html")!, secret: "mgmt-key")

    let fileA = "claude-1a2b3c4d-user-1@example.com.json"
    let fileB = "claude-user-2@example.com.json"
    let fileC = "codex-user-3@example.com-plus.json"
    let fileD = "codex-user-4@example.com-team.json"
    let fileF = "claude-9f8e7d6c-user-6@example.com.json"

    func fixture(_ name: String) throws -> Data {
        try Fixtures.data("synthetic/T6/\(name)")
    }

    func fullTransport() throws -> T6RoutedTransport {
        T6RoutedTransport([
            T6Paths.credentials: .ok(try fixture("credentials.json")),
            T6Paths.strategy: .ok(try fixture("routing-strategy.json")),
            T6Paths.config: .ok(try fixture("config-routing.json")),
        ])
    }

    func source(_ transport: T6RoutedTransport, config: SourceConfig? = nil) -> CliproxySource {
        CliproxySource(config: config ?? self.config, transport: transport, now: now)
    }

    /// One credential with the given quota object, as a credential list body.
    func listing(provider: String = "claude", file: String = "claude-1a2b3c4d-user-1@example.com.json",
                 quota: String) -> Data {
        Data("""
        [ { "id": "\(file)", "provider": "\(provider)", "email": "user-1@example.com",
            "quota": \(quota) } ]
        """.utf8)
    }

    func readings(_ body: Data) throws -> CliproxyCredentialList {
        try CliproxyCredentialsParser.parse(body).get()
    }

    // MARK: - Credential list

    @Test func parsesCredentialList() async throws {
        let transport = try fullTransport()
        let snapshot = try await source(transport).fetch(since: nil).get()

        #expect(snapshot.source == .cliproxy)
        #expect(snapshot.takenAt == now.now)
        #expect(snapshot.routing == RoutingConfig(strategy: .weightedRoundRobin, sessionAffinity: true,
                                                  forcedAccount: nil))
        // The gemini credential is out of scope and skipped.
        #expect(snapshot.accounts == [
            AccountSnapshot(id: AccountID(provider: .claude, identity: "1a2b3c4d"), fileKey: fileA,
                            email: "user-1@example.com", enabled: true, unavailable: [],
                            requestCounter: 1203, routing: AccountRouting(priority: 0, weight: 1),
                            polledAt: nil, pollError: nil),
            AccountSnapshot(id: AccountID(provider: .claude, identity: "user-2@example.com"),
                            fileKey: fileB, email: "user-2@example.com", enabled: false,
                            unavailable: [], requestCounter: nil,
                            routing: AccountRouting(priority: 0, weight: 1), polledAt: nil,
                            pollError: nil),
            AccountSnapshot(id: AccountID(provider: .codex, identity: "00000000-0000-4000-8000-000000000001"),
                            fileKey: fileC, email: "user-3@example.com", enabled: true,
                            unavailable: [.upstreamUnavailable, .outOfRotation], requestCounter: 50,
                            routing: AccountRouting(priority: 2, weight: 0), polledAt: nil,
                            pollError: nil),
            AccountSnapshot(id: AccountID(provider: .codex, identity: "00000000-0000-4000-8000-000000000002"),
                            fileKey: fileD, email: "user-4@example.com", enabled: true,
                            unavailable: [], requestCounter: 9,
                            routing: AccountRouting(priority: 1, weight: 3), polledAt: nil,
                            pollError: nil),
            AccountSnapshot(id: AccountID(provider: .claude, identity: "9f8e7d6c"), fileKey: fileF,
                            email: "user-6@example.com", enabled: true, unavailable: [.outOfRotation],
                            requestCounter: 0, routing: AccountRouting(priority: 0, weight: -1),
                            polledAt: nil, pollError: nil),
        ])
    }

    @Test func parsesPassiveSignalsOfFixture() async throws {
        let snapshot = try await source(try fullTransport()).fetch(since: nil).get()
        #expect(snapshot.readings.count == 5)

        func reading(_ file: String, _ w: WindowKind) -> SourceReading? {
            snapshot.readings.first { $0.fileKey == file && $0.window == w }
        }
        let a5 = try #require(reading(fileA, .fiveHour))
        #expect(abs(a5.usedPercent - 53) < 1e-9)
        #expect(a5.resetsAt == date("2025-11-24T16:00:00Z"))
        #expect(a5.observedAt == date("2025-11-24T12:00:00Z"))
        #expect(a5.source == .passive && a5.provider == .claude)
        let a7 = try #require(reading(fileA, .weekly))
        #expect(abs(a7.usedPercent - 20) < 1e-9)
        #expect(a7.resetsAt == date("2025-11-30T10:53:20Z"))

        // String-array values, lowercase names, reset "0" is unset.
        let b7 = try #require(reading(fileB, .weekly))
        #expect(b7.usedPercent == 25)
        #expect(b7.resetsAt == nil)
        #expect(b7.observedAt == date("2025-11-24T11:00:00Z"))
        #expect(reading(fileB, .fiveHour) == nil)

        let d5 = try #require(reading(fileD, .fiveHour))
        #expect(d5.usedPercent == 5)
        #expect(d5.resetsAt == date("2025-11-24T13:13:20Z"))
        #expect(d5.provider == .codex)
    }

    @Test func sendsCredentialListThenRoutingThenConfig() async throws {
        let transport = try fullTransport()
        _ = await source(transport).fetch(since: nil)
        #expect(transport.paths == [T6Paths.credentials, T6Paths.strategy, T6Paths.config])
        for r in transport.requests {
            #expect(r.httpMethod == "GET")
            #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer mgmt-key")
        }
        #expect(transport.requests.first?.url?.absoluteString
            == "\(Self.base)/v8/management/credentials")
    }

    @Test func acceptsBareArrayListing() throws {
        let list = try readings(listing(quota: "null"))
        #expect(list.credentials.map(\.fileKey) == [fileA])
        #expect(list.readings.isEmpty)
    }

    // MARK: - Passive signals

    @Test("E6: Claude utilization is a fraction, clamped; reset in epoch seconds")
    func e6ClaudeUtilization() async throws {
        let quota = { (u: String) in """
            { "observed_at": "2025-11-24T12:00:00Z", "signals": {
                "Anthropic-Ratelimit-Unified-5h-Utilization": "\(u)",
                "Anthropic-Ratelimit-Unified-5h-Reset": "1764000000" } }
            """ }
        let transport = T6RoutedTransport([T6Paths.credentials: .ok(listing(quota: quota("0.53")))])
        let s = source(transport)
        let first = try #require(try await s.fetch(since: nil).get().readings.first)
        transport.set(T6Paths.credentials, .ok(listing(quota: quota("1.2"))))
        let second = try #require(try await s.fetch(since: nil).get().readings.first)

        #expect(abs(first.usedPercent - 53) < 1e-9)
        #expect(second.usedPercent == 100)
        #expect(first.window == .fiveHour && second.window == .fiveHour)
        #expect(first.resetsAt == date("2025-11-24T16:00:00Z"))
        #expect(second.resetsAt == date("2025-11-24T16:00:00Z"))
    }

    @Test("E8: Codex windows by length; no length is unclassified")
    func e8CodexWindows() async throws {
        let snapshot = try await source(try fullTransport()).fetch(since: nil).get()
        let c = snapshot.readings.filter { $0.fileKey == fileC }
        #expect(c.map(\.window) == [.weekly], "primary 10080 min with no secondary is weekly")
        #expect(c.first?.usedPercent == 37)
        #expect(snapshot.unclassified == [
            UnclassifiedReading(provider: .codex, fileKey: fileD, lengthSeconds: nil, usedPercent: 12,
                                resetsAt: date("2025-11-24T16:00:00Z"),
                                observedAt: date("2025-11-24T12:30:00Z")),
        ])
    }

    @Test func codexOtherLengthIsUnclassifiedWithItsLength() throws {
        let list = try readings(listing(provider: "codex", file: "codex-x.json", quota: """
            { "observed_at": "2025-11-24T12:00:00Z", "signals": {
                "X-Codex-Primary-Used-Percent": "40", "X-Codex-Primary-Window-Minutes": "1440" } }
            """))
        #expect(list.readings.isEmpty)
        #expect(list.unclassified.first?.lengthSeconds == 86400)
    }

    @Test func headerNamesMatchCaseInsensitively() throws {
        let claude = try readings(listing(quota: """
            { "observed_at": "2025-11-24T12:00:00Z", "signals": {
                "ANTHROPIC-RATELIMIT-UNIFIED-5H-UTILIZATION": "0.1",
                "anthropic-ratelimit-unified-5h-reset": "1764000000",
                "aNtHrOpIc-RaTeLiMiT-uNiFiEd-7D-uTiLiZaTiOn": ["0.4"] } }
            """))
        #expect(claude.readings.map(\.window) == [.fiveHour, .weekly])
        #expect(abs(claude.readings[0].usedPercent - 10) < 1e-9)
        #expect(claude.readings[0].resetsAt == date("2025-11-24T16:00:00Z"))
        #expect(abs(claude.readings[1].usedPercent - 40) < 1e-9)

        let codex = try readings(listing(provider: "codex", file: "codex-x.json", quota: """
            { "observed_at": "2025-11-24T12:00:00Z", "signals": {
                "x-CODEX-primary-USED-percent": "60", "X-CODEX-PRIMARY-WINDOW-MINUTES": "300" } }
            """))
        #expect(codex.readings.map(\.window) == [.fiveHour])
        #expect(codex.readings.first?.usedPercent == 60)
    }

    @Test func missingOrZeroResetIsNil() throws {
        let claude = try readings(listing(quota: """
            { "observed_at": "2025-11-24T12:00:00Z", "signals": {
                "Anthropic-Ratelimit-Unified-5h-Utilization": "0.3",
                "Anthropic-Ratelimit-Unified-7d-Utilization": "0.3",
                "Anthropic-Ratelimit-Unified-7d-Reset": "0" } }
            """))
        #expect(claude.readings.count == 2)
        #expect(claude.readings.allSatisfy { $0.resetsAt == nil })

        let codex = try readings(listing(provider: "codex", file: "codex-x.json", quota: """
            { "observed_at": "2025-11-24T12:00:00Z", "signals": {
                "X-Codex-Primary-Used-Percent": "10", "X-Codex-Primary-Window-Minutes": "300",
                "X-Codex-Secondary-Used-Percent": "20", "X-Codex-Secondary-Window-Minutes": "10080",
                "X-Codex-Secondary-Reset-At": "0" } }
            """))
        #expect(codex.readings.count == 2)
        #expect(codex.readings.allSatisfy { $0.resetsAt == nil })
    }

    @Test func codexResetFromObservedAtPlusResetAfter() async throws {
        let snapshot = try await source(try fullTransport()).fetch(since: nil).get()
        let c = try #require(snapshot.readings.first { $0.fileKey == fileC })
        #expect(c.resetsAt == date("2025-11-24T13:00:00Z"), "observed_at 12:00 + 3600 s")

        // An unset Reset-At also falls back to Reset-After-Seconds.
        let list = try readings(listing(provider: "codex", file: "codex-x.json", quota: """
            { "observed_at": "2025-11-24T12:00:00Z", "signals": {
                "X-Codex-Primary-Used-Percent": "10", "X-Codex-Primary-Window-Minutes": "300",
                "X-Codex-Primary-Reset-At": "0", "X-Codex-Primary-Reset-After-Seconds": ["5400"] } }
            """))
        #expect(list.readings.first?.resetsAt == date("2025-11-24T13:30:00Z"))
    }

    @Test func noObservedAtGivesNoReading() throws {
        let list = try readings(listing(quota: """
            { "signals": { "Anthropic-Ratelimit-Unified-5h-Utilization": "0.3" } }
            """))
        #expect(list.readings.isEmpty)
        #expect(list.credentials.count == 1)
    }

    // MARK: - Routing

    @Test func zeroOrNegativeWeightIsOutOfRotationOnlyUnderWeightedRoundRobin() async throws {
        let wrr = try await source(try fullTransport()).fetch(since: nil).get()
        #expect(wrr.accounts.first { $0.fileKey == fileC }?.unavailable
            == [.upstreamUnavailable, .outOfRotation])
        #expect(wrr.accounts.first { $0.fileKey == fileF }?.unavailable == [.outOfRotation])
        #expect(wrr.accounts.first { $0.fileKey == fileD }?.unavailable == [])

        let transport = try fullTransport()
        transport.set(T6Paths.strategy, .ok(Data(#"{"strategy":"round-robin"}"#.utf8)))
        transport.set(T6Paths.config, .ok(Data(#"{"routing":{}}"#.utf8)))
        let rr = try await source(transport).fetch(since: nil).get()
        #expect(rr.routing == RoutingConfig(strategy: .roundRobin, sessionAffinity: false, forcedAccount: nil))
        #expect(rr.accounts.first { $0.fileKey == fileC }?.unavailable == [.upstreamUnavailable])
        #expect(rr.accounts.first { $0.fileKey == fileF }?.unavailable == [])
    }

    @Test func routingParsing() {
        #expect(CliproxyRoutingParser.strategy(Data(#"{"strategy":"fill-first"}"#.utf8)) == .fillFirst)
        #expect(CliproxyRoutingParser.strategy(Data(#""weighted-round-robin""#.utf8)) == .weightedRoundRobin)
        #expect(CliproxyRoutingParser.strategy(Data(#"{"strategy":"mystery"}"#.utf8)) == nil)
        #expect(CliproxyRoutingParser.sessionAffinity(Data(#"{"routing":{"session_affinity":{"enabled":true}}}"#.utf8)) == true)
        #expect(CliproxyRoutingParser.sessionAffinity(Data(#"{"port":8317}"#.utf8)) == false)
        #expect(CliproxyRoutingParser.sessionAffinity(Data("<html>".utf8)) == nil)
    }

    @Test func nonAuthRoutingFailureLeavesRoutingUnknown() async throws {
        let transport = try fullTransport()
        transport.set(T6Paths.strategy, .status(500))
        let snapshot = try await source(transport).fetch(since: nil).get()
        #expect(transport.paths == [T6Paths.credentials, T6Paths.strategy, T6Paths.config])
        #expect(snapshot.routing == nil)
        #expect(snapshot.readings.count == 5)
        #expect(snapshot.accounts.first { $0.fileKey == fileF }?.unavailable == [],
                "no strategy, so no outOfRotation")

        let noConfig = try fullTransport()
        noConfig.set(T6Paths.config, .fail(.timedOut))
        let s2 = try await source(noConfig).fetch(since: nil).get()
        #expect(s2.routing == nil)
        #expect(s2.accounts.first { $0.fileKey == fileF }?.unavailable == [.outOfRotation])
    }

    // MARK: - Errors and request discipline

    @Test(arguments: [
        (T6RoutedTransport.Reply.status(401, #"{"error":"invalid management key"}"#), SourceError.unauthorized),
        (.status(403, #"{"error":"remote management disabled"}"#), .remoteManagementDisabled),
        (.status(403, #"{"error":"IP BANNED due to too many failed attempts. Try again in 29m"}"#), .ipBanned),
        (.status(403), .unauthorized),
        (.status(403, "forbidden"), .unauthorized),
    ])
    func authErrorOnCredentialListIsOneRequest(reply: T6RoutedTransport.Reply, expected: SourceError) async throws {
        let transport = try fullTransport()
        transport.set(T6Paths.credentials, reply)
        #expect(await source(transport).fetch(since: nil).failureValue == expected)
        #expect(transport.paths == [T6Paths.credentials], "no routing or config call")
    }

    @Test func authErrorOnRoutingStopsBeforeConfig() async throws {
        let transport = try fullTransport()
        transport.set(T6Paths.strategy, .status(401))
        #expect(await source(transport).fetch(since: nil).failureValue == .unauthorized)
        #expect(transport.paths == [T6Paths.credentials, T6Paths.strategy])

        let t2 = try fullTransport()
        t2.set(T6Paths.config, .status(403, "remote management disabled"))
        #expect(await source(t2).fetch(since: nil).failureValue == .remoteManagementDisabled)
        #expect(t2.paths.count == 3)
    }

    @Test func unrecognizedForbiddenOnRoutingIsAnAuthStop() async throws {
        let transport = try fullTransport()
        transport.set(T6Paths.strategy, .status(403))
        #expect(await source(transport).fetch(since: nil).failureValue == .unauthorized)
        #expect(transport.paths == [T6Paths.credentials, T6Paths.strategy])
    }

    @Test func takenAtIsWhenTheCredentialListArrives() async throws {
        let start = date("2025-11-24T11:59:00Z")
        let clock = T6SteppingClock(start, stepBy: 60)
        let transport = T6RoutedTransport([
            T6Paths.credentials: .ok(try fixture("credentials.json")),
            T6Paths.strategy: .ok(try fixture("routing-strategy.json")),
            T6Paths.config: .ok(try fixture("config-routing.json")),
        ], clock: clock)
        let snapshot = try await CliproxySource(config: config, transport: transport, now: clock)
            .fetch(since: nil).get()
        #expect(snapshot.takenAt == date("2025-11-24T12:00:00Z"), "one step: the credential list")
        #expect(clock.now == date("2025-11-24T12:02:00Z"), "routing and config came later")
    }

    @Test func otherFailuresOnCredentialList() async throws {
        let t500 = T6RoutedTransport([T6Paths.credentials: .status(500)])
        #expect(await source(t500).fetch(since: nil).failureValue == .http(500))
        #expect(t500.paths.count == 1)

        let timeout = T6RoutedTransport([T6Paths.credentials: .fail(.timedOut)])
        #expect(await source(timeout).fetch(since: nil).failureValue == .timeout)

        let tls = T6RoutedTransport([T6Paths.credentials: .fail(.serverCertificateUntrusted)])
        #expect(await source(tls).fetch(since: nil).failureValue == .tlsUntrusted)

        let html = T6RoutedTransport([T6Paths.credentials: .ok(Data("<html></html>".utf8))])
        guard case .decoding = await source(html).fetch(since: nil).failureValue else {
            Issue.record("expected a decoding error")
            return
        }
        #expect(html.paths.count == 1)
    }

    @Test func testSendsExactlyOneRequest() async throws {
        let transport = try fullTransport()
        transport.set("/base" + T6Paths.credentials, .ok(try fixture("credentials.json")))
        let other = SourceConfig(url: URL(string: "https://other.test/base/management.html/")!,
                                 secret: "new-key")
        #expect(try await source(transport).test(other).get() == "cliproxy answered with 5 credential(s)")
        #expect(transport.requests.count == 1)
        let r = try #require(transport.requests.first)
        #expect(r.url?.absoluteString == "https://other.test/base/v8/management/credentials")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer new-key")

        let denied = T6RoutedTransport([T6Paths.credentials: .status(401)])
        #expect(await source(denied).test(config) == .failure(.unauthorized))
        #expect(denied.requests.count == 1)
    }

    @Test func noKeyMeansNoRequest() async {
        let transport = T6RoutedTransport()
        let s = source(transport, config: SourceConfig(url: URL(string: Self.base)!, secret: nil))
        #expect(await s.fetch(since: nil).failureValue == .unauthorized)
        #expect(await s.test(SourceConfig(url: URL(string: Self.base)!, secret: "")) == .failure(.unauthorized))
        #expect(transport.requests.isEmpty)
    }

    @Test func stripsManagementPage() {
        for raw in ["http://h:8317/management.html", "http://h:8317/management.html/",
                    "http://h:8317/", "http://h:8317"] {
            #expect(CliproxySource.baseURL(URL(string: raw)!).absoluteString == "http://h:8317")
        }
        #expect(CliproxySource.baseURL(URL(string: "https://h/proxy/management.html")!).absoluteString
            == "https://h/proxy")
    }

    @Test(arguments: ["http://h:8317/management.html#/", "http://h:8317/management.html?tab=1",
                      "http://h:8317/management.html/", "http://h:8317/Management.HTML#/config"])
    func stripsManagementPageWithFragmentQueryOrSlash(raw: String) {
        #expect(CliproxySource.baseURL(URL(string: raw)!).absoluteString == "http://h:8317")
    }

    // MARK: - Hostile or partial input

    /// One Claude credential with the given extra fields.
    func credential(_ fields: String) throws -> CliproxyCredential {
        let body = Data(#"[ { "id": "claude-1a2b3c4d-user-1@example.com.json", "provider": "claude", "#
            .utf8) + Data(fields.utf8) + Data(" } ]".utf8)
        return try #require(try readings(body).credentials.first)
    }

    @Test func counterNeedsBothFieldsValid() throws {
        #expect(try credential(#""success": 1497, "failed": 3"#).requestCounter == 1500)
        #expect(try credential(#""success": 1500"#).requestCounter == nil, "failed missing")
        #expect(try credential(#""failed": 3"#).requestCounter == nil, "success missing")
        #expect(try credential(#""success": 1500, "failed": null"#).requestCounter == nil)
        #expect(try credential(#""success": "abc", "failed": 3"#).requestCounter == nil)
        #expect(try credential(#""success": -1, "failed": 3"#).requestCounter == nil)
    }

    @Test func outOfRangeNumbersNeverTrap() throws {
        #expect(try credential(#""success": 9223372036854775807, "failed": 0"#).requestCounter == Int.max)
        #expect(try credential(#""success": 9223372036854775807, "failed": 1"#).requestCounter == nil,
                "sum overflows")
        #expect(try credential(#""success": 9223372036854775808, "failed": 0"#).requestCounter == nil,
                "above Int.max")
        let c = try credential(#""success": 1e300, "failed": 1, "priority": "9.3e18", "weight": 1e20"#)
        #expect(c.requestCounter == nil)
        #expect(c.routing == AccountRouting(priority: 0, weight: 1), "out of range takes the default")

        // 200000000000000000 fits in Int, but times 60 doesn't.
        for minutes in ["1e20", "200000000000000000", "nan", "-1e30"] {
            let list = try readings(listing(provider: "codex", file: "codex-x.json", quota: """
                { "observed_at": "2025-11-24T12:00:00Z", "signals": {
                    "X-Codex-Primary-Used-Percent": "40", "X-Codex-Primary-Window-Minutes": "\(minutes)" } }
                """))
            #expect(list.readings.isEmpty)
            #expect(list.unclassified.map(\.lengthSeconds) == [nil], "minutes \(minutes)")
        }
    }

    @Test func wholeNumbersOnlyNeverRounded() throws {
        #expect(try credential(#""success": 1.5, "failed": 3"#).requestCounter == nil)
        #expect(try credential(#""success": "1500.5", "failed": 3"#).requestCounter == nil)

        // A fractional weight isn't a weight: it takes the default 1, so it stays in
        // rotation instead of rounding to 0.
        let c = try credential(#""weight": 0.4, "priority": 1.5"#)
        #expect(c.routing == AccountRouting(priority: 0, weight: 1))
        let snapshot = CliproxySource.snapshot(CliproxyCredentialList(credentials: [c]),
                                               strategy: .weightedRoundRobin, sessionAffinity: false,
                                               takenAt: now.now)
        #expect(snapshot.accounts.first?.unavailable == [])

        let list = try readings(listing(provider: "codex", file: "codex-x.json", quota: """
            { "observed_at": "2025-11-24T12:00:00Z", "signals": {
                "X-Codex-Primary-Used-Percent": "40", "X-Codex-Primary-Window-Minutes": "300.4" } }
            """))
        #expect(list.readings.isEmpty, "300.4 minutes isn't the 5-hour window")
        #expect(list.unclassified.map(\.lengthSeconds) == [nil])
    }

    @Test func countersAbove2To53StayExact() throws {
        // 2^53 + 1 isn't a Double; a Double round-trip would read it as 2^53.
        let n = 9_007_199_254_740_993
        #expect(try credential(#""success": 9007199254740993, "failed": 0"#).requestCounter == n)
        #expect(try credential(#""success": "9007199254740993", "failed": "0""#).requestCounter == n)
        #expect(try credential(#""success": 9007199254740992, "failed": 1"#).requestCounter == n)
        #expect(try credential(#""success": 9007199254740992, "failed": 0"#).requestCounter == n - 1)
    }

    @Test func lookupFollowsCandidateOrder() throws {
        let json = try CliproxyJSON.parse(Data(#"{"Data": 2, "Files": 1, "ITEMS": 3}"#.utf8))
        #expect(json["files", "items", "data"]?.int == 1)
        #expect(json["data", "files"]?.int == 2)

        let list = try readings(Data("""
            { "Data": { "note": "not the list" },
              "Files": [ { "id": "\(fileA)", "provider": "claude" } ] }
            """.utf8))
        #expect(list.credentials.map(\.fileKey) == [fileA])
    }

    @Test func emptyStringsFallThrough() throws {
        let list = try readings(Data("""
            [ { "id": "", "name": "\(fileA)", "provider": "", "type": "claude" },
              { "id": "codex-x.json", "provider": "codex", "email": "",
                "id_token": { "chatgpt_account_id": "" }, "chatgpt_account_id": "acct-2" } ]
            """.utf8))
        #expect(list.credentials.map(\.fileKey) == [fileA, "codex-x.json"])
        #expect(list.credentials.map(\.id) == [AccountID(provider: .claude, identity: "1a2b3c4d"),
                                               AccountID(provider: .codex, identity: "acct-2")])
        #expect(list.credentials[1].email == nil)
    }
}
