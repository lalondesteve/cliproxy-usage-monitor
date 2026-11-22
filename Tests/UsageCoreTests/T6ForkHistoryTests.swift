import Foundation
import Testing
@testable import UsageCore

@Suite("T6 fork quota/history")
struct T6ForkHistoryTests {
    let config = SourceConfig(url: URL(string: "http://cliproxy.test:8317/management.html")!,
                              secret: "mgmt-key")
    let fileA = "claude-1a2b3c4d-user-1@example.com.json"
    let fileC = "codex-user-3@example.com-plus.json"

    func history(_ fixture: String, range: TimeInterval = 24 * 3600) async throws
        -> (Result<ForkHistoryResponse, SourceError>, T6RoutedTransport) {
        let transport = T6RoutedTransport([
            T6Paths.history: .ok(try Fixtures.data("synthetic/T6/\(fixture)")),
        ])
        let source = CliproxyForkHistorySource(config: config, transport: transport)
        return (await source.fetch(range: range), transport)
    }

    func reading(_ p: Provider, _ file: String, _ w: WindowKind, used: Double, resets: String?,
                 observed: String) -> SourceReading {
        SourceReading(provider: p, fileKey: file, window: w, usedPercent: used,
                      resetsAt: resets.map(date), observedAt: date(observed), source: .forkPoller)
    }

