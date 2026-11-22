import Foundation

/// T4. Keeps the latest state from every source and answers `LedgerView` for the pool
/// engine (T3) and the forecast (T11).
///
/// - Readings are kept keyed by credential file (`provider`, `fileKey`, `window`), the
///   newest per key. They resolve to an account at read time through the latest
///   credential list of each source and the Settings alias list, so a reading whose
///   file isn't listed is kept but ignored until a credential with that `fileKey`
///   appears, and adding an alias re-attaches readings already held.
/// - A snapshot that lacks a window doesn't erase an earlier reading of it (E7).
/// - Accounts with the same `AccountID` (after the alias list) merge: enabled if any
///   file is, available if any enabled file is, routing kept per credential file.
/// - Reset proof (`resetProven`) is one of two things. The first is a reading of that
///   window observed at or after the reset whose own reset is unset or later (the
///   only proof for ocgo, E16). The second, for cliproxy, is the same set of credential
///   files at a listing before the reset and at the latest listing, each with the same
///   request counter at every listing in between (E5 to E5e).
///
/// Persistence: the ledger only reads the store (`alias(for:)` and `restore()`). T8
/// writes what sources return: `append` for readings, `saveLastSnapshot`, and
/// `appendCounterMarks(Ledger.counterMarks(from: snapshot))` for each snapshot, then
/// calls `apply`. `apply` derives the same marks in memory, so a running ledger and one
/// restored from the store give the same answers, with one exception: after
/// `restore()`, a counter proof can fail where the running ledger proved it (see
/// `counterProof`). That window then shows as unknown, never as a wrong value.
///
/// Thread safety: every member takes one lock. Store calls run under that lock: the
/// write side calls `store.alias(for:)` for accounts seen for the first time, and
/// `restore()` holds it across its reads. The store never calls back into the ledger.
public final class Ledger: LedgerUpdating, @unchecked Sendable {
    private let store: any HistoryStore
    private let lock = NSLock()

    // Raw state, as sources reported it.
    private var settings: PoolSettings
    private var snapshots: [SourceKind: SourceSnapshot] = [:]
    private var readings: [ReadingKey: SourceReading] = [:]
    private var counters = CounterHistory()
    /// Every credential file seen in a snapshot, with its identity before the alias
    /// list. Lets the counter proof notice a file that left an account's set.
    private var seenFiles: [String: AccountID] = [:]
    private var aliasCache: [AccountID: AliasEntry] = [:]

    // Derived on every write, so reads are lookups.
    private var derived = Derived()

    public init(store: any HistoryStore, settings: PoolSettings) {
        self.store = store
        self.settings = settings
    }

    /// The counter marks a snapshot carries: one per credential file with a request
    /// counter, at the snapshot's `takenAt`. T8 persists these with
    /// `appendCounterMarks`; `apply` derives the same ones.
    public static func counterMarks(from s: SourceSnapshot) -> [CounterMark] {
        s.accounts.compactMap { a in
            a.requestCounter.map { CounterMark(fileKey: a.fileKey, at: s.takenAt, value: $0) }
        }
    }

    // MARK: LedgerUpdating

    public func updateSettings(_ settings: PoolSettings) {
        lock.withLock {
            self.settings = settings
            recompute()
        }
    }

    public func apply(_ s: SourceSnapshot) {
        lock.withLock {
            ingest(s)
            recompute()
        }
    }

    public func apply(readings newReadings: [SourceReading]) {
        lock.withLock {
            merge(newReadings)
            recompute()
        }
    }

    /// Rebuilds the state from the store: the last snapshot per source, the newest
    /// stored reading per key, and every stored counter mark. Replaces what the ledger
    /// held before.
    ///
    /// The lock is held from the first store read until the restored state is in
    /// place, so an `apply` running at the same time lands either before it (and is
    /// replaced by what the store holds) or after it. This can't deadlock: the store
    /// has its own lock and never calls back into the ledger.
    public func restore() throws {
        try lock.withLock {
            let lastSnapshots = try store.lastSnapshots()
            let latest = try store.latestReadings()
            let marks = try store.counterMarks(since: .distantPast)

            snapshots = [:]
            readings = [:]
            counters = CounterHistory()
            seenFiles = [:]
            for s in lastSnapshots.sorted(by: { $0.takenAt < $1.takenAt }) {
                ingestAccounts(s)
                merge(s.readings)
            }
            merge(latest)
            let listings = Dictionary(grouping: marks, by: \.at)
            for at in listings.keys.sorted() {
                counters.record(at: at, marks: Self.markValues(listings[at] ?? []))
            }
            recompute()
        }
    }

    // MARK: LedgerView

    public var accounts: [MergedAccount] {
        lock.withLock { derived.accounts }
    }

    public var routing: [SourceKind: RoutingConfig] {
        lock.withLock { derived.routing }
    }

    public func latest(_ id: AccountID, _ w: WindowKind) -> WindowReading? {
        lock.withLock {
            derived.latest[id]?[w].map { WindowReading(account: id, reading: $0) }
        }
    }

