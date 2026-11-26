import AppKit
import UsageCore

/// Composition root (integrator, T10): saved settings and Keychain secrets -> sources ->
/// `PollCoordinator` (ledger, SQLite history, `PoolEngine`) -> status item and dropdown.
/// AppDelegate owns the objects; everything here can be built with fakes in tests.
enum Wiring {
    /// What the pipeline reads and writes outside the process. `live()` is the real app;
    /// tests and `--fixtures` swap in fakes.
    struct Environment: Sendable {
        var settingsStore: SettingsStore
        var secrets: any SecretStore
        var transport: any HTTPTransport
        var clock: any NowProvider
        /// The SQLite history file, or `":memory:"`.
        var databasePath: String
        var scheduler: any PollScheduler = SystemPollScheduler()
        var antigravitySource: AntigravitySource? = nil
        /// How far `clock` runs from wall time (`--now`); the dropdown's ages and
        /// countdowns use the same offset.
        var clockOffset: TimeInterval = 0

        /// UserDefaults, the login Keychain, URLSession, the system clock, and
        /// ~/Library/Application Support/<bundle id or app name>/history.sqlite.
        static func live() -> Environment {
            let path: String
            do {
                path = try Wiring.supportDirectory().appendingPathComponent("history.sqlite").path
            } catch {
                Wiring.log("no Application Support folder (\(error)); history kept in memory")
                path = ":memory:"
            }
            let transport = URLSessionTransport()
            return Environment(settingsStore: SettingsStore(), secrets: Keychain(),
                               transport: transport, clock: SystemNowProvider(), databasePath: path,
                               antigravitySource: AntigravitySource(transport: transport))
        }

