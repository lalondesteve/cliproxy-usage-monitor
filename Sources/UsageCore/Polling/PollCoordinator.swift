import Foundation

/// T8. Polls the sources every 60 s, feeds the store and the ledger, and publishes a
/// `DashboardModel` (plan.md "Polling budget", "Auth failures stop polling", and
/// "Forecast" for the history range).
///
/// A tick runs two chains at the same time:
/// - cliproxy: the credential list (`UsageSource.fetch`), then the fork's
///   `quota/history` (one request for every provider). An auth error from the first
///   skips the second.
/// - ocgo: `/_ocgo/status`.
///
/// Auth latch: an auth error (`SourceError.isAuthError`: 401, or a 403 for remote
/// management disabled or a banned IP) from a source, from the fork history route for
/// cliproxy, or from a Test of the saved configuration, stops every request to that
/// source. Only `PollControl` clears it: `configChanged(kind)`, or `test(kind, config)`
/// with the saved configuration when its single request succeeds. Clearing it polls
/// that source at once. A successful Test of values other than the ones the
/// coordinator polls with reads `savedConfig` again; if the saved configuration now
/// equals them, the source is rebuilt with it, as `configChanged` does. A Test of any
/// other configuration never touches the latch.
///
/// Each source has a configuration revision, bumped by `configChanged`. A result that
/// comes back after the revision moved on is dropped, even when the configuration
/// changed back in between.
///
/// Each accepted snapshot is persisted, then applied: `store.append(readings)`,
/// `store.appendCounterMarks`, `store.saveLastSnapshot`, then `ledger.apply`. A
/// snapshot whose `takenAt` isn't after the last one accepted for its source is
/// dropped (clock corrections, late results). Fork `current` readings go to
/// `store.append`, then `ledger.apply(readings:)`; fork `history` goes to the store
/// only. A store error never stops the ledger update or the next tick; the latest one
/// is kept in `lastStoreError`.
///
/// History `range`: the time since the oldest of the newest fork-poller observations
/// of the providers the last history response served (saved in the store, so it holds
/// across relaunch), clamped to 1h...720h; 24h when none of them has an observation.
///
/// Sleep: between `.willSleep` and `.didWake` no request starts, and a tick already
/// running doesn't go on to fork history. If the power events end while asleep, the
/// Mac counts as awake (no gap). The gap from the sleep time to the
/// wake time is stored before the first poll after wake. One more gap runs from the
/// last stored poll to launch (`start()`). The store is pruned to 30 days once a day (it also prunes on
/// open).
public actor PollCoordinator: PollControl {
    public static let defaultInterval: TimeInterval = 60
    static let retention: TimeInterval = 30 * 24 * 3600
    static let pruneEvery: TimeInterval = 24 * 3600
    static let defaultRange: TimeInterval = 24 * 3600
    static let rangeLimits: ClosedRange<TimeInterval> = 3600...(720 * 3600)

    private struct Configured {
        let config: SourceConfig
        let source: any UsageSource
        let fork: (any ForkHistorySource)?
    }

    private let setup: PollSetup
    private let ledger: any LedgerUpdating
    private let store: any HistoryStore
    private let clock: any NowProvider
    private let scheduler: any PollScheduler
    private let interval: TimeInterval
    private let build: DashboardBuilder

    private var settings: PoolSettings
    private var configured: [SourceKind: Configured] = [:]
    private var statuses: [SourceKind: SourceStatus] = [:]
    private var latches: [SourceKind: SourceError] = [:]
    private var lastAccepted: [SourceKind: Date] = [:]
    private var forkStates: [Provider: ForkProviderState] = [:]
    private var forkRouteMissing = false
    private var sleepStartedAt: Date?
    private var wakeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var revisions: [SourceKind: Int] = [:]
    private var lastPrune: Date?
    private var started = false
    private var polling = false
    private var pending: Set<SourceKind> = []

    /// The last model published.
    public private(set) var model: DashboardModel?
    /// The last store error, if any (the coordinator keeps going).
    public private(set) var lastStoreError: String?
    /// Every published model; keeps only the newest one when the reader is behind.
    public nonisolated let models: AsyncStream<DashboardModel>
    private nonisolated let continuation: AsyncStream<DashboardModel>.Continuation

    public init(setup: PollSetup, ledger: any LedgerUpdating, store: any HistoryStore,
                settings: PoolSettings, clock: any NowProvider,
                scheduler: any PollScheduler = SystemPollScheduler(),
                interval: TimeInterval = PollCoordinator.defaultInterval,
                build: @escaping DashboardBuilder = PoolEngine.dashboard(ledger:settings:sources:now:)) {
        self.setup = setup
        self.ledger = ledger
        self.store = store
        self.settings = settings
        self.clock = clock
        self.scheduler = scheduler
        self.interval = interval
        self.build = build
        (models, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        for kind in SourceKind.allCases {
            configured[kind] = Self.configure(kind, setup: setup)
        }
    }

    // MARK: Lifecycle

    /// Restores the ledger from the store, records the gap from the last stored poll
    /// to now, and publishes. Runs once; `tick()` and `run(power:)` call it.
    public func start() {
        guard !started else { return }
        started = true
        let now = clock.now
        lastPrune = now   // the store prunes when it opens
        attempt { try ledger.restore() }
        if let snapshots = attempt({ try store.lastSnapshots() }) {
            for s in snapshots {
                lastAccepted[s.source] = max(lastAccepted[s.source] ?? s.takenAt, s.takenAt)
            }
            // A Test before start may have latched a source: keep its auth status.
            for (kind, at) in lastAccepted where configured[kind] != nil && latches[kind] == nil {
                statuses[kind] = .ok(at: at)
            }
            if let lastPoll = lastAccepted.values.max(), lastPoll < now {
                attempt { try store.recordGap(from: lastPoll, to: now) }
            }
        }
        forkStates = attempt { try store.forkProviderStates() } ?? [:]
        publish()
    }

    /// Starts, then ticks every `interval` until the scheduler throws or the task is
    /// cancelled, handling power events as they arrive.
    public func run(power: AsyncStream<PowerEvent>) async {
        start()
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in power { await self.handle(event) }
                await self.powerEventsEnded()
                return false
            }
            group.addTask {
                await self.loop()
                return true
            }
            while let loopEnded = await group.next() {
                if loopEnded {
                    group.cancelAll()
                    break
                }
            }
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            await untilAwake()
            if Task.isCancelled { return }
            let tickStart = clock.now
            await tick()
            do {
                try await scheduler.sleep(until: tickStart.addingTimeInterval(interval))
            } catch {
                return
            }
        }
    }

    /// One poll of every configured source that isn't latched, then a publish.
    public func tick() async {
        await poll(Set(SourceKind.allCases))
    }

    /// Between `.willSleep` and `.didWake`.
    public var isAsleep: Bool { sleepStartedAt != nil }

    /// Sleep starts a gap (a second `.willSleep` keeps the first time); wake records it
    /// with the store, then lets the polling loop go on. Neither polls by itself. A wake
    /// time at or before the sleep time records no gap.
    public func handle(_ event: PowerEvent) {
        switch event {
        case .willSleep(let at):
            if sleepStartedAt == nil { sleepStartedAt = at }
        case .didWake(let to):
            guard let from = sleepStartedAt else { return }
            sleepStartedAt = nil
            if to > from { attempt { try store.recordGap(from: from, to: to) } }
            let waiters = wakeWaiters
            wakeWaiters = [:]
            for w in waiters.values { w.resume() }
        }
    }

    /// Returns at once when awake; otherwise once awake when the loop gets to run (a
    /// wake followed at once by another sleep keeps it waiting), or on cancellation.
    private func untilAwake() async {
        while sleepStartedAt != nil, !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    if sleepStartedAt == nil || Task.isCancelled {
                        c.resume()
                    } else {
                        wakeWaiters[id] = c
                    }
                }
            } onCancel: {
                Task { await self.releaseWaiter(id) }
            }
        }
    }

    private func releaseWaiter(_ id: UUID) {
        wakeWaiters.removeValue(forKey: id)?.resume()
    }

    /// The power events ended (the app stopped observing them): treat the Mac as
    /// awake so the loop can't wait forever. No gap is recorded.
    private func powerEventsEnded() {
        guard sleepStartedAt != nil else { return }
        sleepStartedAt = nil
        let waiters = wakeWaiters
        wakeWaiters = [:]
        for w in waiters.values { w.resume() }
    }

    /// Where T11 reads this provider's history: the fork when the last history
    /// response served it, otherwise (paused, a 404 route, no fork, OpenCode Go) the
    /// app's own readings.
    public func historyOrigin(_ provider: Provider) -> HistoryOrigin {
        guard provider != .go, configured[.cliproxy]?.fork != nil, !forkRouteMissing,
              forkStates[provider] == .served else { return .local }
        return .fork
    }

    // MARK: PollControl

    public func test(_ kind: SourceKind, _ config: SourceConfig) async -> Result<String, SourceError> {
        let revision = revisions[kind, default: 0]
        let source = configured[kind]?.source ?? setup.makeSource(kind, config)
        let result = await source.test(config)
        guard revisions[kind, default: 0] == revision else { return result }
        // The saved configuration may have moved on since it was last read (a Keychain
        // read denied at launch, allowed now): read it again, and adopt it as
        // `configChanged` would when the tested values are what is saved.
        if case .success = result, configured[kind]?.config != config,
           let saved = Self.configure(kind, setup: setup), saved.config == config {
            revisions[kind, default: 0] += 1
            configured[kind] = saved
            latches[kind] = nil
            statuses[kind] = lastStatus(kind)
            if kind == .cliproxy { forkRouteMissing = false }
            await poll([kind])
            return result
        }
        // Only a Test of the saved configuration, still current, touches the latch.
        guard configured[kind]?.config == config else { return result }
        // Both branches bump the revision, so a request started before the Test (say a
        // late 401) can't undo what the Test decided.
        switch result {
        case .success where latches[kind] != nil:
            revisions[kind, default: 0] += 1
            latches[kind] = nil
            statuses[kind] = lastStatus(kind)
            await poll([kind])
        case .failure(let e) where e.isAuthError:
            revisions[kind, default: 0] += 1
            fail(kind, e)
            publish()
        default:
            break
        }
        return result
    }

    public func configChanged(_ kind: SourceKind) async {
        revisions[kind, default: 0] += 1
        latches[kind] = nil
        statuses[kind] = lastStatus(kind)
        configured[kind] = Self.configure(kind, setup: setup)
        if kind == .cliproxy { forkRouteMissing = false }
        if configured[kind] != nil {
            await poll([kind])
        } else {
            publish()
        }
    }

    public func poolSettingsChanged(_ settings: PoolSettings) async {
        self.settings = settings
        ledger.updateSettings(settings)
        publish()
    }

    // MARK: Polling

    /// Polls `kinds`. A call that arrives while a poll runs is folded into it, so a
    /// source never has two requests in flight.
    private func poll(_ kinds: Set<SourceKind>) async {
        start()
        pending.formUnion(kinds)
        guard !polling else { return }
        polling = true
        while !pending.isEmpty {
            let batch = pending
            pending = []
            await withTaskGroup(of: Void.self) { group in
                if batch.contains(.cliproxy) { group.addTask { await self.pollCliproxy() } }
                if batch.contains(.ocgo) { group.addTask { _ = await self.fetch(.ocgo) } }
            }
            pruneIfDue()
            publish()
        }
        polling = false
    }

    private func pollCliproxy() async {
        // No history request once the Mac started going to sleep during the fetch.
        guard await fetch(.cliproxy), sleepStartedAt == nil,
              let fork = configured[.cliproxy]?.fork, latches[.cliproxy] == nil else { return }
        let revision = revisions[.cliproxy, default: 0]
        let result = await fork.fetch(range: historyRange())
        guard revisions[.cliproxy, default: 0] == revision, latches[.cliproxy] == nil else { return }
        switch result {
        case .success(let response):
            accept(response)
        case .failure(.http(404)):
            forkRouteMissing = true
        case .failure(let e) where e.isAuthError:
            fail(.cliproxy, e)
        case .failure:
            break   // keeps the last provider states; the next tick asks again
        }
    }

    /// Fetches one source and records the result. True when the tick may go on to the
    /// next request of that source (success, or a failure that isn't an auth error).
    private func fetch(_ kind: SourceKind) async -> Bool {
        // Checked right before the request: work skipped while asleep waits for the
        // first tick after wake.
        guard let c = configured[kind], latches[kind] == nil, sleepStartedAt == nil else { return false }
        let revision = revisions[kind, default: 0]
        let result = await c.source.fetch(since: lastAccepted[kind])
        // Settings changed the source, or a Test latched it, while the request ran: its
        // answer is stale.
        guard revisions[kind, default: 0] == revision, latches[kind] == nil else { return false }
        switch result {
        case .success(let snapshot):
            accept(snapshot)
            statuses[kind] = .ok(at: lastAccepted[kind] ?? snapshot.takenAt)
            return true
        case .failure(let e):
            fail(kind, e)
            return !e.isAuthError
        }
    }

    /// The status after a latch clears or the configuration changes, until the next
    /// result: the last accepted poll, so the provider rows stay up.
    private func lastStatus(_ kind: SourceKind) -> SourceStatus? {
        lastAccepted[kind].map { .ok(at: $0) }
    }

    private func fail(_ kind: SourceKind, _ e: SourceError) {
        if e.isAuthError {
            latches[kind] = e
            statuses[kind] = .authStopped(e)
        } else if case .failing(_, let since) = statuses[kind] {
            statuses[kind] = .failing(e, since: since)
        } else {
            statuses[kind] = .failing(e, since: clock.now)
        }
    }

    private func accept(_ s: SourceSnapshot) {
        if let last = lastAccepted[s.source], s.takenAt <= last { return }
        lastAccepted[s.source] = s.takenAt
        attempt { try store.append(s.readings) }
        attempt { try store.appendCounterMarks(Ledger.counterMarks(from: s)) }
        attempt { try store.saveLastSnapshot(s) }
        ledger.apply(s)
    }

    private func accept(_ r: ForkHistoryResponse) {
        forkRouteMissing = false
        attempt { try store.append(r.history) }
        attempt { try store.append(r.current) }
        ledger.apply(readings: r.current)
        forkStates = r.providers
        attempt { try store.saveForkProviderStates(r.providers) }
    }

    private func historyRange() -> TimeInterval {
        let now = clock.now
        let served = Provider.allCases.filter { forkStates[$0] == .served }
        let newest = served.compactMap { p in
            attempt { try store.lastObservation(p, source: .forkPoller) } ?? nil
        }
        guard let oldest = newest.min() else { return Self.defaultRange }
        let range = now.timeIntervalSince(oldest)
        return min(max(range, Self.rangeLimits.lowerBound), Self.rangeLimits.upperBound)
    }

    private func pruneIfDue() {
        let now = clock.now
        if let last = lastPrune, now.timeIntervalSince(last) < Self.pruneEvery { return }
        lastPrune = now
        attempt { try store.prune(olderThan: now.addingTimeInterval(-Self.retention)) }
    }

    private func publish() {
        var sources: [SourceKind: SourceStatus] = [:]
        for kind in SourceKind.allCases {
            if configured[kind] == nil {
                sources[kind] = .notConfigured
            } else if let status = statuses[kind] {
                sources[kind] = status
            }
        }
        let m = build(ledger, settings, sources, clock.now)
        model = m
        continuation.yield(m)
    }

    @discardableResult
    private func attempt<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            lastStoreError = String(describing: error)
            return nil
        }
    }

    private static func configure(_ kind: SourceKind, setup: PollSetup) -> Configured? {
        guard let config = setup.savedConfig(kind) else { return nil }
        return Configured(config: config, source: setup.makeSource(kind, config),
                          fork: kind == .cliproxy ? setup.makeForkSource(config) : nil)
    }
}
