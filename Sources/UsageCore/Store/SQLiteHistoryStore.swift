import Foundation
import SQLite3

/// `HistoryStore` on a SQLite file (plan.md "SQLite history (30 days)").
///
/// One connection, serialized by a lock, so any thread may call it. The file uses
/// WAL journaling.
///
/// Storage choices:
/// - Dates are REAL `timeIntervalSinceReferenceDate`, the Double a `Date` holds, so a
///   date read back is bit-for-bit the one written. The idempotency key
///   `(provider, fileKey, window, source, observedAt)` compares exactly what the
///   source produced, sub-second digits included.
/// - Enums are stored by raw value. Snapshots and fork provider states are JSON from
///   the contract types' `Codable`.
/// - Aliases are assigned per provider in first-sight order, and never pruned:
///   Claude and Codex get `claude-1`, `claude-2`, ... (plan.md "Alias and color"),
///   OpenCode Go keeps its account name (`team-a`, plan.md "Accounts by alias").
///   `colorIndex` counts from 0 per provider, because colors only need to differ
///   within one provider row.
public final class SQLiteHistoryStore: HistoryStore, @unchecked Sendable {
    /// plan.md: the history keeps 30 days.
    public static let defaultRetention: TimeInterval = 30 * 24 * 3600
    static let schemaVersion = 1

    private let lock = NSLock()
    private let connection: SQLiteConnection

    /// Opens or creates the database at `path`, then prunes rows older than
    /// `retention` before `now.now` (plan.md T5: "prunes rows older than 30 days on
    /// open"; the daily prune is the caller's timer calling `prune(olderThan:)`).
    /// Pass `retention: nil` to skip the prune on open.
    public init(path: String, now: any NowProvider = SystemNowProvider(),
                retention: TimeInterval? = SQLiteHistoryStore.defaultRetention) throws {
        connection = try SQLiteConnection(path: path)
        do {
            try connection.execute("PRAGMA journal_mode = WAL")
            try connection.execute("PRAGMA synchronous = NORMAL")
            try migrate()
            if let retention {
                try pruneLocked(olderThan: now.now.addingTimeInterval(-retention))
            }
        } catch {
            connection.close()
            throw error
        }
    }

    /// Closes the file. Later calls throw `HistoryStoreError.closed`. Also happens on
    /// deinit.
    public func close() {
        locked { connection.close() }
    }

    // MARK: Readings

    public func append(_ readings: [SourceReading]) throws {
        guard !readings.isEmpty else { return }
        try locked {
            try connection.transaction {
                // Same key, same observation: the first write wins.
                let insert = try connection.prepare("""
                    INSERT OR IGNORE INTO readings
                        (provider, file_key, window, source, observed_at, used_percent, resets_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """)
                for r in readings {
                    try insert.run([
                        .text(r.provider.rawValue), .text(r.fileKey), .text(r.window.rawValue),
                        .text(r.source.rawValue), Self.date(r.observedAt), .double(r.usedPercent),
                        r.resetsAt.map(Self.date) ?? .null,
                    ])
                }
            }
        }
    }

    /// Readings of the given files observed in `from...to` (both ends included),
    /// oldest first. An empty `fileKeys` matches nothing.
    public func readings(fileKeys: [String], _ w: WindowKind?, from: Date, to: Date) throws
        -> [SourceReading]
    {
        guard !fileKeys.isEmpty else { return [] }
        let keys = Array(Set(fileKeys))
        var sql = """
            SELECT \(Self.readingColumns) FROM readings
            WHERE file_key IN (\(Array(repeating: "?", count: keys.count).joined(separator: ", ")))
              AND observed_at >= ? AND observed_at <= ?
            """
        var values: [SQLiteStatement.Value] = keys.map { .text($0) }
        values += [Self.date(from), Self.date(to)]
        if let w {
            sql += " AND window = ?"
            values.append(.text(w.rawValue))
        }
        sql += " ORDER BY observed_at, provider, file_key, window, source"
        return try locked {
            try connection.prepare(sql).query(values, Self.reading)
        }
    }

    public func latestReadings() throws -> [SourceReading] {
        // SQLite fills the bare columns from the row that holds MAX(observed_at).
        try locked {
            try connection.prepare("""
                SELECT provider, file_key, window, source, MAX(observed_at), used_percent, resets_at
                FROM readings
                GROUP BY provider, file_key, window, source
                ORDER BY provider, file_key, window, source
                """).query([], Self.reading)
        }
    }

    public func lastObservation(_ p: Provider, source: ReadingSource) throws -> Date? {
        try locked {
            try connection.prepare(
                "SELECT MAX(observed_at) FROM readings WHERE provider = ? AND source = ?"
            ).query([.text(p.rawValue), .text(source.rawValue)]) { row in
                row.optionalDouble(0).map(Date.init(timeIntervalSinceReferenceDate:))
            }.first ?? nil
        }
    }