        /// Development: the proxy sources answer from a capture folder laid out like
        /// `Tests/UsageCoreTests/Fixtures/live/`. Nothing real is touched: settings live
        /// in their own UserDefaults suite (reset at each launch, never the standard
        /// one), secrets in memory, history in memory. With `now` (the capture time) the
        /// clock starts there and runs at real speed, and polls wait against it, so
        /// ticks stay 60 s apart.
        static func fixtures(directory: URL, now: Date?,
                             makeDefaults: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) })
            throws -> Environment {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw LaunchError("--fixtures: \(directory.path) is not a folder")
            }
            let suiteName = (Bundle.main.bundleIdentifier ?? Keychain.defaultService) + ".fixtures"
            guard let defaults = makeDefaults(suiteName) else {
                throw LaunchError("--fixtures: can't open the UserDefaults suite \(suiteName)")
            }
            defaults.removePersistentDomain(forName: suiteName)
            let store = SettingsStore(defaults: defaults)
            let transport = FixtureDirectoryTransport(directory: directory)
            var settings = AppSettings()
            if transport.serves(CliproxyPaths.credentials) { settings.cliproxyURL = URL(string: "http://fixtures.invalid:8317") }
            if transport.serves(OcgoPaths.status) { settings.ocgoURL = URL(string: "http://fixtures.invalid:8320") }
            try store.save(settings)
            let offset = now?.timeIntervalSinceNow ?? 0
            return Environment(settingsStore: store,
                               secrets: MemorySecretStore([.cliproxyKey: "fixture-key"]),
                               transport: transport, clock: OffsetClock(offset: offset),
                               databasePath: ":memory:", scheduler: OffsetScheduler(offset: offset),
                               clockOffset: offset)
        }
    }

    struct LaunchError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The environment the options ask for. Throws for any option problem, so the app
    /// exits instead of starting the live pipeline by mistake.
    static func environment(for options: LaunchOptions) throws -> Environment {
        if !options.problems.isEmpty { throw LaunchError(options.problems.joined(separator: "; ")) }
        if let directory = options.fixtures { return try .fixtures(directory: directory, now: options.now) }
        return .live()
    }

    // MARK: Coordinator

    /// The configuration the coordinator polls with: the URL exactly as saved (so a
    /// Settings Test of the saved values matches it) and the Keychain secret. nil when
    /// the source has no URL. A missing or unreadable secret gives `secret: nil`: the
    /// cliproxy client then sends nothing and reports `.unauthorized`, which shows as
    /// an auth error in the dropdown instead of hiding the row.
    ///
    /// Reads the Keychain, which may block while macOS shows a prompt: call it off the
    /// main thread. The secret is read only when the source has a URL.
    static func savedConfig(_ kind: SourceKind, settings: AppSettings,
                            secrets: any SecretStore) -> SourceConfig? {
        let url: URL? = switch kind {
        case .cliproxy: settings.cliproxyURL
        case .ocgo: settings.ocgoURL
        }
        guard let url else { return nil }
        let secret: String?
        do {
            secret = try secrets.read(Keychain.Account.secret(for: kind))
        } catch {
            log("\(kind) secret unreadable (\(error)); polling without it")
            secret = nil
        }
        return SourceConfig(url: url, secret: secret)
    }

    /// `PollSetup` for the real sources over `env.transport`. Settings are read from the
    /// store each time the coordinator asks (at init and on `configChanged`), after
    /// `SettingsSaver` has written them.
    static func pollSetup(_ env: Environment) -> PollSetup {
        let settingsStore = env.settingsStore
        let secrets = env.secrets
        let transport = env.transport
        let clock = env.clock
        return PollSetup(
            savedConfig: { kind in
                savedConfig(kind, settings: settingsStore.load() ?? AppSettings(), secrets: secrets)
            },
            makeSource: { kind, config in
                switch kind {
                case .cliproxy: CliproxySource(config: config, transport: transport, now: clock)
                case .ocgo: OcgoSource(config: config, transport: transport, now: clock)
                }
            },
            makeForkSource: { config in
                CliproxyForkHistorySource(config: config, transport: transport)
            })
    }

    /// Opens the history (falling back to memory if the file can't be opened), builds
    /// the ledger and the coordinator. Reads the Keychain for each configured source,
    /// so call it off the main thread.
    static func makeCoordinator(_ env: Environment) -> PollCoordinator {
        let store: SQLiteHistoryStore
        do {
            store = try SQLiteHistoryStore(path: env.databasePath, now: env.clock)
        } catch {
            log("history at \(env.databasePath) unavailable (\(error)); kept in memory")
            // An in-memory database only fails when SQLite itself can't run.
            store = try! SQLiteHistoryStore(path: ":memory:", now: env.clock)
        }
        let settings = env.settingsStore.load() ?? AppSettings()
        return PollCoordinator(setup: pollSetup(env), ledger: Ledger(store: store, settings: settings.pool),
                               store: store, settings: settings.pool, clock: env.clock,
                               scheduler: env.scheduler, antigravitySource: env.antigravitySource)
    }

    // MARK: Settings

    /// The Settings model, saving to `env` and telling `pollControl` what changed.
    @MainActor
    static func makeSetupModel(settings: AppSettings, env: Environment,
                               pollControl: any PollControl) -> SetupModel {
        SetupModel(settings: settings, saver: SettingsSaver(
            settingsStore: env.settingsStore, secrets: env.secrets, pollControl: pollControl))
    }

    // MARK: System

    /// ~/Library/Application Support/<bundle id, or the process name>, created if missing.
    static func supportDirectory(fileManager: FileManager = .default,
                                 name: String = Bundle.main.bundleIdentifier
                                     ?? ProcessInfo.processInfo.processName) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Sleep and wake from `center` (NSWorkspace's in the app), each stamped with the
    /// time the notification arrived on the main queue. Observers go away when the
    /// stream ends.
    static func powerEvents(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
                            now: @escaping @Sendable () -> Date = { Date() }) -> AsyncStream<PowerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: PowerEvent.self)
        let tokens = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                continuation.yield(.willSleep(at: now()))
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                continuation.yield(.didWake(at: now()))
            },
        ]
        let observers = ObserverTokens(center: center, tokens: tokens)
        continuation.onTermination = { _ in observers.remove() }
        return stream
    }

    /// Opens the dropdown under the status item, or closes it. Positioned relative to
    /// `.zero` (the anchor's bounds as they change): in Compact the item shrinks back
    /// to the glyph 3 s after expanding, possibly while the dropdown is open.
    @MainActor
    static func toggle(_ dropdown: DropdownPopover, anchor: NSView?) {
        if dropdown.isShown {
            dropdown.close()
            return
        }
        guard let anchor else { return }
        dropdown.popover.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
        dropdown.popover.contentViewController?.view.window?.makeKey()
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("UsageMonitor: \(message)\n".utf8))
    }
}