    @Test func parsesCurrentAndHistoryForAllProviders() async throws {
        let (result, transport) = try await history("quota-history.json")
        let response = try result.get()

        #expect(transport.requests.count == 1)
        let r = try #require(transport.requests.first)
        #expect(r.url?.absoluteString == "http://cliproxy.test:8317/v8/management/quota/history?range=24h")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer mgmt-key")

        // "anthropic" is read as Claude; a stale account doesn't pause its provider.
        #expect(response.providers == [.claude: .served, .codex: .served])

        // Values are remaining %, stored as used %. E15: Go zero time is unset.
        #expect(Set(response.current) == [
            reading(.claude, fileA, .fiveHour, used: 30, resets: "2026-11-22T14:10:00Z",
                    observed: "2026-11-22T11:55:00Z"),
            reading(.claude, fileA, .weekly, used: 58.5, resets: nil, observed: "2026-11-22T11:55:00Z"),
            reading(.codex, fileC, .fiveHour, used: 0, resets: nil, observed: "2026-11-22T11:50:00Z"),
            reading(.codex, fileC, .weekly, used: 37, resets: "2026-11-25T09:00:00Z",
                    observed: "2026-11-22T11:50:00Z"),
        ])

        // Carried-forward knots are deduplicated; only "ok" entries with a remaining.
        #expect(response.history == [
            reading(.codex, fileC, .weekly, used: 36, resets: "2026-11-25T09:00:00Z",
                    observed: "2026-11-22T10:50:00Z"),
            reading(.claude, fileA, .fiveHour, used: 20, resets: "2026-11-22T14:10:00Z",
                    observed: "2026-11-22T10:55:00Z"),
            reading(.claude, fileA, .weekly, used: 55, resets: nil, observed: "2026-11-22T10:55:00Z"),
            reading(.claude, fileA, .fiveHour, used: 25, resets: "2026-11-22T14:10:00Z",
                    observed: "2026-11-22T11:00:00Z"),
            reading(.claude, fileA, .weekly, used: 56, resets: "2026-11-27T08:00:00Z",
                    observed: "2026-11-22T11:00:00Z"),
        ])
    }

    @Test("E15: fork poller reset 0001-01-01T00:00:00Z is unset")
    func e15GoZeroTime() async throws {
        let response = try await history("quota-history.json").0.get()
        let weekly = try #require(response.current.first { $0.fileKey == fileA && $0.window == .weekly })
        #expect(weekly.resetsAt == nil)
        let codex5h = try #require(response.current.first { $0.fileKey == fileC && $0.window == .fiveHour })
        #expect(codex5h.resetsAt == nil)
    }

    @Test func pausedCodexAccountsGivePausedProvider() async throws {
        let response = try await history("quota-history-codex-paused.json").0.get()
        #expect(response.providers[.codex] == .paused)
        #expect(response.providers[.claude] == .served)
        #expect(response.current.allSatisfy { $0.provider == .claude })
        #expect(response.history.allSatisfy { $0.provider == .claude })
        #expect(response.history == [
            reading(.claude, fileA, .fiveHour, used: 20, resets: "2026-11-22T14:10:00Z",
                    observed: "2026-11-22T10:55:00Z"),
        ])
    }

    @Test func activeProviderWithNoSamplesIsServedWithNoHistory() async throws {
        let response = try await history("quota-history-no-samples.json").0.get()
        #expect(response.providers == [.claude: .served])
        #expect(response.history.isEmpty)
        #expect(response.current.isEmpty)
    }

    @Test func missingRouteIsHTTP404() async {
        let transport = T6RoutedTransport()
        let source = CliproxyForkHistorySource(config: config, transport: transport)
        #expect(await source.fetch(range: 3600).failureValue == .http(404))
        #expect(transport.requests.count == 1)
    }

    @Test func authErrorsMap() async {
        let t401 = T6RoutedTransport([T6Paths.history: .status(401)])
        #expect(await CliproxyForkHistorySource(config: config, transport: t401)
            .fetch(range: 3600).failureValue == .unauthorized)
        let t403 = T6RoutedTransport([T6Paths.history: .status(403, "IP banned")])
        #expect(await CliproxyForkHistorySource(config: config, transport: t403)
            .fetch(range: 3600).failureValue == .ipBanned)
        let empty403 = T6RoutedTransport([T6Paths.history: .status(403)])
        #expect(await CliproxyForkHistorySource(config: config, transport: empty403)
            .fetch(range: 3600).failureValue == .unauthorized)
        #expect(empty403.requests.count == 1)
    }

    func parse(_ json: String) throws -> ForkHistoryResponse {
        try CliproxyForkHistoryParser.parse(Data(json.utf8)).get()
    }

    @Test func invalidEntryDoesNotHideALaterValidOne() throws {
        let response = try parse("""
            { "accounts": [ { "id": "\(fileA)", "provider": "anthropic", "status": "ok" } ],
              "pools": [ { "provider": "anthropic", "window": "short", "history": [
                { "accounts": [ { "id": "\(fileA)", "status": "ok", "remaining": null,
                                  "observedAt": "2026-11-22T10:55:00Z" } ] },
                { "accounts": [ { "id": "\(fileA)", "status": "ok", "remaining": 80,
                                  "observedAt": "2026-11-22T10:55:00Z" } ] } ] } ] }
            """)
        #expect(response.history == [
            reading(.claude, fileA, .fiveHour, used: 20, resets: nil, observed: "2026-11-22T10:55:00Z"),
        ])
    }

    @Test func unsetWindowTimeFallsBackToTheReadingTime() throws {
        let response = try parse("""
            { "accounts": [ { "id": "\(fileA)", "provider": "anthropic", "status": "ok",
                "observedAt": "2026-11-22T11:00:00Z",
                "reading": { "observedAt": "0001-01-01T00:00:00Z", "windows": {
                  "short": { "remaining": 70, "observedAt": "" },
                  "weekly": { "remaining": 40, "observedAt": "0001-01-01T00:00:00Z" } } } } ] }
            """)
        #expect(Set(response.current) == [
            reading(.claude, fileA, .fiveHour, used: 30, resets: nil, observed: "2026-11-22T11:00:00Z"),
            reading(.claude, fileA, .weekly, used: 60, resets: nil, observed: "2026-11-22T11:00:00Z"),
        ])
    }

    @Test func blankStatusIsNotOK() throws {
        let response = try parse("""
            { "accounts": [ { "id": "\(fileA)", "provider": "anthropic", "status": "ok",
                "reading": { "observedAt": "2026-11-22T11:00:00Z", "windows": {
                  "short": { "status": "", "remaining": 0 },
                  "weekly": { "status": "ok", "remaining": 40 } } } } ],
              "pools": [ { "provider": "anthropic", "window": "short", "history": [
                { "accounts": [ { "id": "\(fileA)", "status": "", "remaining": 0,
                                  "observedAt": "2026-11-22T10:55:00Z" } ] } ] } ] }
            """)
        #expect(response.current == [
            reading(.claude, fileA, .weekly, used: 60, resets: nil, observed: "2026-11-22T11:00:00Z"),
        ])
        #expect(response.history.isEmpty)
    }

    @Test func emptyEntryIDFallsBackToAccountID() throws {
        let response = try parse("""
            { "accounts": [ { "id": "", "account": { "id": "\(fileA)" }, "provider": "anthropic",
                              "status": "ok" } ],
              "pools": [ { "provider": "anthropic", "window": "weekly", "history": [
                { "accounts": [ { "id": "", "account": { "id": "\(fileA)" }, "status": "ok",
                                  "remaining": 90, "observedAt": "2026-11-22T10:55:00Z" } ] } ] } ] }
            """)
        #expect(response.history.map(\.fileKey) == [fileA])
    }

    @Test func providerMissingFromAccountsGivesNoReadings() throws {
        let response = try parse("""
            { "accounts": [ { "id": "\(fileA)", "provider": "anthropic", "status": "ok" } ],
              "pools": [ { "provider": "codex", "window": "weekly", "history": [
                { "accounts": [ { "id": "\(fileC)", "status": "ok", "remaining": 64,
                                  "observedAt": "2026-11-22T10:50:00Z" } ] } ] } ] }
            """)
        #expect(response.providers == [.claude: .served])
        #expect(response.history.isEmpty)
    }

    @Test func rangeIsWholeHoursWithinRouteLimits() {
        #expect(CliproxyForkHistorySource.rangeHours(24 * 3600) == 24)
        #expect(CliproxyForkHistorySource.rangeHours(90 * 60) == 2)
        #expect(CliproxyForkHistorySource.rangeHours(60) == 1)
        #expect(CliproxyForkHistorySource.rangeHours(0) == 1)
        #expect(CliproxyForkHistorySource.rangeHours(40 * 24 * 3600) == 720)
    }

    @Test func nonObjectBodyIsDecodingError() async {
        let transport = T6RoutedTransport([T6Paths.history: .ok(Data("[]".utf8))])
        guard case .decoding = await CliproxyForkHistorySource(config: config, transport: transport)
            .fetch(range: 3600).failureValue
        else {
            Issue.record("expected a decoding error")
            return
        }
    }
}