    public func resetProven(_ id: AccountID, _ w: WindowKind, resetAt: Date) -> Bool {
        lock.withLock {
            freshReadingProof(id, w, resetAt: resetAt) || counterProof(id, resetAt: resetAt)
        }
    }

    public func unclassified(_ id: AccountID) -> [UnclassifiedReading] {
        lock.withLock { derived.unclassified[id] ?? [] }
    }

    // MARK: Writes (lock held)

    private func ingest(_ s: SourceSnapshot) {
        merge(s.readings)
        // A snapshot older than the one held for its source is late: its readings
        // still count (newest wins), its credential list and counters don't.
        if let held = snapshots[s.source], s.takenAt < held.takenAt { return }
        ingestAccounts(s)
        counters.record(at: s.takenAt, marks: Self.markValues(Self.counterMarks(from: s)))
    }

    private func ingestAccounts(_ s: SourceSnapshot) {
        snapshots[s.source] = s
        for a in s.accounts where a.requestCounter != nil {
            seenFiles[a.fileKey] = a.id
        }
    }

    private func merge(_ new: [SourceReading]) {
        for r in new {
            let key = ReadingKey(provider: r.provider, fileKey: r.fileKey, window: r.window)
            if let held = readings[key], !Self.isNewer(r, than: held) { continue }
            readings[key] = r
        }
    }

