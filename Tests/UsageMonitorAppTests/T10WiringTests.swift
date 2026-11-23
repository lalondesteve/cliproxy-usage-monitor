import AppKit
import Foundation
import Testing
import UsageCore
@testable import UsageMonitorApp

/// T10 wiring through `Wiring` and `AppPipeline`, with fakes only: settings in a private
/// UserDefaults suite, secrets in memory, a recording transport (no network), a
/// temporary SQLite file. The presenter renders with T9a's `StatusDisplay`, the state
/// behind the status item button, so "title" below is the text the menubar shows.
@MainActor
@Suite("T10 wiring", .serialized)
struct T10WiringTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("UsageCoreTests/Fixtures/synthetic")
    static let ocgoA = URL(string: "http://127.0.0.1:8320")!
    static let ocgoB = URL(string: "http://127.0.0.1:9320")!

    /// A wired coordinator and pipeline over fakes. Call `stop()` at the end.
    @MainActor
    final class Harness {
        let suite = T9cDefaults()
        let secrets: T9cFakeSecretStore
        let transport = T10Transport()
        let clock = T10Clock(Date(timeIntervalSince1970: 1_795_348_800))   // 2026-11-22T12:00:00Z
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("T10-\(UUID().uuidString).sqlite")
        let env: Wiring.Environment
        let presenter = T10Presenter()
        let pipeline: AppPipeline
        let control: T10ForwardingControl

        init(settings: AppSettings, secrets: [Keychain.Account: String] = [.ocgoToken: "go-token"]) throws {
            self.secrets = T9cFakeSecretStore(secrets)
            let store = SettingsStore(defaults: suite.defaults)
            try store.save(settings)
            env = Wiring.Environment(settingsStore: store, secrets: self.secrets, transport: transport,
                                     clock: clock, databasePath: database.path)
            let coordinator = Wiring.makeCoordinator(env)
            control = T10ForwardingControl(coordinator)
            pipeline = AppPipeline(coordinator: coordinator)
            pipeline.present(to: [presenter])
        }

        func stop() {
            pipeline.stop()
            try? FileManager.default.removeItem(at: database)
        }
    }

    @Test func publishedModelReachesTheStatusItemTitle() async throws {
        let h = try Harness(settings: AppSettings(ocgoURL: Self.ocgoA))
        defer { h.stop() }
        h.transport.ocgoBody = try Data(contentsOf: Self.fixtures.appendingPathComponent("T1/ocgo-status.json"))

        await h.pipeline.coordinator.tick()
        try await t9cWait("Go title") { h.presenter.titles[.go] == "48%" }   // (48 + 60 + 36) / 3
        #expect(h.presenter.titles.keys.sorted { $0.rawValue < $1.rawValue } == [.go])
        #expect(h.presenter.last?.sources[.cliproxy] == .notConfigured)
        // The coordinator polled the saved URL with the Keychain token.
        let request = try #require(h.transport.requests.first)
        #expect(request.url?.host == "127.0.0.1" && request.url?.port == 8320)
        #expect(request.url?.path == "/_ocgo/status")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer go-token")
    }

    @Test func savingANewOcgoURLCallsConfigChangedAndPollsIt() async throws {
        let h = try Harness(settings: AppSettings(ocgoURL: Self.ocgoA))
        defer { h.stop() }
        h.transport.ocgoBody = try Data(contentsOf: Self.fixtures.appendingPathComponent("T1/ocgo-status.json"))
        await h.pipeline.coordinator.tick()
        try await t9cWait("first model") { h.presenter.titles[.go] == "48%" }

        let model = Wiring.makeSetupModel(settings: h.env.settingsStore.load()!, env: h.env, pollControl: h.control)
        var saved: [AppSettings] = []
        model.onSaved = { settings, _ in saved.append(settings) }
        await model.load()
        model.form.ocgoURL = Self.ocgoB.absoluteString
        h.clock.advance(60)
        await model.save()

        #expect(model.saveState == .saved)
        #expect(await h.control.calls == [.configChanged(.ocgo)])
        #expect(saved.map(\.ocgoURL) == [Self.ocgoB])
        #expect(h.env.settingsStore.load()?.ocgoURL == Self.ocgoB)
        // configChanged re-read the saved settings and polled the new URL at once.
        let last = try #require(h.transport.requests.last)
        #expect(last.url?.port == 9320)
        #expect(h.transport.requests.count == 2)
        #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer go-token")
        try await t9cWait("model after save") { h.presenter.last?.generatedAt == h.clock.now }
        #expect(h.presenter.titles[.go] == "48%")
    }

    @Test func clearingTheOcgoURLHidesTheGoRow() async throws {
        let h = try Harness(settings: AppSettings(ocgoURL: Self.ocgoA))
        defer { h.stop() }
        h.transport.ocgoBody = try Data(contentsOf: Self.fixtures.appendingPathComponent("T1/ocgo-status.json"))
        await h.pipeline.coordinator.tick()
        try await t9cWait("first model") { h.presenter.titles[.go] == "48%" }

        let model = Wiring.makeSetupModel(settings: h.env.settingsStore.load()!, env: h.env, pollControl: h.control)
        await model.load()
        model.form.ocgoURL = ""
        model.form.ocgoToken.value = ""
        await model.save()

        #expect(model.saveState == .saved)
        #expect(await h.control.calls == [.configChanged(.ocgo)])
        try await t9cWait("Go row hidden") { h.presenter.last?.sources[.ocgo] == .notConfigured }
        #expect(h.presenter.titles.isEmpty)
        #expect(h.presenter.last?.row(.go) == nil)
        #expect(h.transport.requests.count == 1, "no request once ocgo isn't configured")
        #expect(h.secrets.stored[.ocgoToken] == nil)
    }

    @Test func menubarStyleOnlySaveCallsNoPollControl() async throws {
        let h = try Harness(settings: AppSettings(ocgoURL: Self.ocgoA))
        defer { h.stop() }
        let model = Wiring.makeSetupModel(settings: h.env.settingsStore.load()!, env: h.env, pollControl: h.control)
        var styles: [MenubarStyle] = []
        model.onSaved = { settings, _ in styles.append(settings.menubarStyle) }
        await model.load()
        model.form.menubarStyle = .compact
        await model.save()
        #expect(styles == [.compact])
        #expect(await h.control.calls.isEmpty)
    }

    // MARK: Saved configuration

    @Test func savedConfigUsesTheSavedURLAndTheKeychainSecret() {
        let url = URL(string: "http://100.64.0.1:8317/management.html")!
        let secrets = T9cFakeSecretStore([.cliproxyKey: "k"])
        let settings = AppSettings(cliproxyURL: url)
        // The URL exactly as saved, so a Settings Test of the saved values matches it.
        #expect(Wiring.savedConfig(.cliproxy, settings: settings, secrets: secrets)
            == SourceConfig(url: url, secret: "k"))
        #expect(Wiring.savedConfig(.ocgo, settings: settings, secrets: secrets) == nil)

        // No URL: no Keychain read at all (a read could block on a prompt).
        let gated = T9cFakeSecretStore([.cliproxyKey: "k"])
        let gate = gated.holdNextRead()
        #expect(Wiring.savedConfig(.cliproxy, settings: AppSettings(), secrets: gated) == nil)
        #expect(!gate.hasArrived)
        gate.release()

        // An unreadable secret polls without one (cliproxy then sends nothing).
        secrets.failReads(.cliproxyKey)
        #expect(Wiring.savedConfig(.cliproxy, settings: settings, secrets: secrets)
            == SourceConfig(url: url, secret: nil))
    }

    @Test func cliproxyWithoutAKeySendsNoRequest() async throws {
        let h = try Harness(settings: AppSettings(cliproxyURL: URL(string: "http://127.0.0.1:8317")!), secrets: [:])
        defer { h.stop() }
        await h.pipeline.coordinator.tick()
        try await t9cWait("auth stop") {
            h.presenter.last?.sources[.cliproxy] == .authStopped(.unauthorized)
        }
        #expect(h.transport.requests.isEmpty)
    }

    // MARK: Fixtures mode and system glue

    @Test func fixtureEnvironmentReplaysACaptureFolder() async throws {
        let now = Date(timeIntervalSince1970: 1_795_348_800)   // EXPECTED.md's as-of time
        let env = try Wiring.Environment.fixtures(directory: Self.fixtures.appendingPathComponent("T10"), now: now)
        defer { Self.removeFixtureSuite() }
        #expect(env.databasePath == ":memory:")
        #expect(env.secrets is MemorySecretStore)
        let coordinator = Wiring.makeCoordinator(env)
        await coordinator.tick()
        let model = try #require(await coordinator.model)
        var display = StatusDisplay()
        display.show(model)
        // Synthetic EXPECTED.md: Claude 40-73.3, Codex 75, Go 55 (usable 5-hour).
        #expect(display.entries.map(\.text) == ["40-73%", "75%", "55%"])
    }

    static func removeFixtureSuite() {
        let suite = (Bundle.main.bundleIdentifier ?? Keychain.defaultService) + ".fixtures"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    /// A: the fixture clock starts at `--now` and runs, and the poll loop waits against
    /// it. With a fixed past clock and the wall-time scheduler the loop never slept.
    @Test func fixtureModeWithAPastNowTicksOncePerInterval() async throws {
        let past = Date(timeIntervalSince1970: 1_577_880_000)   // 2020-01-01T12:00:00Z
        var env = try Wiring.Environment.fixtures(directory: Self.fixtures.appendingPathComponent("T10"), now: past)
        defer { Self.removeFixtureSuite() }
        #expect(abs(env.clock.now.timeIntervalSince(past)) < 5)
        #expect(abs(env.clockOffset - past.timeIntervalSinceNow) < 5)
        let counter = T10CountingTransport(env.transport)
        env.transport = counter
        let coordinator = Wiring.makeCoordinator(env)
        let (power, powerInput) = AsyncStream.makeStream(of: PowerEvent.self)
        let run = Task { await coordinator.run(power: power) }
        try await t9cWait("first tick") { counter.count(OcgoPaths.status) == 1 }
        try await Task.sleep(for: .milliseconds(300))
        run.cancel()
        powerInput.finish()
        await run.value
        #expect(counter.count(OcgoPaths.status) == 1)
    }

    @Test func offsetSchedulerWaitsAgainstTheShiftedClock() async throws {
        let offset: TimeInterval = -86_400 * 365
        let clock = OffsetClock(offset: offset)
        let start = Date()
        try await OffsetScheduler(offset: offset).sleep(until: clock.now.addingTimeInterval(0.2))
        #expect(Date().timeIntervalSince(start) >= 0.15)
    }

    // MARK: C: launch option problems

    @Test func fixturesWithoutAFolderIsRejected() {
        for args in [["bin", "--fixtures"], ["bin", "--fixtures", "--now", "2026-11-22T12:00:00Z"],
                     ["bin", "--fixtures", ""]] {
            let options = LaunchOptions.parse(args)
            #expect(options.fixtures == nil)
            #expect(options.problems == ["--fixtures needs a capture folder"], "\(args)")
            #expect(throws: Wiring.LaunchError.self) { try Wiring.environment(for: options) }
        }
        #expect(!LaunchOptions.parse(["bin", "--now", "yesterday"]).problems.isEmpty)
        #expect(!LaunchOptions.parse(["bin", "--debug-snapshot"]).problems.isEmpty)
        #expect(LaunchOptions.parse(["bin", "--fixtures", "/tmp/capture"]).problems.isEmpty)
    }

    @Test func fixturesNeverFallBackToTheStandardDefaults() {
        let folder = Self.fixtures.appendingPathComponent("T10")
        var asked: [String] = []
        #expect(throws: Wiring.LaunchError.self) {
            try Wiring.Environment.fixtures(directory: folder, now: nil) { asked.append($0); return nil }
        }
        #expect(asked.count == 1 && asked[0].hasSuffix(".fixtures"))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("T10-missing-\(UUID().uuidString)")
        #expect(throws: Wiring.LaunchError.self) {
            try Wiring.Environment.fixtures(directory: missing, now: nil) { _ in
                Issue.record("opened defaults for a missing folder")
                return nil
            }
        }
    }

    // MARK: B: right-click status line

    @Test func statusLineShowsEachSourceState() {
        let utc = TimeZone(identifier: "UTC")!
        let at = Date(timeIntervalSince1970: 1_795_348_800)
        let time = at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: utc))
        func line(_ sources: [SourceKind: SourceStatus]) -> String {
            StatusItemController.statusLine(for: DashboardModel(generatedAt: at, rows: [], sources: sources),
                                            timeZone: utc)
        }
        #expect(line([.cliproxy: .notConfigured, .ocgo: .notConfigured]) == "Not configured")
        #expect(line([.cliproxy: .authStopped(.unauthorized), .ocgo: .ok(at: at)])
                == "cliproxy: stopped, management key rejected · ocgo-proxy: updated \(time)")
        #expect(line([.cliproxy: .notConfigured, .ocgo: .failing(.timeout, since: at)])
                == "ocgo-proxy: failing since \(time), timed out")
        #expect(line([.ocgo: .authStopped(.unauthorized)])
                == "cliproxy: waiting for the first poll · ocgo-proxy: stopped, token rejected")
        #expect(!line([.ocgo: .ok(at: at)]).contains("no data"))
    }

    @Test func fixtureTransportRoutesByPath() async throws {
        let t = FixtureDirectoryTransport(directory: Self.fixtures.appendingPathComponent("T10"))
        let (_, ok) = try await t.send(URLRequest(url: URL(string: "http://x/v8/management/quota/history?range=24h")!))
        #expect(ok.statusCode == 200)
        let (_, missing) = try await t.send(URLRequest(url: URL(string: "http://x/v0/management/auth-files")!))
        #expect(missing.statusCode == 404)
        #expect(!FixtureDirectoryTransport(directory: Self.fixtures.appendingPathComponent("T7")).serves(OcgoPaths.status))
    }

    @Test func powerEventsAreStampedWhenTheyArrive() async throws {
        let center = NotificationCenter()
        let stamps = T10Clock(Date(timeIntervalSince1970: 1000))
        let stream = Wiring.powerEvents(center: center, now: { stamps.now })
        var iterator = stream.makeAsyncIterator()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        stamps.advance(3600)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await iterator.next() == .willSleep(at: Date(timeIntervalSince1970: 1000)))
        #expect(await iterator.next() == .didWake(at: Date(timeIntervalSince1970: 4600)))
    }
}