    // MARK: Counter marks

    public func appendCounterMarks(_ marks: [CounterMark]) throws {
        guard !marks.isEmpty else { return }
        try locked {
            try connection.transaction {
                let insert = try connection.prepare(
                    "INSERT OR REPLACE INTO counter_marks (file_key, at, value) VALUES (?, ?, ?)")
                for m in marks {
                    try insert.run([.text(m.fileKey), Self.date(m.at), .int(Int64(m.value))])
                }
            }
        }
    }

    /// Marks at or after `since`, oldest first.
    public func counterMarks(since: Date) throws -> [CounterMark] {
        try locked {
            try connection.prepare(
                "SELECT file_key, at, value FROM counter_marks WHERE at >= ? ORDER BY at, file_key"
            ).query([Self.date(since)]) { row in
                CounterMark(fileKey: row.text(0),
                            at: Date(timeIntervalSinceReferenceDate: row.double(1)),
                            value: Int(row.int(2)))
            }
        }
    }

    // MARK: Snapshots

    /// Replaces the source's stored snapshot only when `s.takenAt` is later than the
    /// stored one's. A late or repeated snapshot (same or earlier `takenAt`) is
    /// ignored, so the store keeps the newest poll, as the ledger does. The whole
    /// snapshot is kept as the source returned it, readings included.
    public func saveLastSnapshot(_ s: SourceSnapshot) throws {
        let json = try JSONEncoder().encode(s)
        try locked {
            try connection.prepare("""
                INSERT INTO last_snapshots (source, taken_at, json) VALUES (?, ?, ?)
                ON CONFLICT (source) DO UPDATE SET taken_at = excluded.taken_at, json = excluded.json
                WHERE excluded.taken_at > last_snapshots.taken_at
                """
            ).run([.text(s.source.rawValue), Self.date(s.takenAt), .blob(json)])
        }
    }

    public func lastSnapshots() throws -> [SourceSnapshot] {
        let blobs = try locked {
            try connection.prepare("SELECT json FROM last_snapshots ORDER BY source")
                .query([]) { $0.blob(0) }
        }
        let decoder = JSONDecoder()
        return try blobs.map { try decoder.decode(SourceSnapshot.self, from: $0) }
    }

    // MARK: Aliases

    public func alias(for id: AccountID) throws -> (alias: String, colorIndex: Int) {
        try locked {
            try connection.transaction {
                let existing = try connection.prepare(
                    "SELECT alias, color_index FROM aliases WHERE provider = ? AND identity = ?"
                ).query([.text(id.provider.rawValue), .text(id.identity)]) { row in
                    (row.text(0), Int(row.int(1)))
                }
                if let found = existing.first { return (alias: found.0, colorIndex: found.1) }

                let next = try connection.prepare(
                    "SELECT COALESCE(MAX(color_index) + 1, 0) FROM aliases WHERE provider = ?"
                ).query([.text(id.provider.rawValue)]) { Int($0.int(0)) }.first ?? 0
                let alias = id.provider == .go ? id.identity : "\(id.provider.rawValue)-\(next + 1)"
                try connection.prepare(
                    "INSERT INTO aliases (provider, identity, alias, color_index) VALUES (?, ?, ?, ?)"
                ).run([.text(id.provider.rawValue), .text(id.identity), .text(alias), .int(Int64(next))])
                return (alias: alias, colorIndex: next)
            }
        }
    }

    // MARK: Fork provider states

    /// Replaces the stored states with `s`.
    public func saveForkProviderStates(_ s: [Provider: ForkProviderState]) throws {
        let json = try JSONEncoder().encode(s)
        try locked { try setMeta(Self.forkStatesKey, .blob(json)) }
    }

    /// Empty until the first save.
    public func forkProviderStates() throws -> [Provider: ForkProviderState] {
        guard let json = try locked({ try meta(Self.forkStatesKey) }) else { return [:] }
        return try JSONDecoder().decode([Provider: ForkProviderState].self, from: json)
    }

    // MARK: Gaps

    public func recordGap(from: Date, to: Date) throws {
        guard to >= from else { throw HistoryStoreError.invalidGap }
        try locked {
            try connection.prepare("INSERT OR IGNORE INTO gaps (started_at, ended_at) VALUES (?, ?)")
                .run([Self.date(from), Self.date(to)])
        }
    }

