import Foundation
import Testing
@testable import UsageCore

/// T6b: what the parsers read from the P0.3 captures in Fixtures/live/ (captured
/// 2026-11-23T03:16:02Z). Every expected value was read by hand from the fixture; the
/// comment beside it gives its JSON path. Skipped while the captures are missing.
@Suite("T6b live payload semantics")
struct T6bLiveSemanticsTests {
    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: Fixtures.url("live/\(name)").path)
    }
    static func data(_ name: String) throws -> Data { try Fixtures.data("live/\(name)") }
    static func missing(_ name: String) -> Comment {
        "No \(name) in Fixtures/live/ yet: P0.3 hasn't run scripts/capture-fixtures.sh"
    }

    /// capture-manifest.json `captured_at`.
    static let capturedAt = T6bTime.instant("2026-11-23T03:16:02Z")
    let sourceConfig = SourceConfig(url: URL(string: "http://cliproxy.test:8317")!, secret: "k")

    static let user4 = "claude-ea14e983-user-4@example.com.json"
    static let user1 = "claude-f5ae9dff-user-1@example.com.json"
    static let user5 = "claude-f5ae9dff-user-5@example.com.json"
    static let codex2 = "codex-85e5a20c-user-2@example.com-team.json"
    static let codex3 = "codex-85e5a20c-user-3@example.com-team.json"

    // MARK: - quota/history

    func history() throws -> ForkHistoryResponse {
        try CliproxyForkHistoryParser.parse(try Self.data("cliproxy-quota-history-24h.json")).get()
    }

    @Test(.enabled(if: exists("cliproxy-quota-history-24h.json"), missing("quota/history")))
    func forkProvidersAreServed() throws {
        // accounts[*].account.provider is "anthropic" or "codex"; statuses are "ok",
        // "removed" and "unsupported" (API keys), none "paused".
        #expect(try history().providers == [.claude: .served, .codex: .served])
    }

    @Test(.enabled(if: exists("cliproxy-quota-history-24h.json"), missing("quota/history")))
    func forkCurrentReadingsAreTheCapturedOnes() throws {
        let expected: [T6bExpected] = [
            // accounts[0]: reading.at 2026-11-23T03:12:14.440545117Z;
            // windows[0] short remaining 69, resetAt 2026-11-23T07:00:00.3971Z;
            // windows[1] weekly remaining 69, resetAt 2026-11-29T03:00:00.397118Z.
            .init(.claude, Self.user4, .fiveHour, used: 31, resets: "2026-11-23T07:00:00.3971Z",
                  observed: "2026-11-23T03:12:14.440545117Z"),
            .init(.claude, Self.user4, .weekly, used: 31, resets: "2026-11-29T03:00:00.397118Z",
                  observed: "2026-11-23T03:12:14.440545117Z"),
            // accounts[1]: reading.at 2026-11-23T03:12:11.488728362Z; short remaining 0,
            // resetAt 2026-11-23T04:20:00.439984Z; weekly remaining 83, resetAt
            // 2026-11-29T23:00:00.440001Z.
            .init(.claude, Self.user1, .fiveHour, used: 100, resets: "2026-11-23T04:20:00.439984Z",
                  observed: "2026-11-23T03:12:11.488728362Z"),
            .init(.claude, Self.user1, .weekly, used: 17, resets: "2026-11-29T23:00:00.440001Z",
                  observed: "2026-11-23T03:12:11.488728362Z"),
            // accounts[2]: reading.at 2026-11-23T03:12:11.509570254Z; short remaining 0,
            // resetAt 2026-11-23T03:20:00.464851Z; weekly remaining 64, resetAt
            // 2026-11-26T07:00:00.464872Z.
            .init(.claude, Self.user5, .fiveHour, used: 100, resets: "2026-11-23T03:20:00.464851Z",
                  observed: "2026-11-23T03:12:11.509570254Z"),
            .init(.claude, Self.user5, .weekly, used: 36, resets: "2026-11-26T07:00:00.464872Z",
                  observed: "2026-11-23T03:12:11.509570254Z"),
            // accounts[3...5]: claude:apikey:* with status "removed" / "unsupported" and
            // no reading: nothing.
            // accounts[6]: reading.at 2026-11-23T03:15:11.908671748Z; short remaining 94,
            // resetAt 2026-11-23T08:04:31Z; weekly remaining 57, resetAt 2026-11-24T02:11:16Z.
            .init(.codex, Self.codex2, .fiveHour, used: 6, resets: "2026-11-23T08:04:31Z",
                  observed: "2026-11-23T03:15:11.908671748Z"),
            .init(.codex, Self.codex2, .weekly, used: 43, resets: "2026-11-24T02:11:16Z",
                  observed: "2026-11-23T03:15:11.908671748Z"),
            // accounts[7]: reading.at 2026-11-23T03:13:03.678681438Z; short remaining 26,
            // resetAt 2026-11-23T03:22:46Z; weekly remaining 76, resetAt 2026-11-27T11:58:55Z.
            .init(.codex, Self.codex3, .fiveHour, used: 74, resets: "2026-11-23T03:22:46Z",
                  observed: "2026-11-23T03:13:03.678681438Z"),
            .init(.codex, Self.codex3, .weekly, used: 24, resets: "2026-11-27T11:58:55Z",
                  observed: "2026-11-23T03:13:03.678681438Z"),
        ]
        let current = try history().current
        T6bExpected.match(current, expected, source: .forkPoller)
    }

    @Test(.enabled(if: exists("cliproxy-quota-history-24h.json"), missing("quota/history")))
    func forkHistorySpotChecks() throws {
        let history = try history().history
        func at(_ file: String, _ w: WindowKind, _ observed: String) -> [SourceReading] {
            let t = T6bTime.instant(observed)
            return history.filter { $0.fileKey == file && $0.window == w && T6bTime.close($0.observedAt, t) }
        }

        // pools[1] (anthropic weekly) history[0].accounts[1]: remaining 0, observedAt
        // 2026-11-22T03:12:24.472025262Z, resetAt 2026-11-22T23:00:00.425573Z.
        T6bExpected.match(at(Self.user1, .weekly, "2026-11-22T03:12:24.472025262Z"), [
            .init(.claude, Self.user1, .weekly, used: 100, resets: "2026-11-22T23:00:00.425573Z",
                  observed: "2026-11-22T03:12:24.472025262Z"),
        ], source: .forkPoller)
        // pools[0] (anthropic short) history[0].accounts[1]: remaining 100, resetAt
        // 0001-01-01T00:00:00Z (unset).
        T6bExpected.match(at(Self.user1, .fiveHour, "2026-11-22T03:12:24.472025262Z"), [
            .init(.claude, Self.user1, .fiveHour, used: 0, resets: nil,
                  observed: "2026-11-22T03:12:24.472025262Z"),
        ], source: .forkPoller)
        // pools[2] (codex short) and pools[3] (codex weekly) history[0].accounts[0]:
        // the same observation (2026-11-22T03:15:18.689737561Z) in both pools, remaining
        // 100 resetAt 2026-11-22T08:15:18Z, and remaining 58 resetAt 2026-11-24T02:11:16Z.
        T6bExpected.match(at(Self.codex2, .fiveHour, "2026-11-22T03:15:18.689737561Z"), [
            .init(.codex, Self.codex2, .fiveHour, used: 0, resets: "2026-11-22T08:15:18Z",
                  observed: "2026-11-22T03:15:18.689737561Z"),
        ], source: .forkPoller)
        T6bExpected.match(at(Self.codex2, .weekly, "2026-11-22T03:15:18.689737561Z"), [
            .init(.codex, Self.codex2, .weekly, used: 42, resets: "2026-11-24T02:11:16Z",
                  observed: "2026-11-22T03:15:18.689737561Z"),
        ], source: .forkPoller)
        // pools[0].history[51] has user-5's 07:18:12 observation as "ok" (remaining 96,
        // resetAt 2026-11-22T07:20:00.441474Z); history[52] carries it forward as
        // "stale_or_unsupported". The ok copy stays, once.
        T6bExpected.match(at(Self.user5, .fiveHour, "2026-11-22T07:18:12.491398728Z"), [
            .init(.claude, Self.user5, .fiveHour, used: 4, resets: "2026-11-22T07:20:00.441474Z",
                  observed: "2026-11-22T07:18:12.491398728Z"),
        ], source: .forkPoller)
        // pools[2].history[457] and [458].accounts[1]: codex user-3 at
        // 2026-11-22T22:17:04.837838289Z only as "stale_or_unsupported": no reading.
        #expect(at(Self.codex3, .fiveHour, "2026-11-22T22:17:04.837838289Z").isEmpty)
        // pools[0].history[*].accounts[3]: claude:apikey:* entries are "unsupported" or
        // "added" with remaining null: never a reading.
        #expect(!history.contains { $0.fileKey.hasPrefix("claude:apikey:") })
    }

    // MARK: - Credential list, routing and config

    func cliproxySnapshot() async throws -> SourceSnapshot {
        let transport = T6RoutedTransport([
            T6Paths.credentials: .ok(try Self.data("cliproxy-credentials.json")),
            T6Paths.strategy: .ok(try Self.data("cliproxy-routing-strategy.json")),
            T6Paths.config: .ok(try Self.data("cliproxy-config-routing.json")),
        ])
        let source = CliproxySource(config: sourceConfig, transport: transport,
                                    now: FixedNowProvider(Self.capturedAt))
        return try await source.fetch(since: nil).get()
    }

    static var cliproxyCaptured: Bool {
        exists("cliproxy-credentials.json") && exists("cliproxy-routing-strategy.json")
            && exists("cliproxy-config-routing.json")
    }

    @Test(.enabled(if: cliproxyCaptured, missing("cliproxy capture")))
    func credentialAccountsAsCaptured() async throws {
        let snapshot = try await cliproxySnapshot()
        // files[0] is provider "antigravity": skipped. files[1...5] in order.
        #expect(snapshot.accounts.map(\.fileKey) == [Self.user4, Self.user1, Self.user5,
                                                     Self.codex2, Self.codex3])
        // files[*].email; files[*].disabled is false everywhere.
        #expect(snapshot.accounts.map(\.email) == ["user-4@example.com", "user-1@example.com",
                                                   "user-5@example.com", "user-2@example.com",
                                                   "user-3@example.com"])
        #expect(snapshot.accounts.allSatisfy { $0.enabled })
        // files[*].success + failed: 5712+34, 7453+47, 5664+29, 450+2, 787+11.
        #expect(snapshot.accounts.map(\.requestCounter) == [5746, 7500, 5693, 452, 798])
        // files[*].priority: 10, 0, -10, 10, 0. files[1].weight is 1; the others have
        // no weight (default 1).
        #expect(snapshot.accounts.map(\.routing) == [
            AccountRouting(priority: 10, weight: 1), AccountRouting(priority: 0, weight: 1),
            AccountRouting(priority: -10, weight: 1), AccountRouting(priority: 10, weight: 1),
            AccountRouting(priority: 0, weight: 1),
        ])
        #expect(snapshot.accounts.allSatisfy { $0.polledAt == nil && $0.pollError == nil })
    }

    /// T4b: identity is the seat (plan.md "Identity", "P0.4 as captured"). The two
    /// f5ae9dff files and the two Codex files sharing one chatgpt_account_id each give
    /// two accounts: five seats from five files.
    @Test(.enabled(if: cliproxyCaptured, missing("cliproxy capture")))
    func capturedPairsAreSeparateSeats() async throws {
        let snapshot = try await cliproxySnapshot()
        // File-name hash plus files[*].email; files[4,5].id_token.chatgpt_account_id
        // plus files[4,5].email.
        #expect(snapshot.accounts.map(\.id) == [
            AccountID(provider: .claude, identity: "ea14e983:user-4@example.com"),
            AccountID(provider: .claude, identity: "f5ae9dff:user-1@example.com"),
            AccountID(provider: .claude, identity: "f5ae9dff:user-5@example.com"),
            AccountID(provider: .codex, identity: "00000000-0000-4000-8000-000000000001:user-2@example.com"),
            AccountID(provider: .codex, identity: "00000000-0000-4000-8000-000000000001:user-3@example.com"),
        ])
    }

    @Test(.enabled(if: cliproxyCaptured, missing("cliproxy capture")))
    func quotaBlockedCredentialsCoolDownUntilTheirRetry() async throws {
        let snapshot = try await cliproxySnapshot()
        func until(_ file: String) -> [Date?] {
            (snapshot.accounts.first { $0.fileKey == file }?.unavailable ?? []).map {
                if case .coolingDown(let until) = $0 { return until }
                return nil
            }
        }
        // files[2] (user-1): unavailable true, next_retry_after and
        // cooldowns[0] (scope "credential").retry_at 2026-11-23T04:20:12.000362001Z.
        let u1 = until(Self.user1)
        #expect(u1.count == 1)
        #expect(u1.first.flatMap { $0 }.map {
            T6bTime.close($0, T6bTime.instant("2026-11-23T04:20:12.000362001Z"))
        } == true)
        // files[3] (user-5): unavailable true, next_retry_after
        // 2026-11-23T03:20:07.000421349Z, after the 03:16:02 capture.
        let u5 = until(Self.user5)
        #expect(u5.count == 1)
        #expect(u5.first.flatMap { $0 }.map {
            T6bTime.close($0, T6bTime.instant("2026-11-23T03:20:07.000421349Z"))
        } == true)
        // files[1], [4], [5]: unavailable false, cooldowns [], weights > 0.
        for file in [Self.user4, Self.codex2, Self.codex3] {
            #expect(snapshot.accounts.first { $0.fileKey == file }?.unavailable == [], "\(file)")
        }
    }

    @Test(.enabled(if: cliproxyCaptured, missing("cliproxy capture")))
    func passiveSignalsAsCaptured() async throws {
        let snapshot = try await cliproxySnapshot()
        let expected: [T6bExpected] = [
            // files[1].quota: observed_at 2026-11-23T03:16:02.118971182Z;
            // Anthropic-Ratelimit-Unified-5h-Utilization "0.31", -5h-Reset "1795417200"
            // (2026-11-23T07:00:00Z); -7d-Utilization "0.3", -7d-Reset "1795921200"
            // (2026-11-29T03:00:00Z).
            .init(.claude, Self.user4, .fiveHour, used: 31, resets: "2026-11-23T07:00:00Z",
                  observed: "2026-11-23T03:16:02.118971182Z"),
            .init(.claude, Self.user4, .weekly, used: 30, resets: "2026-11-29T03:00:00Z",
                  observed: "2026-11-23T03:16:02.118971182Z"),
            // files[2].quota: observed_at 2026-11-23T01:18:13.357964805Z; 5h "1.0",
            // reset 1795407600 (2026-11-23T04:20:00Z); 7d "0.17", reset 1795993200
            // (2026-11-29T23:00:00Z).
            .init(.claude, Self.user1, .fiveHour, used: 100, resets: "2026-11-23T04:20:00Z",
                  observed: "2026-11-23T01:18:13.357964805Z"),
            .init(.claude, Self.user1, .weekly, used: 17, resets: "2026-11-29T23:00:00Z",
                  observed: "2026-11-23T01:18:13.357964805Z"),
            // files[3].quota: observed_at 2026-11-22T23:28:07.480692594Z; 5h "1.0",
            // reset 1795404000 (2026-11-23T03:20:00Z); 7d "0.35", reset 1795676400
            // (2026-11-26T07:00:00Z).
            .init(.claude, Self.user5, .fiveHour, used: 100, resets: "2026-11-23T03:20:00Z",
                  observed: "2026-11-22T23:28:07.480692594Z"),
            .init(.claude, Self.user5, .weekly, used: 35, resets: "2026-11-26T07:00:00Z",
                  observed: "2026-11-22T23:28:07.480692594Z"),
            // files[4].quota: observed_at 2026-11-23T03:12:44.017163797Z;
            // X-Codex-Primary-Used-Percent "4", -Window-Minutes "300", -Reset-At
            // "1795421071" (2026-11-23T08:04:31Z); Secondary "43", "10080",
            // "1795486276" (2026-11-24T02:11:16Z).
            .init(.codex, Self.codex2, .fiveHour, used: 4, resets: "2026-11-23T08:04:31Z",
                  observed: "2026-11-23T03:12:44.017163797Z"),
            .init(.codex, Self.codex2, .weekly, used: 43, resets: "2026-11-24T02:11:16Z",
                  observed: "2026-11-23T03:12:44.017163797Z"),
            // files[5].quota: observed_at 2026-11-23T01:54:09.301827088Z; Primary "74",
            // "300", "1795404166" (2026-11-23T03:22:46Z); Secondary "24", "10080",
            // "1795780735" (2026-11-27T11:58:55Z).
            .init(.codex, Self.codex3, .fiveHour, used: 74, resets: "2026-11-23T03:22:46Z",
                  observed: "2026-11-23T01:54:09.301827088Z"),
            .init(.codex, Self.codex3, .weekly, used: 24, resets: "2026-11-27T11:58:55Z",
                  observed: "2026-11-23T01:54:09.301827088Z"),
        ]
        T6bExpected.match(snapshot.readings, expected, source: .passive)
        #expect(snapshot.unclassified.isEmpty, "every Codex window is 300 or 10080 minutes")
    }

    @Test(.enabled(if: cliproxyCaptured, missing("cliproxy capture")))
    func routingAsCaptured() async throws {
        // cliproxy-routing-strategy.json strategy "weighted-round-robin";
        // cliproxy-config-routing.json routing.session-affinity true (ttl "4h" isn't
        // read: nothing in RoutingConfig holds it).
        #expect(try await cliproxySnapshot().routing
            == RoutingConfig(strategy: .weightedRoundRobin, sessionAffinity: true, forcedAccount: nil))
    }

    // MARK: - ocgo

    @Test(.enabled(if: exists("ocgo-status.json"), missing("ocgo-status.json")))
    func ocgoStatusAsCaptured() throws {
        let s = try OcgoStatusParser.snapshot(from: try Self.data("ocgo-status.json"),
                                              takenAt: Self.capturedAt).get()
        // accounts[*].name; no forced_account key anywhere in the body.
        #expect(s.accounts.map(\.fileKey) == ["team-a", "team-b", "extra"])
        #expect(s.routing == RoutingConfig(strategy: .mostHeadroom, sessionAffinity: false,
                                           forcedAccount: nil))
        // accounts[0]: available false, exhausted true, exhausted_until
        // 2026-11-30T21:54:01Z. accounts[1], [2]: available true.
        #expect(s.accounts.map(\.unavailable) == [
            [.exhausted(until: T6bTime.instant("2026-11-30T21:54:01Z"))], [], [],
        ])
        #expect(s.accounts.allSatisfy { $0.pollError == nil && $0.enabled })

        let expected: [T6bExpected] = [
            // accounts[0] polled_at 2026-11-23T03:14:11.573035212Z. windows.rolling ok 0
            // 2026-11-23T08:14:11.53Z; weekly ok 0 2026-11-30T00:00:00Z; monthly
            // "rate-limited" 100 2026-11-30T21:54:01Z.
            .init(.go, "team-a", .fiveHour, used: 0, resets: "2026-11-23T08:14:11.53Z",
                  observed: "2026-11-23T03:14:11.573035212Z"),
            .init(.go, "team-a", .weekly, used: 0, resets: "2026-11-30T00:00:00Z",
                  observed: "2026-11-23T03:14:11.573035212Z"),
            .init(.go, "team-a", .monthly, used: 100, resets: "2026-11-30T21:54:01Z",
                  observed: "2026-11-23T03:14:11.573035212Z"),
            // accounts[1] polled_at 2026-11-23T03:14:11.542943569Z. rolling 0
            // 2026-11-23T08:14:11.513Z; weekly 0 2026-11-30T00:00:00Z; monthly 67
            // 2026-11-28T22:29:26Z.
            .init(.go, "team-b", .fiveHour, used: 0, resets: "2026-11-23T08:14:11.513Z",
                  observed: "2026-11-23T03:14:11.542943569Z"),
            .init(.go, "team-b", .weekly, used: 0, resets: "2026-11-30T00:00:00Z",
                  observed: "2026-11-23T03:14:11.542943569Z"),
            .init(.go, "team-b", .monthly, used: 67, resets: "2026-11-28T22:29:26Z",
                  observed: "2026-11-23T03:14:11.542943569Z"),
            // accounts[2] polled_at 2026-11-23T03:14:11.548307801Z. rolling 2
            // 2026-11-23T05:36:42Z; weekly 0 2026-11-30T00:00:00Z; monthly 11
            // 2026-11-30T21:54:01Z.
            .init(.go, "extra", .fiveHour, used: 2, resets: "2026-11-23T05:36:42Z",
                  observed: "2026-11-23T03:14:11.548307801Z"),
            .init(.go, "extra", .weekly, used: 0, resets: "2026-11-30T00:00:00Z",
                  observed: "2026-11-23T03:14:11.548307801Z"),
            .init(.go, "extra", .monthly, used: 11, resets: "2026-11-30T21:54:01Z",
                  observed: "2026-11-23T03:14:11.548307801Z"),
        ]
        T6bExpected.match(s.readings, expected, source: .ocgo)
        // polledAt is the reading time above.
        #expect(T6bTime.close(s.accounts[0].polledAt ?? .distantPast,
                              T6bTime.instant("2026-11-23T03:14:11.573035212Z")))
    }
}

