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
                                     "--fixtures", "/tmp/capture", "--now", "2026-11-22T12:00:00Z",
                                     "--debug-snapshot", "/tmp/item.png", "--ocgo-url", "http://h:8320"])
        #expect(o.fixtures?.path == "/tmp/capture")
        #expect(o.now == ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z"))
        #expect(o.debugSnapshot?.path == "/tmp/item.png")
        #expect(o.problems.isEmpty)
        #expect(LaunchOptions.parse(["bin"]) == LaunchOptions())
    }

    @Test func debugTokenHasItsOwnKeychainAccount() {
        #expect(Keychain.Account.debugTestToken.rawValue != Keychain.Account.ocgoToken.rawValue)
        #expect(Keychain.Account.debugTestToken.rawValue != Keychain.Account.cliproxyKey.rawValue)
    }
}
