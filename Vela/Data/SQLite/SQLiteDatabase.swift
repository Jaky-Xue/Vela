//
//  SQLiteDatabase.swift
//  Vela
//
//  Thin SQLite wrapper used by the data layer.
//
//  iOS ships SQLite as a system library, so this talks to `sqlite3` directly
//  rather than taking on a third-party wrapper. The table definitions, column
//  names and indexes in `BrowserSchema.swift` are the contract it serves, so a
//  schema change and the queries against it move together.
//

import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` tells SQLite to copy the bound buffer. The C macro is not
/// importable into Swift, so it is re-declared here.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, LocalizedError {
    case openFailed(path: String, message: String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(sql: String, message: String)
    case bindFailed(index: Int32, message: String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case let .openFailed(path, message):
            return "无法打开数据库 \(path)：\(message)"
        case let .prepareFailed(sql, message):
            return "SQL 编译失败：\(message)\n\(sql)"
        case let .stepFailed(sql, message):
            return "SQL 执行失败：\(message)\n\(sql)"
        case let .bindFailed(index, message):
            return "参数绑定失败（第 \(index) 个）：\(message)"
        case .notOpen:
            return "数据库尚未打开。"
        }
    }
}

/// A value that can be bound to or read from a SQLite column.
public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var intValue: Int64? {
        switch self {
        case let .integer(value): return value
        case let .real(value): return Int64(value)
        case let .text(value): return Int64(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .integer(value): return Double(value)
        case let .real(value): return value
        case let .text(value): return Double(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case let .text(value): return value
        case let .integer(value): return String(value)
        case let .real(value): return String(value)
        default: return nil
        }
    }

    public var dataValue: Data? {
        if case let .blob(value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// A single prepared statement. Created through `SQLiteDatabase.prepare`.
///
/// Statements are short-lived and explicitly finalised; the data layer issues
/// small queries rather than holding cursors open, which keeps the wrapper free
/// of the statement-cache complexity a long-lived connection would need.
public final class SQLiteStatement {
    fileprivate let handle: OpaquePointer

    fileprivate init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// Binds `values` positionally. Binding is 1-based in the C API.
    @discardableResult
    public func bind(_ values: [SQLiteValue]) throws -> SQLiteStatement {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(handle, index)
            case let .integer(number):
                status = sqlite3_bind_int64(handle, index, number)
            case let .real(number):
                status = sqlite3_bind_double(handle, index, number)
            case let .text(string):
                status = sqlite3_bind_text(handle, index, string, -1, sqliteTransient)
            case let .blob(data):
                if data.isEmpty {
                    status = sqlite3_bind_zeroblob(handle, index, 0)
                } else {
                    status = data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(
                            handle,
                            index,
                            buffer.baseAddress,
                            Int32(buffer.count),
                            sqliteTransient
                        )
                    }
                }
            }
            guard status == SQLITE_OK else {
                throw SQLiteError.bindFailed(
                    index: index,
                    message: String(cString: sqlite3_errstr(status))
                )
            }
        }
        return self
    }

    /// Runs the statement to completion, discarding any rows.
    public func step() throws {
        let status = sqlite3_step(handle)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw SQLiteError.stepFailed(
                sql: String(cString: sqlite3_sql(handle)),
                message: lastErrorMessage
            )
        }
    }

    /// Steps once. Returns true when a row is available.
    @discardableResult
    public func stepRow() throws -> Bool {
        let status = sqlite3_step(handle)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw SQLiteError.stepFailed(
            sql: String(cString: sqlite3_sql(handle)),
            message: lastErrorMessage
        )
    }

    private var lastErrorMessage: String {
        guard let connection = sqlite3_db_handle(handle), let cString = sqlite3_errmsg(connection) else {
            return "未知错误"
        }
        return String(cString: cString)
    }

    /// Reads a column by index. Column indexes are 0-based in the C API.
    public func value(at index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(handle, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(handle, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(handle, index))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(handle, index))
            guard count > 0, let pointer = sqlite3_column_blob(handle, index) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: count))
        default:
            guard let cString = sqlite3_column_text(handle, index) else { return .text("") }
            return .text(String(cString: cString))
        }
    }

    public func string(at index: Int32) -> String {
        value(at: index).stringValue ?? ""
    }

    public func optionalString(at index: Int32) -> String? {
        let value = value(at: index)
        return value.isNull ? nil : value.stringValue
    }

    public func int(at index: Int32) -> Int64 {
        value(at: index).intValue ?? 0
    }

    public func optionalInt(at index: Int32) -> Int64? {
        let value = value(at: index)
        return value.isNull ? nil : value.intValue
    }

    public func double(at index: Int32) -> Double {
        value(at: index).doubleValue ?? 0
    }

    public func bool(at index: Int32) -> Bool {
        int(at: index) != 0
    }

    /// Reads the whole result set of a query.
    public func rows() throws -> [[SQLiteValue]] {
        var collected: [[SQLiteValue]] = []
        while try stepRow() {
            let count = sqlite3_column_count(handle)
            collected.append((0..<count).map { value(at: $0) })
        }
        return collected
    }
}

/// A serialised SQLite connection.
///
/// Access is serialised with a recursive lock rather than a `DispatchQueue`.
/// A queue would be the obvious choice, but `transaction` has to hold the
/// serialisation point across the caller's closure, and that closure calls back
/// into `execute`/`query` — with a queue those nested `sync` calls would
/// deadlock, and splitting the API into locked and unlocked variants leaks the
/// distinction into every caller. A recursive lock lets the same thread re-enter
/// while still excluding other threads, which is exactly the requirement.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &connection, flags, nil)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close_v2(connection)
            throw SQLiteError.openFailed(path: path, message: message)
        }
        self.handle = connection

        // Write-ahead logging plus relaxed synchronisation is the standard
        // pairing for an app-local database and matches the durability profile of
        // a `relationalStore` configured for the default security level.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    private func withHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let handle else { throw SQLiteError.notOpen }
        return try body(handle)
    }

    /// Runs one or more statements with no result rows.
    public func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        try withHandle { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteError.prepareFailed(
                    sql: sql,
                    message: String(cString: sqlite3_errmsg(connection))
                )
            }
            // `SQLiteStatement` owns the handle and finalises it in its `deinit`.
            // Finalising here as well frees the same statement twice, which
            // segfaults inside libsqlite3 on the second call.
            let wrapped = SQLiteStatement(handle: statement)
            try wrapped.bind(values)
            try wrapped.step()
        }
    }

    /// Runs a statement that yields rows and maps each one.
    public func query<T>(
        _ sql: String,
        _ values: [SQLiteValue] = [],
        row: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return try withHandle { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteError.prepareFailed(
                    sql: sql,
                    message: String(cString: sqlite3_errmsg(connection))
                )
            }
            // `SQLiteStatement` owns the handle and finalises it in its `deinit`.
            // Finalising here as well frees the same statement twice, which
            // segfaults inside libsqlite3 on the second call.
            let wrapped = SQLiteStatement(handle: statement)
            try wrapped.bind(values)
            var collected: [T] = []
            while try wrapped.stepRow() {
                collected.append(try row(wrapped))
            }
            return collected
        }
    }

    /// Wraps `body` in a transaction, rolling back on any thrown error.
    ///
    /// The lock is held for the whole transaction, so no other thread's
    /// statement can land between `BEGIN` and `COMMIT` and be committed or
    /// rolled back by this transaction by accident.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Runs a statement that returns a single scalar integer.
    public func scalarInt(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64 {
        try query(sql, values) { $0.int(at: 0) }.first ?? 0
    }
}
