import Foundation
import SQLite3

public enum HistoryStoreError: Error, Equatable, Sendable {
    case sqlite(code: Int32, message: String)
    /// The store was closed; reopen it with a new instance.
    case closed
    /// The file was written by a newer version of the app.
    case newerSchema(found: Int, supported: Int)
    /// `recordGap(from:to:)` with `to` before `from`.
    case invalidGap
}

/// SQLITE_TRANSIENT: SQLite copies bound text and blobs before the call returns.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin wrapper over one sqlite3 connection. Not thread-safe; the store serializes
/// every call.
final class SQLiteConnection {
    private var db: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(handle)
            throw HistoryStoreError.sqlite(code: rc, message: message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { close() }

    var isOpen: Bool { db != nil }

    func close() {
        guard let db else { return }
        sqlite3_close_v2(db)
        self.db = nil
    }

    func execute(_ sql: String) throws {
        let handle = try open()
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw HistoryStoreError.sqlite(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        let handle = try open()
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw HistoryStoreError.sqlite(code: rc, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(stmt, db: handle)
    }

    /// Runs `body` in one write transaction; rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func open() throws -> OpaquePointer {
        guard let db else { throw HistoryStoreError.closed }
        return db
    }
}

/// A prepared statement. Bind indexes start at 1, column indexes at 0.
final class SQLiteStatement {
    private let stmt: OpaquePointer
    private let db: OpaquePointer

    fileprivate init(_ stmt: OpaquePointer, db: OpaquePointer) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    enum Value {
        case int(Int64), double(Double), text(String), blob(Data), null
    }

    /// Resets the statement and binds `values` in order.
    func bind(_ values: [Value]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .int(let v): rc = sqlite3_bind_int64(stmt, i, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, i, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, i, v, -1, transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(stmt, i, buffer.baseAddress, Int32(buffer.count), transient)
                }
            case .null: rc = sqlite3_bind_null(stmt, i)
            }
            try check(rc)
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ values: [Value] = []) throws {
        try bind(values)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw error(rc) }
    }

    /// Runs a query and maps each row.
    func query<T>(_ values: [Value] = [], _ row: (SQLiteRow) throws -> T) throws -> [T] {
        try bind(values)
        var result: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            result.append(try row(SQLiteRow(stmt: stmt)))
        }
        return result
    }

    private func check(_ rc: Int32) throws {
        if rc != SQLITE_OK { throw error(rc) }
    }

    private func error(_ rc: Int32) -> HistoryStoreError {
        .sqlite(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }
}

struct SQLiteRow {
    fileprivate let stmt: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func optionalDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }

    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    func blob(_ i: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, i))
        guard count > 0, let bytes = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
