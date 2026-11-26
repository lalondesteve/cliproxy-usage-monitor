import Foundation
import Testing
@testable import UsageCore

@Suite("Local Antigravity quotas")
struct AntigravitySourceTests {
    private static let modelsPath = "/v1internal:fetchAvailableModels"
    private static let summaryPath = "/v1internal:retrieveUserQuotaSummary"
    private static let now = date("2026-11-26T22:00:00Z")
    private static let models = T6RoutedTransport.Reply.ok(Data("""
        {"models":{
            "gemini-flash":{"quotaInfo":{"remainingFraction":0.87,"resetTime":"2026-11-27T03:00:00Z"}},
            "gemini-pro":{"quotaInfo":{"remainingFraction":0.45,"resetTime":"2026-11-27T04:00:00Z"}},
            "gemini-invalid":{"quotaInfo":{"remainingFraction":-0.1}},
            "claude-opus":{"quotaInfo":{"remainingFraction":0.1}},
            "gemini-without-quota":{}
        }}
        """.utf8))
    private static let summary = T6RoutedTransport.Reply.ok(Data("""
        {"groups":[{"buckets":[
            {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0,
             "resetTime":"2026-11-30T01:24:30Z"},
            {"bucketId":"3p-5h","window":"5h","remainingFraction":0.37,
             "resetTime":"2026-11-27T03:26:52Z"}
        ]}]}
        """.utf8))

    @Test func pollsLocalLoginAndPublishesSeparateQuotas() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeLogin(in: home)
        let transport = T6RoutedTransport([Self.modelsPath: Self.models, Self.summaryPath: Self.summary])
        let source = AntigravitySource(transport: transport, home: home)
        let clock = T8Clock(Self.now)
        let store = try SQLiteHistoryStore(path: ":memory:", now: clock)
        let settings = PoolSettings()
        let setup = PollSetup(savedConfig: { _ in nil }, makeSource: { _, _ in
            fatalError("No proxy source is configured")
        }, makeForkSource: { _ in nil })
        let coordinator = PollCoordinator(setup: setup, ledger: Ledger(store: store, settings: settings),
                                          store: store, settings: settings, clock: clock,
                                          antigravitySource: source)

        await coordinator.tick()
        let dashboard = try #require(await coordinator.model)
        let usage = try #require(dashboard.antigravity)
        #expect(dashboard.rows.isEmpty)
        #expect(usage.gemini?.remaining == 45)
        #expect(usage.gemini?.resetsAt == date("2026-11-27T04:00:00Z"))
        #expect(usage.fiveHour?.remaining == 37)
        #expect(usage.weekly?.remaining == 0)
        #expect(usage.weekly?.resetsAt == date("2026-11-30T01:24:30Z"))
        #expect(!usage.waitingForLogin)
        #expect(transport.paths.sorted() == [Self.modelsPath, Self.summaryPath])
        for request in transport.requests {
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "daily-cloudcode-pa.googleapis.com")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-access-token")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("antigravity/") == true)
        }
    }

    @Test func waitsForRenewalAndKeepsEarlierQuotasThroughARequestFailure() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = T6RoutedTransport([Self.modelsPath: Self.models, Self.summaryPath: Self.summary])
        let source = AntigravitySource(transport: transport, home: home)
        let expired = Self.now.addingTimeInterval(3600)

        #expect(await source.fetch(now: Self.now) == nil)
        try writeLogin(in: home)
        let initial = try #require(await source.fetch(now: Self.now))
        let waiting = try #require(await source.fetch(now: expired))
        #expect(waiting.waitingForLogin)
        #expect(waiting.gemini == initial.gemini)
        #expect(transport.requests.count == 2)

        try writeLogin(in: home, token: "renewed", expiry: "2026-11-27T00:00:00Z")
        transport.set(Self.summaryPath, .status(503))
        let renewed = try #require(await source.fetch(now: expired))
        #expect(!renewed.waitingForLogin)
        #expect(renewed.gemini?.observedAt == expired)
        #expect(renewed.weekly == initial.weekly)
        #expect(renewed.weekly?.observedAt != renewed.checkedAt)
        #expect(transport.requests.count == 4)
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        return home
    }

    private func writeLogin(in home: URL, token: String = "fake-access-token",
                            expiry: String = "2026-11-26T17:00:00.123456-05:00") throws {
        let directory = home.appendingPathComponent(".t3/userdata/providers/antigravity/profile/antigravity-acp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("""
            {"token":{"access_token":"\(token)","expiry":"\(expiry)","refresh_token":"unused"},
             "id_token_email":"antigravity@example.com"}
            """.utf8)
        try data.write(to: directory.appendingPathComponent("antigravity-oauth-token"), options: .atomic)
    }
}