/// Wall time shifted by `offset` seconds (`--now`).
struct OffsetClock: NowProvider {
    let offset: TimeInterval
    var now: Date { Date().addingTimeInterval(offset) }
}

/// Waits until a deadline on an `OffsetClock` with the same offset.
struct OffsetScheduler: PollScheduler {
    let offset: TimeInterval

    func sleep(until date: Date) async throws {
        try await SystemPollScheduler().sleep(until: date.addingTimeInterval(-offset))
    }
}

/// Something that shows each published dashboard (the status item, the dropdown).
@MainActor
protocol DashboardPresenting: AnyObject {
    func show(_ model: DashboardModel)
}

extension StatusItemController: DashboardPresenting {}
extension DropdownPopover: DashboardPresenting {}

/// The running pipeline: the coordinator's polling loop and the main-actor task that
/// hands each published model to the presenters.
@MainActor
final class AppPipeline {
    let coordinator: PollCoordinator
    private var tasks: [Task<Void, Never>] = []

    init(coordinator: PollCoordinator) {
        self.coordinator = coordinator
    }

    /// Delivers every model the coordinator publishes to `presenters`, in order, on the
    /// main actor. Call once: the coordinator's `models` stream has one reader.
    func present(to presenters: [any DashboardPresenting]) {
        let models = coordinator.models
        tasks.append(Task { @MainActor in
            for await model in models {
                for presenter in presenters { presenter.show(model) }
            }
        })
    }

    /// Starts polling every 60 s until `stop()`.
    func run(power: AsyncStream<PowerEvent>) {
        let coordinator = self.coordinator
        tasks.append(Task { await coordinator.run(power: power) })
    }

    /// One poll now (the menu's Refresh). Folded into a poll already running.
    func refresh() {
        let coordinator = self.coordinator
        Task { await coordinator.tick() }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}

/// `NotificationCenter` observer tokens, removed once.
private final class ObserverTokens: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol]

    init(center: NotificationCenter, tokens: [any NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    func remove() {
        let removed = lock.withLock { () -> [any NSObjectProtocol] in
            defer { tokens = [] }
            return tokens
        }
        removed.forEach(center.removeObserver)
    }
}

/// Request paths the fixture transport answers (from the sources and
/// `scripts/capture-fixtures.sh`).
enum CliproxyPaths {
    static let credentials = "/v8/management/credentials"
    static let quotaHistory = "/v8/management/quota/history"
    static let routingStrategy = "/v0/management/routing/strategy"
    static let config = "/v0/management/config"
}

enum OcgoPaths {
    static let status = "/_ocgo/status"
}

/// Answers each request from a capture folder by URL path, ignoring host and query;
/// 404 for a path with no file. File names are the ones
/// `scripts/capture-fixtures.sh` writes.
struct FixtureDirectoryTransport: HTTPTransport {
    static let files = [
        CliproxyPaths.credentials: "cliproxy-credentials.json",
        CliproxyPaths.quotaHistory: "cliproxy-quota-history-24h.json",
        CliproxyPaths.routingStrategy: "cliproxy-routing-strategy.json",
        CliproxyPaths.config: "cliproxy-config-routing.json",
        OcgoPaths.status: "ocgo-status.json",
    ]

    let directory: URL

    func file(for path: String) -> URL? {
        guard let name = Self.files[path] else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func serves(_ path: String) -> Bool { file(for: path) != nil }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = r.url ?? directory
        let (status, body): (Int, Data)
        if let file = file(for: url.path) {
            (status, body) = (200, try Data(contentsOf: file))
        } else {
            (status, body) = (404, Data("404 page not found".utf8))
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"])
        else { throw URLError(.badServerResponse) }
        return (body, response)
    }
}

/// Secrets in memory, for `--fixtures`.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Keychain.Account: String]

    init(_ values: [Keychain.Account: String] = [:]) {
        self.values = values
    }

    func read(_ account: Keychain.Account) throws -> String? { lock.withLock { values[account] } }
    func write(_ value: String, for account: Keychain.Account) throws { lock.withLock { values[account] = value } }
    func delete(_ account: Keychain.Account) throws { lock.withLock { values[account] = nil } }
}