    private static func markValues(_ marks: [CounterMark]) -> [String: Int] {
        Dictionary(marks.map { ($0.fileKey, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// Newest `observedAt` wins. Ties break on a fixed order, ending with the lowest
    /// `fileKey`, so the result depends neither on the order readings arrive in (live
    /// apply vs. restore) nor on dictionary iteration order.
    private static func isNewer(_ a: SourceReading, than b: SourceReading) -> Bool {
        if a.observedAt != b.observedAt { return a.observedAt > b.observedAt }
        if a.source != b.source { return sourceRank(a.source) > sourceRank(b.source) }
        if a.usedPercent != b.usedPercent { return a.usedPercent > b.usedPercent }
        let aReset = a.resetsAt ?? .distantPast, bReset = b.resetsAt ?? .distantPast
        if aReset != bReset { return aReset > bReset }
        return a.fileKey < b.fileKey
    }

    private static func sourceRank(_ s: ReadingSource) -> Int {
        ReadingSource.allCases.firstIndex(of: s) ?? 0
    }

    // MARK: Resolution

    /// The account a credential file belongs to: its identity, replaced by the alias
    /// list entry for that file if there is one.
    private func resolve(_ raw: AccountID, fileKey: String) -> AccountID {
        guard let alias = settings.identityAliases[fileKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty
        else { return raw }
        return AccountID(provider: raw.provider, identity: alias)
    }

    private func recompute() {
        var d = Derived()
        var order: [AccountID] = []
        var groups: [AccountID: [AccountSnapshot]] = [:]

        for kind in SourceKind.allCases {
            guard let s = snapshots[kind] else { continue }
            for a in s.accounts {
                let file = FileRef(provider: a.id.provider, fileKey: a.fileKey)
                guard d.owner[file] == nil else { continue }   // a file listed twice
                let id = resolve(a.id, fileKey: a.fileKey)
                d.owner[file] = id
                if groups[id] == nil { order.append(id) }
                groups[id, default: []].append(a)
                if kind == .cliproxy, a.requestCounter != nil {
                    d.counterFiles[id, default: []].insert(a.fileKey)
                }
            }
            if let r = s.routing {
                let forced = r.forcedAccount.map { f in
                    s.accounts.first { $0.id == f }.map { resolve($0.id, fileKey: $0.fileKey) } ?? f
                }
                d.routing[kind] = RoutingConfig(strategy: r.strategy, sessionAffinity: r.sessionAffinity,
                                                forcedAccount: forced)
            }
        }

        // First sight assigns the alias, in source then listing order.
        let merged = order.map { id in Self.merge(id, groups[id] ?? [], alias: aliasEntry(id)) }
        d.accounts = merged.sorted {
            let p0 = Provider.allCases.firstIndex(of: $0.id.provider) ?? 0
            let p1 = Provider.allCases.firstIndex(of: $1.id.provider) ?? 0
            if p0 != p1 { return p0 < p1 }
            if $0.colorIndex != $1.colorIndex { return $0.colorIndex < $1.colorIndex }
            return $0.id.identity < $1.id.identity
        }

        for (key, r) in readings {
            guard let id = d.owner[FileRef(provider: key.provider, fileKey: key.fileKey)] else { continue }
            if let held = d.latest[id]?[key.window], !Self.isNewer(r, than: held) { continue }
            d.latest[id, default: [:]][key.window] = r
        }

        for kind in SourceKind.allCases {
            for u in snapshots[kind]?.unclassified ?? [] {
                guard let id = d.owner[FileRef(provider: u.provider, fileKey: u.fileKey)] else { continue }
                d.unclassified[id, default: []].append(u)
            }
        }
        for (id, list) in d.unclassified {
            d.unclassified[id] = list.sorted {
                ($0.fileKey, $0.observedAt, $0.lengthSeconds ?? -1)
                    < ($1.fileKey, $1.observedAt, $1.lengthSeconds ?? -1)
            }
        }

        derived = d
    }

    private static func merge(_ id: AccountID, _ files: [AccountSnapshot], alias: AliasEntry) -> MergedAccount {
        let sorted = files.sorted { $0.fileKey < $1.fileKey }
        let routes = sorted.map {
            CredentialRoute(fileKey: $0.fileKey, priority: $0.routing?.priority ?? 0,
                            weight: $0.routing?.weight ?? 1, enabled: $0.enabled,
                            unavailable: $0.unavailable)
        }
        let enabled = routes.filter(\.enabled)
        let unavailable: [Unavailability]
        if enabled.contains(where: { $0.unavailable.isEmpty }) {
            unavailable = []
        } else {
            // Why no credential can take traffic: the enabled ones' reasons, or every
            // file's reasons when none is enabled.
            var reasons: [Unavailability] = []
            for reason in (enabled.isEmpty ? routes : enabled).flatMap(\.unavailable)
            where !reasons.contains(reason) {
                reasons.append(reason)
            }
            unavailable = reasons
        }
        return MergedAccount(id: id, alias: alias.alias, email: sorted.lazy.compactMap(\.email).first,
                             enabled: !enabled.isEmpty, unavailable: unavailable,
                             credentials: routes, colorIndex: alias.colorIndex)
    }

    /// The stored alias and color, assigned by the store on first sight. A store
    /// failure gives a placeholder that isn't cached, so the next write retries. The
    /// placeholder never shows the identity, which can be an email.
    private func aliasEntry(_ id: AccountID) -> AliasEntry {
        if let cached = aliasCache[id] { return cached }
        guard let stored = try? store.alias(for: id) else {
            return AliasEntry(alias: "\(id.provider.rawValue)-?", colorIndex: 0)
        }
        let entry = AliasEntry(alias: stored.alias, colorIndex: stored.colorIndex)
        aliasCache[id] = entry
        return entry
    }

    // MARK: Reset proof (lock held)

    /// A reading of this window, from any of the account's files, observed at or
    /// after the reset and belonging to a later window: its reset is unset, or later
    /// than both `resetAt` and its own `observedAt`. A reading that still carries the
    /// old reset (a request that finished just after the reset) or that ends as it is
    /// observed (a Codex `Reset-After-Seconds: 0` with no `Reset-At`) proves nothing.
    /// For ocgo this is a fresh `ok` window; the account's `polledAt` alone proves
    /// nothing (E16).
    private func freshReadingProof(_ id: AccountID, _ w: WindowKind, resetAt: Date) -> Bool {
        guard let r = derived.latest[id]?[w], r.observedAt >= resetAt else { return false }
        return r.resetsAt.map { $0 > max(resetAt, r.observedAt) } ?? true
    }

    /// cliproxy: a listing before the reset and the latest listing, at or after it,
    /// hold the same set of the account's credential files, and each file's counter
    /// is the same at every listing between them. A file joining (E5e) or leaving the
    /// set, any use (E5b), or a restart (E5c, or E5d where another file's rise hides
    /// it) breaks the proof, as does no listing before the reset. Known limitation:
    /// after `restore()` (an app relaunch) the ledger knows file owners only from the
    /// last snapshots, so a file of a different account that left the list between the
    /// two listings also denies the proof (the window shows unknown where a running
    /// ledger would prove it), because `CounterMark` carries no owner.
    private func counterProof(_ id: AccountID, resetAt: Date) -> Bool {
        guard let current = counters.lastListing, current >= resetAt,
              let before = counters.lastListing(before: resetAt),
              let files = derived.counterFiles[id], !files.isEmpty
        else { return false }

        for fileKey in files {
            guard let run = counters.run(fileKey, endingAt: current), run.from <= before else {
                return false
            }
        }
        // Any other file listed in between denies the proof unless it is known to
        // belong to a different account. This fails closed: after a restore, a file
        // that has since left the credential list has no known owner.
        for fileKey in counters.fileKeys where !files.contains(fileKey) {
            guard counters.present(fileKey, from: before, to: current) else { continue }
            guard let raw = seenFiles[fileKey], resolve(raw, fileKey: fileKey) != id else {
                return false
            }
        }
        return true
    }
}

// MARK: - Private types

private struct ReadingKey: Hashable {
    let provider: Provider
    let fileKey: String
    let window: WindowKind
}

private struct FileRef: Hashable {
    let provider: Provider
    let fileKey: String
}

private struct AliasEntry {
    let alias: String
    let colorIndex: Int
}

private struct Derived {
    var accounts: [MergedAccount] = []
    var routing: [SourceKind: RoutingConfig] = [:]
    /// Credential file -> account, from the latest credential lists and the alias list.
    var owner: [FileRef: AccountID] = [:]
    var latest: [AccountID: [WindowKind: SourceReading]] = [:]
    var unclassified: [AccountID: [UnclassifiedReading]] = [:]
    /// The account's cliproxy files with a request counter in the latest listing.
    var counterFiles: [AccountID: Set<String>] = [:]
}