// MARK: - Live shapes, small synthetic cases

@Suite("T6b live shapes")
struct T6bLiveShapeTests {
    func parse(_ json: String) throws -> ForkHistoryResponse {
        try CliproxyForkHistoryParser.parse(Data(json.utf8)).get()
    }

    static let oauth = "claude-1a2b3c4d-user-1@example.com.json"

    @Test func apiKeyCredentialsDontKeepAPausedProviderServed() throws {
        // The live API-key entries ("unsupported", "removed") have no reading; only
        // the OAuth accounts decide whether the poller is paused.
        let r = try parse("""
            { "accounts": [
              { "account": { "id": "\(Self.oauth)", "provider": "anthropic", "enabled": true },
                "status": "paused" },
              { "account": { "id": "claude:apikey:aaaaaaaaaaaa", "provider": "anthropic",
                             "enabled": true }, "status": "unsupported", "error": "unsupported" },
              { "account": { "id": "claude:apikey:bbbbbbbbbbbb", "provider": "anthropic",
                             "enabled": false }, "status": "removed" } ] }
            """)
        #expect(r.providers == [.claude: .paused])
    }

    @Test func providerWithOnlyAPIKeyCredentialsIsLeftOut() throws {
        let r = try parse("""
            { "accounts": [
              { "account": { "id": "claude:apikey:aaaaaaaaaaaa", "provider": "anthropic" },
                "status": "unsupported" },
              { "account": { "id": "codex-user-3@example.com-plus.json", "provider": "codex" },
                "status": "ok" } ] }
            """)
        #expect(r.providers == [.codex: .served])
    }

