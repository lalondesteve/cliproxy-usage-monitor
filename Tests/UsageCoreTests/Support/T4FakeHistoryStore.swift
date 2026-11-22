import Foundation
import UsageCore

/// In-memory `HistoryStore` for the T4 ledger tests (the SQLite store is T5).
/// Follows the contract comments: idempotent appends on
/// (provider, fileKey, window, source, observedAt), one last snapshot per source,
/// newest reading per (provider, fileKey, window, source), aliases assigned on first
/// sight per provider (`claude-1`, `claude-2`, ...).
final class T4FakeHistoryStore: HistoryStore, @unchecked Sendable {
    private struct ReadingKey: Hashable {
        let provider: Provider
        let fileKey: String
        let window: WindowKind
        let source: ReadingSource
        let observedAt: Date
    }

    private let lock = NSLock()
    private var rows: [ReadingKey: SourceReading] = [:]
    private var marks: [CounterMark] = []
    private var snapshots: [SourceKind: SourceSnapshot] = [:]
    private var aliases: [AccountID: (alias: String, colorIndex: Int)] = [:]
    private var forkStates: [Provider: ForkProviderState] = [:]
    private var gapList: [DateInterval] = []
    private var _aliasCalls = 0
    private var _failAliases = false

    var aliasCalls: Int { lock.withLock { _aliasCalls } }
    /// When true, `alias(for:)` throws.
    var failAliases: Bool {
        get { lock.withLock { _failAliases } }
        set { lock.withLock { _failAliases = newValue } }
    }

    struct AliasFailure: Error {}

    func append(_ readings: [SourceReading]) throws {
        lock.withLock {
            for r in readings {
                rows[ReadingKey(provider: r.provider, fileKey: r.fileKey, window: r.window,
                                source: r.source, observedAt: r.observedAt)] = r
            }
        }
    }

    func appendCounterMarks(_ new: [CounterMark]) throws {
        lock.withLock { marks.append(contentsOf: new) }
    }

    func saveLastSnapshot(_ s: SourceSnapshot) throws {
        lock.withLock { snapshots[s.source] = s }
    }

    func lastSnapshots() throws -> [SourceSnapshot] {
        lock.withLock { SourceKind.allCases.compactMap { snapshots[$0] } }
    }

    func readings(fileKeys: [String], _ w: WindowKind?, from: Date, to: Date) throws -> [SourceReading] {
        lock.withLock {
            rows.values
                .filter { fileKeys.contains($0.fileKey) && (w == nil || $0.window == w)
                    && $0.observedAt >= from && $0.observedAt <= to }
                .sorted { $0.observedAt < $1.observedAt }
        }
    }

    func latestReadings() throws -> [SourceReading] {
        lock.withLock {
            var newest: [String: SourceReading] = [:]
            for r in rows.values {
                let key = "\(r.provider)|\(r.fileKey)|\(r.window)|\(r.source)"
                if let held = newest[key], held.observedAt >= r.observedAt { continue }
                newest[key] = r
            }
            return Array(newest.values)
        }
    }

    func counterMarks(since: Date) throws -> [CounterMark] {
        lock.withLock { marks.filter { $0.at >= since } }
    }

    func alias(for id: AccountID) throws -> (alias: String, colorIndex: Int) {
        try lock.withLock {
            _aliasCalls += 1
            if _failAliases { throw AliasFailure() }
            if let held = aliases[id] { return held }
            let n = aliases.keys.filter { $0.provider == id.provider }.count
            let entry = (alias: "\(id.provider.rawValue)-\(n + 1)", colorIndex: n)
            aliases[id] = entry
            return entry
        }
    }

    func lastObservation(_ p: Provider, source: ReadingSource) throws -> Date? {
        lock.withLock {
            rows.values.filter { $0.provider == p && $0.source == source }.map(\.observedAt).max()
        }
    }

    func saveForkProviderStates(_ s: [Provider: ForkProviderState]) throws {
        lock.withLock { forkStates = s }
    }

    func forkProviderStates() throws -> [Provider: ForkProviderState] {
        lock.withLock { forkStates }
    }

    func recordGap(from: Date, to: Date) throws {
        lock.withLock { gapList.append(DateInterval(start: from, end: to)) }
    }

    func gaps(since: Date) throws -> [DateInterval] {
        lock.withLock { gapList.filter { $0.end >= since } }
    }

    func prune(olderThan: Date) throws {
        lock.withLock {
            rows = rows.filter { $0.value.observedAt >= olderThan }
            marks.removeAll { $0.at < olderThan }
        }
    }
}

/// Plays T8's part for one snapshot: persist what the source returned, then apply it.
func t4PersistAndApply(_ s: SourceSnapshot, store: T4FakeHistoryStore, ledger: Ledger) throws {
    try store.append(s.readings)
    try store.appendCounterMarks(Ledger.counterMarks(from: s))
    try store.saveLastSnapshot(s)
    ledger.apply(s)
}

/// Plays T8's part for fork `current` readings.
func t4PersistAndApply(readings: [SourceReading], store: T4FakeHistoryStore, ledger: Ledger) throws {
    try store.append(readings)
    ledger.apply(readings: readings)
}