    /// Gaps that end at or after `since`, oldest first.
    public func gaps(since: Date) throws -> [DateInterval] {
        try locked {
            try connection.prepare(
                "SELECT started_at, ended_at FROM gaps WHERE ended_at >= ? ORDER BY started_at, ended_at"
            ).query([Self.date(since)]) { row in
                DateInterval(start: Date(timeIntervalSinceReferenceDate: row.double(0)),
                             end: Date(timeIntervalSinceReferenceDate: row.double(1)))
            }
        }
    }

    // MARK: Pruning

    /// Deletes readings and counter marks from before `olderThan`, and gaps that ended
    /// before it. Aliases, last snapshots and meta are kept.
    public func prune(olderThan: Date) throws {
        try locked { try pruneLocked(olderThan: olderThan) }
    }

    private func pruneLocked(olderThan cutoff: Date) throws {
        try connection.transaction {
            let at = Self.date(cutoff)
            try connection.prepare("DELETE FROM readings WHERE observed_at < ?").run([at])
            try connection.prepare("DELETE FROM counter_marks WHERE at < ?").run([at])
            try connection.prepare("DELETE FROM gaps WHERE ended_at < ?").run([at])
        }
    }

    // MARK: Schema

    private static let schemaKey = "schema_version"
    private static let forkStatesKey = "fork_provider_states"

    private func migrate() throws {
        try connection.transaction {
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value BLOB NOT NULL
                );
                """)
            let found = try meta(Self.schemaKey)
                .flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            if found > Self.schemaVersion {
                throw HistoryStoreError.newerSchema(found: found, supported: Self.schemaVersion)
            }
            if found < 1 {
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS readings (
                        provider TEXT NOT NULL,
                        file_key TEXT NOT NULL,
                        window TEXT NOT NULL,
                        source TEXT NOT NULL,
                        observed_at REAL NOT NULL,
                        used_percent REAL NOT NULL,
                        resets_at REAL,
                        PRIMARY KEY (provider, file_key, window, source, observed_at)
                    ) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS readings_observed_at ON readings (observed_at);
                    CREATE INDEX IF NOT EXISTS readings_file_key ON readings (file_key, observed_at);
                    CREATE INDEX IF NOT EXISTS readings_provider_source
                        ON readings (provider, source, observed_at);
                    CREATE TABLE IF NOT EXISTS counter_marks (
                        file_key TEXT NOT NULL,
                        at REAL NOT NULL,
                        value INTEGER NOT NULL,
                        PRIMARY KEY (file_key, at)
                    ) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS counter_marks_at ON counter_marks (at);
                    CREATE TABLE IF NOT EXISTS aliases (
                        provider TEXT NOT NULL,
                        identity TEXT NOT NULL,
                        alias TEXT NOT NULL,
                        color_index INTEGER NOT NULL,
                        PRIMARY KEY (provider, identity)
                    ) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS last_snapshots (
                        source TEXT PRIMARY KEY NOT NULL,
                        taken_at REAL NOT NULL,
                        json BLOB NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS gaps (
                        started_at REAL NOT NULL,
                        ended_at REAL NOT NULL,
                        PRIMARY KEY (started_at, ended_at)
                    ) WITHOUT ROWID;
                    """)
            }
            if found != Self.schemaVersion {
                try setMeta(Self.schemaKey, .blob(Data(String(Self.schemaVersion).utf8)))
            }
        }
    }

    private func meta(_ key: String) throws -> Data? {
        try connection.prepare("SELECT value FROM meta WHERE key = ?")
            .query([.text(key)]) { $0.blob(0) }.first
    }

    private func setMeta(_ key: String, _ value: SQLiteStatement.Value) throws {
        try connection.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
            .run([.text(key), value])
    }

    // MARK: Helpers

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func date(_ d: Date) -> SQLiteStatement.Value {
        .double(d.timeIntervalSinceReferenceDate)
    }

    private static let readingColumns =
        "provider, file_key, window, source, observed_at, used_percent, resets_at"

    /// Maps a row in `readingColumns` order. Rows with an enum value this build
    /// doesn't know are a schema error.
    private static func reading(_ row: SQLiteRow) throws -> SourceReading {
        guard let provider = Provider(rawValue: row.text(0)),
              let window = WindowKind(rawValue: row.text(2)),
              let source = ReadingSource(rawValue: row.text(3))
        else {
            throw HistoryStoreError.sqlite(
                code: SQLITE_MISMATCH,
                message: "unknown reading key \(row.text(0))/\(row.text(2))/\(row.text(3))")
        }
        return SourceReading(
            provider: provider, fileKey: row.text(1), window: window,
            usedPercent: row.double(5),
            resetsAt: row.optionalDouble(6).map(Date.init(timeIntervalSinceReferenceDate:)),
            observedAt: Date(timeIntervalSinceReferenceDate: row.double(4)),
            source: source)
    }
}