    @Test func liveReadingNeedsAnOkStatusAndTakesItsTimeFromAt() throws {
        let r = try parse("""
            { "accounts": [
              { "account": { "id": "\(Self.oauth)", "provider": "anthropic" }, "status": "ok",
                "reading": { "at": "2026-11-23T03:12:14.5Z", "status": "ok", "windows": [
                  { "id": "short", "durationSeconds": 18000, "remaining": 69,
                    "resetAt": "0001-01-01T00:00:00Z", "resetKind": "rolling" },
                  { "id": "other", "durationSeconds": 604800, "remaining": 40,
                    "resetAt": "2026-11-29T03:00:00Z" },
                  { "id": "other", "durationSeconds": 60, "remaining": 1 } ] } },
              { "account": { "id": "claude-9f8e7d6c-user-6@example.com.json",
                             "provider": "anthropic" }, "status": "ok",
                "reading": { "at": "2026-11-23T03:12:00Z", "status": "error", "windows": [
                  { "id": "short", "remaining": 10 } ] } } ] }
            """)
        // An unknown window id falls back to its length; one of neither kind is dropped.
        T6bExpected.match(r.current, [
            .init(.claude, Self.oauth, .fiveHour, used: 31, resets: nil, observed: "2026-11-23T03:12:14.5Z"),
            .init(.claude, Self.oauth, .weekly, used: 60, resets: "2026-11-29T03:00:00Z",
                  observed: "2026-11-23T03:12:14.5Z"),
        ], source: .forkPoller)
    }

