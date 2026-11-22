import Foundation
import UsageCore

// Fakes for the T8 coordinator tests. Every fake writes what it was asked into one
// shared `T8Log`, so tests can check counts and order across sources, store and ledger.

/// A small lock-guarded box.
final class T8Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var get: Value { lock.withLock { value } }
    func set(_ v: Value) { lock.withLock { value = v } }
    func update<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

/// A clock the test moves by hand.
final class T8Clock: NowProvider, @unchecked Sendable {
    private let box: T8Box<Date>
    init(_ start: Date) { box = T8Box(start) }
    var now: Date { box.get }
    func set(_ d: Date) { box.set(d) }
    func advance(_ seconds: TimeInterval) { box.update { $0 = $0.addingTimeInterval(seconds) } }
}

/// Moves the fake clock to each deadline instead of sleeping, and stops the loop (by
/// throwing) at the first deadline at or after `stopAt`.
/// `onDeadline`, when set, runs after the clock moves (to send power events mid-loop).
struct T8Scheduler: PollScheduler {
    let clock: T8Clock
    let stopAt: Date
    var onDeadline: (@Sendable (Date) async -> Void)? = nil

    func sleep(until date: Date) async throws {
        if date >= stopAt { throw CancellationError() }
        if date > clock.now { clock.set(date) }
        await onDeadline?(date)
    }
}

/// Never returns until its task is cancelled; the test drives everything else.
struct T8BlockingScheduler: PollScheduler {
    func sleep(until date: Date) async throws {
        let (never, _) = AsyncStream<Void>.makeStream()
        for await _ in never {}
        throw CancellationError()
    }
}

/// One entry per call any fake received.
enum T8Event: Equatable, Sendable {
    case fetch(SourceKind)
    case test(SourceKind, SourceConfig)
    case history(range: TimeInterval)
    case append(count: Int)
    case appendCounterMarks
    case saveLastSnapshot(SourceKind)
    case saveForkProviderStates
    case recordGap(DateInterval)
    case prune(olderThan: Date)
    case applySnapshot(SourceKind)
    case applyReadings(count: Int)
}

final class T8Log: @unchecked Sendable {
    private let box = T8Box<[T8Event]>([])
    func add(_ e: T8Event) { box.update { $0.append(e) } }
    var events: [T8Event] { box.get }
    func count(_ e: T8Event) -> Int { events.filter { $0 == e }.count }
    var historyRanges: [TimeInterval] {
        events.compactMap { if case .history(let r) = $0 { r } else { nil } }
    }
    var gaps: [DateInterval] {
        events.compactMap { if case .recordGap(let g) = $0 { g } else { nil } }
    }
    var prunes: [Date] {
        events.compactMap { if case .prune(let d) = $0 { d } else { nil } }
    }
}

/// Holds requests in flight until the test opens it; stays open after.
final class T8Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if opened { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func open() {
        let pending = lock.withLock {
            opened = true
            defer { waiters = [] }
            return waiters
        }
        for c in pending { c.resume() }
    }
}

/// A `UsageSource` whose answers the test sets; `respond` gets the current time.
final class T8FakeSource: UsageSource, @unchecked Sendable {
    let kind: SourceKind
    private let log: T8Log
    private let clock: T8Clock
    let respond: T8Box<@Sendable (Date) -> Result<SourceSnapshot, SourceError>>
    let testResult = T8Box<Result<String, SourceError>>(.success("ok"))

    init(_ kind: SourceKind, log: T8Log, clock: T8Clock) {
        self.kind = kind
        self.log = log
        self.clock = clock
        respond = T8Box { now in
            .success(SourceSnapshot(source: kind, takenAt: now, accounts: [], readings: [],
                                    unclassified: [], routing: nil))
        }
    }

    func answer(_ r: @escaping @Sendable (Date) -> Result<SourceSnapshot, SourceError>) { respond.set(r) }
    func answer(_ r: Result<SourceSnapshot, SourceError>) { respond.set { _ in r } }

    /// When set, the next fetches compute their answer, then wait for the gate to open.
    let gate = T8Box<T8Gate?>(nil)

    func fetch(since: Date?) async -> Result<SourceSnapshot, SourceError> {
        log.add(.fetch(kind))
        let answer = respond.get(clock.now)
        if let gate = gate.get { await gate.wait() }
        return answer
    }

    func test(_ config: SourceConfig) async -> Result<String, SourceError> {
        log.add(.test(kind, config))
        return testResult.get
    }
}

final class T8FakeFork: ForkHistorySource, @unchecked Sendable {
    private let log: T8Log
    let respond = T8Box<Result<ForkHistoryResponse, SourceError>>(
        .success(ForkHistoryResponse(providers: [.claude: .served, .codex: .served], current: [],
                                     history: [])))

    init(log: T8Log) { self.log = log }

    func answer(_ r: Result<ForkHistoryResponse, SourceError>) { respond.set(r) }

    func fetch(range: TimeInterval) async -> Result<ForkHistoryResponse, SourceError> {
        log.add(.history(range: range))
        return respond.get
    }
}

/// Forwards to a real store, logs the writes, and throws from the methods named in
/// `failing`.
final class T8SpyStore: HistoryStore, @unchecked Sendable {
    struct Injected: Error {}
    let base: any HistoryStore
    private let log: T8Log
    let failing = T8Box<Set<String>>([])

    init(_ base: any HistoryStore, log: T8Log) {
        self.base = base
        self.log = log
    }

    private func check(_ name: String) throws {
        if failing.get.contains(name) { throw Injected() }
    }

