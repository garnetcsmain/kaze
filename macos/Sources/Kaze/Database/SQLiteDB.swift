import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { "SQLite error: \(message)" }
}

/// A row returned from a query. Column access is by name.
struct SQLRow {
    fileprivate var values: [String: Any] = [:]

    func int(_ column: String) -> Int64? {
        switch values[column] {
        case let v as Int64: return v
        case let v as Double: return Int64(v)
        default: return nil
        }
    }

    func double(_ column: String) -> Double? {
        switch values[column] {
        case let v as Double: return v
        case let v as Int64: return Double(v)
        default: return nil
        }
    }

    func string(_ column: String) -> String? {
        values[column] as? String
    }
}

/// Thin thread-safe wrapper over the SQLite C API.
/// All access is serialized through an internal queue — services and UI share one connection (WAL mode).
final class SQLiteDB {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "kaze.db")

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open"
            sqlite3_close(handle)
            throw SQLiteError(message: msg)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
    }

    func close() {
        queue.sync {
            if let db { sqlite3_close_v2(db) }
            db = nil
        }
    }

    var isOpen: Bool { queue.sync { db != nil } }

    // MARK: - Public API (each call runs on the serial queue)

    @discardableResult
    func execute(_ sql: String, _ params: [Any?] = []) throws -> Int {
        try queue.sync { try executeLocked(sql, params) }
    }

    func query(_ sql: String, _ params: [Any?] = []) throws -> [SQLRow] {
        try queue.sync { try queryLocked(sql, params) }
    }

    func lastInsertRowID() -> Int64 {
        queue.sync { db.map { sqlite3_last_insert_rowid($0) } ?? 0 }
    }

    /// Variant for use inside a `transaction` body, which already runs on the serial queue
    /// (the public `lastInsertRowID` would deadlock there — the queue is not reentrant).
    func lastInsertRowIDLocked() -> Int64 {
        db.map { sqlite3_last_insert_rowid($0) } ?? 0
    }

    /// Run several statements atomically. The block receives locked variants — do not call
    /// the public API from inside it (the queue is not reentrant).
    func transaction<T>(_ body: (_ exec: (String, [Any?]) throws -> Int, _ query: (String, [Any?]) throws -> [SQLRow]) throws -> T) throws -> T {
        try queue.sync {
            _ = try executeLocked("BEGIN IMMEDIATE TRANSACTION", [])
            do {
                let result = try body(
                    { sql, params in try self.executeLocked(sql, params) },
                    { sql, params in try self.queryLocked(sql, params) }
                )
                _ = try executeLocked("COMMIT", [])
                return result
            } catch {
                _ = try? executeLocked("ROLLBACK", [])
                throw error
            }
        }
    }

    // MARK: - Internals

    @discardableResult
    private func executeLocked(_ sql: String, _ params: [Any?]) throws -> Int {
        guard let db else { throw SQLiteError(message: "database closed") }
        let stmt = try prepare(db, sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    private func queryLocked(_ sql: String, _ params: [Any?]) throws -> [SQLRow] {
        guard let db else { throw SQLiteError(message: "database closed") }
        let stmt = try prepare(db, sql, params)
        defer { sqlite3_finalize(stmt) }

        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
            }
            var row = SQLRow()
            let count = sqlite3_column_count(stmt)
            for i in 0..<count {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.values[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: row.values[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row.values[name] = String(cString: sqlite3_column_text(stmt, i))
                default: break // NULL and BLOB (unused) -> absent
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func prepare(_ db: OpaquePointer, _ sql: String, _ params: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: "\(String(cString: sqlite3_errmsg(db))) — in: \(sql.prefix(120))")
        }
        for (index, param) in params.enumerated() {
            let i = Int32(index + 1)
            switch param {
            case nil: sqlite3_bind_null(stmt, i)
            case let v as Int: sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, i, v)
            case let v as Int32: sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, i, v)
            case let v as Float: sqlite3_bind_double(stmt, i, Double(v))
            case let v as Bool: sqlite3_bind_int64(stmt, i, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            default:
                sqlite3_finalize(stmt)
                throw SQLiteError(message: "unsupported bind type at index \(index)")
            }
        }
        return stmt
    }
}