    // MARK: cliproxy cooldowns

    func snapshot(_ entry: String, at now: String) throws -> AccountSnapshot {
        let body = Data("""
            { "files": [ { "id": "\(Self.oauth)", "provider": "claude", \(entry) } ] }
            """.utf8)
        let list = try CliproxyCredentialsParser.parse(body).get()
        let s = CliproxySource.snapshot(list, strategy: .weightedRoundRobin, sessionAffinity: true,
                                        takenAt: T6bTime.instant(now))
        return try #require(s.accounts.first)
    }

    @Test func unavailableWithAFutureRetryIsCoolingDown() throws {
        let retry = T6bTime.instant("2026-11-23T04:20:12Z")
        #expect(try snapshot(#""unavailable": true, "next_retry_after": "2026-11-23T04:20:12Z""#,
                             at: "2026-11-23T03:16:02Z").unavailable == [.coolingDown(until: retry)])
        // Without next_retry_after, the credential-scope cooldown says it.
        #expect(try snapshot("""
            "unavailable": true, "cooldowns": [
              { "scope": "model", "model_key": "m", "retry_at": "2026-11-23T05:00:00Z" },
              { "scope": "credential", "retry_at": "2026-11-23T04:20:12Z" } ]
            """, at: "2026-11-23T03:16:02Z").unavailable == [.coolingDown(until: retry)])
    }

    /// next_retry_after has passed (11:55) but the credential-scope cooldown retries at
    /// 12:30, after the 12:00 listing: the later of the two is the retry.
    @Test func aPastNextRetryDoesntHideALaterCredentialCooldown() throws {
        #expect(try snapshot("""
            "unavailable": true, "next_retry_after": "2026-11-23T11:55:00Z", "cooldowns": [
              { "scope": "credential", "retry_at": "2026-11-23T12:30:00Z" } ]
            """, at: "2026-11-23T12:00:00Z").unavailable
            == [.coolingDown(until: T6bTime.instant("2026-11-23T12:30:00Z"))])
    }

    @Test func unavailableWithNoFutureRetryHasNoKnownEnd() throws {
        #expect(try snapshot(#""unavailable": true, "next_retry_after": "2026-11-23T03:00:00Z""#,
                             at: "2026-11-23T03:16:02Z").unavailable == [.upstreamUnavailable])
        #expect(try snapshot(#""unavailable": true, "next_retry_after": "0001-01-01T00:00:00Z""#,
                             at: "2026-11-23T03:16:02Z").unavailable == [.upstreamUnavailable])
        #expect(try snapshot("""
            "unavailable": true, "cooldowns": [
              { "scope": "model", "model_key": "m", "retry_at": "2026-11-23T05:00:00Z" } ]
            """, at: "2026-11-23T03:16:02Z").unavailable == [.upstreamUnavailable])
    }

    @Test func aRetryTimeAloneDoesntMakeACredentialUnavailable() throws {
        #expect(try snapshot(#""unavailable": false, "next_retry_after": "2026-11-23T04:20:12Z""#,
                             at: "2026-11-23T03:16:02Z").unavailable == [])
    }

    // MARK: ocgo "rate-limited"

    @Test func ocgoRateLimitedWindowIsAReadingButNeedsAPercent() throws {
        let body = Data("""
            { "time": "2026-11-23T03:16:02Z", "accounts": [ {
                "name": "team-a", "available": false, "exhausted": true,
                "exhausted_until": "2026-11-30T21:54:01Z", "polled_at": "2026-11-23T03:14:11Z",
                "windows": {
                  "monthly": { "status": "rate-limited", "percent": 100, "resets_at": "2026-11-30T21:54:01Z" },
                  "weekly": { "status": "rate-limited", "resets_at": "2026-11-30T00:00:00Z" },
                  "rolling": { "status": "error", "percent": 0, "resets_at": "2026-11-23T08:14:11Z" } } } ] }
            """.utf8)
        let s = try OcgoStatusParser.snapshot(from: body, takenAt: T6bTime.instant("2026-11-23T03:16:02Z")).get()
        #expect(s.readings == [
            SourceReading(provider: .go, fileKey: "team-a", window: .monthly, usedPercent: 100,
                          resetsAt: T6bTime.instant("2026-11-30T21:54:01Z"),
                          observedAt: T6bTime.instant("2026-11-23T03:14:11Z"), source: .ocgo),
        ])
    }
}

// MARK: - Helpers, written apart from the parsers

/// One expected reading with times as RFC 3339 text.
struct T6bExpected {
    let provider: Provider
    let fileKey: String
    let window: WindowKind
    let used: Double
    let resets: String?
    let observed: String

    init(_ provider: Provider, _ fileKey: String, _ window: WindowKind, used: Double,
         resets: String?, observed: String) {
        self.provider = provider
        self.fileKey = fileKey
        self.window = window
        self.used = used
        self.resets = resets
        self.observed = observed
    }

    /// Same multiset of readings, matched by (provider, file, window), times within 1 µs
    /// and percents within 1e-9.
    static func match(_ actual: [SourceReading], _ expected: [T6bExpected], source: ReadingSource,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, "reading count", sourceLocation: sourceLocation)
        for e in expected {
            let found = actual.filter {
                $0.provider == e.provider && $0.fileKey == e.fileKey && $0.window == e.window
            }
            guard found.count == 1, let r = found.first else {
                Issue.record("\(e.fileKey) \(e.window): \(found.count) readings", sourceLocation: sourceLocation)
                continue
            }
            let label = "\(e.fileKey) \(e.window)"
            #expect(abs(r.usedPercent - e.used) < 1e-9, "\(label) used \(r.usedPercent)",
                    sourceLocation: sourceLocation)
            #expect(T6bTime.close(r.observedAt, T6bTime.instant(e.observed)), "\(label) observedAt",
                    sourceLocation: sourceLocation)
            switch (r.resetsAt, e.resets) {
            case (nil, nil): break
            case (let a?, let b?):
                #expect(T6bTime.close(a, T6bTime.instant(b)), "\(label) resetsAt \(a)",
                        sourceLocation: sourceLocation)
            default:
                Issue.record("\(label) resetsAt \(String(describing: r.resetsAt)), expected \(String(describing: e.resets))",
                             sourceLocation: sourceLocation)
            }
            #expect(r.source == source, "\(label) source", sourceLocation: sourceLocation)
        }
    }
}

enum T6bTime {
    /// RFC 3339 with up to nanosecond fractions: whole seconds through
    /// ISO8601DateFormatter, the fraction digits added from their decimal text.
    static func instant(_ s: String) -> Date {
        var text = s
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            let digits = s[s.index(after: dot)...].prefix { $0.isNumber }
            fraction = NSDecimalNumber(string: "0." + digits).doubleValue
            text = String(s[..<dot]) + String(s[s.index(dot, offsetBy: 1 + digits.count)...])
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)!.addingTimeInterval(fraction)
    }

    static func close(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 1e-6
    }
}