    func append(_ readings: [SourceReading]) throws {
        log.add(.append(count: readings.count))
        try check("append")
        try base.append(readings)
    }
    func appendCounterMarks(_ marks: [CounterMark]) throws {
        log.add(.appendCounterMarks)
        try check("appendCounterMarks")
        try base.appendCounterMarks(marks)
    }
    func saveLastSnapshot(_ s: SourceSnapshot) throws {
        log.add(.saveLastSnapshot(s.source))
        try check("saveLastSnapshot")
        try base.saveLastSnapshot(s)
    }
    func lastSnapshots() throws -> [SourceSnapshot] { try base.lastSnapshots() }
    func readings(fileKeys: [String], _ w: WindowKind?, from: Date, to: Date) throws -> [SourceReading] {
        try base.readings(fileKeys: fileKeys, w, from: from, to: to)
    }
    func latestReadings() throws -> [SourceReading] { try base.latestReadings() }
    func counterMarks(since: Date) throws -> [CounterMark] { try base.counterMarks(since: since) }
    func alias(for id: AccountID) throws -> (alias: String, colorIndex: Int) { try base.alias(for: id) }
    func lastObservation(_ p: Provider, source: ReadingSource) throws -> Date? {
        try base.lastObservation(p, source: source)
    }
    func saveForkProviderStates(_ s: [Provider: ForkProviderState]) throws {
        log.add(.saveForkProviderStates)
        try check("saveForkProviderStates")
        try base.saveForkProviderStates(s)
    }
    func forkProviderStates() throws -> [Provider: ForkProviderState] { try base.forkProviderStates() }
    /// Runs inside `recordGap`, on the caller's executor (the coordinator's, when it
    /// records a wake gap).
    let onRecordGap = T8Box<(@Sendable () -> Void)?>(nil)

    func recordGap(from: Date, to: Date) throws {
        log.add(.recordGap(DateInterval(start: from, end: to)))
        onRecordGap.get?()
        try check("recordGap")
        try base.recordGap(from: from, to: to)
    }
    func gaps(since: Date) throws -> [DateInterval] { try base.gaps(since: since) }
    func prune(olderThan: Date) throws {
        log.add(.prune(olderThan: olderThan))
        try check("prune")
        try base.prune(olderThan: olderThan)
    }
}

/// The real `Ledger`, with its writes logged.
final class T8SpyLedger: LedgerUpdating, @unchecked Sendable {
    let base: Ledger
    private let log: T8Log

    init(_ base: Ledger, log: T8Log) {
        self.base = base
        self.log = log
    }

    var accounts: [MergedAccount] { base.accounts }
    var routing: [SourceKind: RoutingConfig] { base.routing }
    func latest(_ id: AccountID, _ w: WindowKind) -> WindowReading? { base.latest(id, w) }
    func resetProven(_ id: AccountID, _ w: WindowKind, resetAt: Date) -> Bool {
        base.resetProven(id, w, resetAt: resetAt)
    }
    func unclassified(_ id: AccountID) -> [UnclassifiedReading] { base.unclassified(id) }
    func updateSettings(_ settings: PoolSettings) { base.updateSettings(settings) }
    func apply(_ s: SourceSnapshot) {
        log.add(.applySnapshot(s.source))
        base.apply(s)
    }
    func apply(readings: [SourceReading]) {
        log.add(.applyReadings(count: readings.count))
        base.apply(readings: readings)
    }
    func restore() throws { try base.restore() }
}

/// A coordinator on a real SQLite store (in `db`) and a real ledger, with fake sources.
/// Several rigs can share one `db` to model a relaunch.
struct T8Rig {
    static let cliproxyConfig = SourceConfig(url: URL(string: "https://cliproxy.test")!, secret: "saved-key")
    static let ocgoConfig = SourceConfig(url: URL(string: "https://ocgo.test")!, secret: "token")

    let clock: T8Clock
    let log = T8Log()
    let cliproxy: T8FakeSource
    let ocgo: T8FakeSource
    let fork: T8FakeFork
    let store: T8SpyStore
    let ledger: T8SpyLedger
    let configs: T8Box<[SourceKind: SourceConfig]>
    /// Every model the coordinator built, in order (the `models` stream keeps only the
    /// newest).
    let published = T8Box<[DashboardModel]>([])
    let coordinator: PollCoordinator

    init(db: T5TempDatabase, at start: Date, withFork: Bool = true,
         configs: [SourceKind: SourceConfig] = [.cliproxy: T8Rig.cliproxyConfig, .ocgo: T8Rig.ocgoConfig],
         settings: PoolSettings = PoolSettings(),
         scheduler: ((T8Clock) -> any PollScheduler)? = nil) throws {
        clock = T8Clock(start)
        cliproxy = T8FakeSource(.cliproxy, log: log, clock: clock)
        ocgo = T8FakeSource(.ocgo, log: log, clock: clock)
        fork = T8FakeFork(log: log)
        store = T8SpyStore(try SQLiteHistoryStore(path: db.path, now: clock), log: log)
        ledger = T8SpyLedger(Ledger(store: store, settings: settings), log: log)
        let box = T8Box(configs)
        self.configs = box
        let sources: [SourceKind: T8FakeSource] = [.cliproxy: cliproxy, .ocgo: ocgo]
        let fork = self.fork
        let setup = PollSetup(
            savedConfig: { box.get[$0] },
            makeSource: { kind, _ in sources[kind]! },
            makeForkSource: { _ in withFork ? fork : nil })
        let published = self.published
        coordinator = PollCoordinator(
            setup: setup, ledger: ledger, store: store, settings: settings, clock: clock,
            scheduler: scheduler?(clock) ?? T8BlockingScheduler(),
            build: { ledger, settings, sources, now in
                let m = PoolEngine.dashboard(ledger: ledger, settings: settings, sources: sources, now: now)
                published.update { $0.append(m) }
                return m
            })
    }
}
