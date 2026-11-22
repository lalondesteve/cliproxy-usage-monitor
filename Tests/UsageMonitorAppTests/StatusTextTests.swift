import Foundation
import Testing
import UsageCore
@testable import UsageMonitorApp

@Suite("T1 status item")
struct StatusTextTests {
    private func gauge(_ range: PercentRange?) -> WindowGauge {
        WindowGauge(window: .fiveHour, known: 3, total: 3, quota: range, usable: range, bars: [],
                    nextRefill: nil, allFull: false, pace: nil, accounts: [])
    }

    @Test func exactRangeAndMissing() {
        #expect(StatusText.title(for: gauge(PercentRange(exact: 48))) == "48%")
        #expect(StatusText.title(for: gauge(PercentRange(lower: 123.0 / 3, upper: 223.0 / 3))) == "41-74%")
        #expect(StatusText.title(for: gauge(nil)) == "--")
        #expect(StatusText.title(for: nil) == "--")
    }

    @Test func launchOptions() {
        let o = LaunchOptions.parse(["bin", "-NSDocumentRevisionsDebugMode", "YES",
                                     "--ocgo-url", "http://100.64.0.1:8320", "--debug-write-test-token"])
        #expect(o.ocgoURL == URL(string: "http://100.64.0.1:8320"))
        #expect(o.debugWriteTestToken)
        #expect(o.ocgoFixture == nil)
        #expect(LaunchOptions.parse(["bin"]) == LaunchOptions())
    }

    @Test func debugTokenHasItsOwnKeychainAccount() {
        #expect(Keychain.Account.debugTestToken.rawValue != Keychain.Account.ocgoToken.rawValue)
        #expect(Keychain.Account.debugTestToken.rawValue != Keychain.Account.cliproxyKey.rawValue)
    }

    @Test func liveURLWithoutTokenIsAnError() {
        var o = LaunchOptions()
        o.ocgoURL = URL(string: "http://h:8320")
        guard case .failure(.noToken) = Wiring.ocgoSource(options: o, token: nil) else {
            Issue.record("expected noToken")
            return
        }
    }

    @Test func fixtureSourcePollsTo48() async throws {
        var o = LaunchOptions()
        o.ocgoFixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UsageCoreTests/Fixtures/synthetic/T1/ocgo-status.json")
        let setup = try Wiring.ocgoSource(options: o, token: nil).get()
        let model = try await Wiring.poll(setup.source).get()
        #expect(StatusText.title(for: model.row(.go)?.fiveHour) == "48%")
    }
}