// MARK: Fakes

/// Records each model and renders it the way the status item does.
@MainActor
final class T10Presenter: DashboardPresenting {
    private(set) var models: [DashboardModel] = []
    private(set) var display = StatusDisplay()

    var last: DashboardModel? { models.last }
    var titles: [Provider: String] {
        Dictionary(uniqueKeysWithValues: display.entries.map { ($0.provider, $0.text) })
    }

    func show(_ model: DashboardModel) {
        models.append(model)
        display.show(model)
    }
}

/// Serves `/_ocgo/status` from `ocgoBody`, 404 otherwise, and records every request.
final class T10Transport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _ocgoBody = Data()

    var requests: [URLRequest] { lock.withLock { _requests } }
    var ocgoBody: Data {
        get { lock.withLock { _ocgoBody } }
        set { lock.withLock { _ocgoBody = newValue } }
    }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = lock.withLock { () -> Data? in
            _requests.append(r)
            return r.url?.path == "/_ocgo/status" ? _ocgoBody : nil
        }
        return (body ?? Data("404 page not found".utf8),
                HTTPURLResponse(url: r.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Counts requests by path, then forwards them.
final class T10CountingTransport: HTTPTransport, @unchecked Sendable {
    private let base: any HTTPTransport
    private let lock = NSLock()
    private var paths: [String] = []

    init(_ base: any HTTPTransport) { self.base = base }

    func count(_ path: String) -> Int { lock.withLock { paths.filter { $0 == path }.count } }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { paths.append(r.url?.path ?? "") }
        return try await base.send(r)
    }
}

final class T10Clock: NowProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Records the PollControl calls Settings makes, then forwards them to the real
/// coordinator.
actor T10ForwardingControl: PollControl {
    enum Call: Equatable {
        case test(SourceKind, SourceConfig)
        case configChanged(SourceKind)
        case poolSettingsChanged(PoolSettings)
    }

    private let target: any PollControl
    private(set) var calls: [Call] = []

    init(_ target: any PollControl) { self.target = target }

    func test(_ kind: SourceKind, _ config: SourceConfig) async -> Result<String, SourceError> {
        calls.append(.test(kind, config))
        return await target.test(kind, config)
    }

    func configChanged(_ kind: SourceKind) async {
        calls.append(.configChanged(kind))
        await target.configChanged(kind)
    }

    func poolSettingsChanged(_ settings: PoolSettings) async {
        calls.append(.poolSettingsChanged(settings))
        await target.poolSettingsChanged(settings)
    }
}
