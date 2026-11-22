import Foundation
import SQLite3
import Synchronization

/// A SQLite file with the bare necessities around it: execute statements, bind values,
/// read rows — for the ``CatalogIndex``.
///
/// A lock around the one connection: queries come from the main thread (one page of the
/// grid, a few milliseconds) and from the sync in the background; SQLite itself is
/// opened in "serialized" mode, the lock keeps related steps (transaction,
/// prepared statement including reading) together.
final class Database: @unchecked Sendable {

    enum Failure: Error, CustomStringConvertible {
        case openFailed(String)
        case statement(String, String)

        var description: String {
            switch self {
            case .openFailed(let text): "SQLite open: \(text)"
            case .statement(let sql, let text): "SQLite \(text) — \(sql.prefix(80))"
            }
        }
    }

    /// A value to bind.
    enum Value {
        case text(String)
        case integer(Int64)
        case decimalNumber(Double)
        case data(Data)
        case null

        static func text(_ s: String?) -> Value { s.map { .text($0) } ?? .null }
        static func integer(_ i: Int?) -> Value { i.map { .integer(Int64($0)) } ?? .null }
        static func decimalNumber(_ d: Double?) -> Value { d.map { .decimalNumber($0) } ?? .null }
    }

    /// A row that was read — columns by position.
    struct Row {
        fileprivate let statement: OpaquePointer

        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(statement, i) else { return nil }
            return String(cString: c)
        }
        func integer(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
        func decimalNumber(_ i: Int32) -> Double? {
            sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : sqlite3_column_double(statement, i)
        }
        func data(_ i: Int32) -> Data? {
            guard let pointer = sqlite3_column_blob(statement, i) else { return nil }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, i)))
        }
    }

    private let lock = Mutex(())
    private let db: OpaquePointer

    /// - Parameter file: `nil` keeps everything in memory (tests).
    init(file: URL?) throws {
        var pointer: OpaquePointer?
        if let file {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let path = file?.path ?? ":memory:"
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let text = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            if let pointer { sqlite3_close(pointer) }
            throw Failure.openFailed(text)
        }
        db = pointer
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = OFF")
    }

    deinit { sqlite3_close(db) }

    /// Several statements without values.
    func execute(_ sql: String) throws {
        try lock.withLock { _ in try executeUnlocked(sql) }
    }

    private func executeUnlocked(_ sql: String) throws {
        var failure: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &failure) == SQLITE_OK else {
            let text = failure.map { String(cString: $0) } ?? "?"
            sqlite3_free(failure)
            throw Failure.statement(sql, text)
        }
    }

    /// One statement with values, without a result.
    func write(_ sql: String, _ values: [Value] = []) throws {
        try lock.withLock { _ in try writeUnlocked(sql, values) }
    }

    /// One statement, one result per row.
    func query<T>(_ sql: String, _ values: [Value] = [], _ line: (Row) throws -> T) throws -> [T] {
        try lock.withLock { _ in
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(values, to: statement, sql: sql)
            var result: [T] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW {
                    result.append(try line(Row(statement: statement)))
                } else if step == SQLITE_DONE {
                    return result
                } else {
                    throw Failure.statement(sql, String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }

    /// Many write steps in one transaction — an extract with 35,000 titles in one
    /// instead of 35,000 transactions.
    func transaction(_ steps: (Writer) throws -> Void) throws {
        try lock.withLock { _ in
            try executeUnlocked("BEGIN IMMEDIATE")
            do {
                let writer = Writer(database: self)
                defer { writer.close() }
                try steps(writer)
                try executeUnlocked("COMMIT")
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    /// Writes within a transaction and reuses prepared statements.
    final class Writer {
        fileprivate let database: Database
        private var prepared: [String: OpaquePointer] = [:]

        fileprivate init(database: Database) { self.database = database }

        func write(_ sql: String, _ values: [Value] = []) throws {
            let statement: OpaquePointer
            if let existing = prepared[sql] {
                statement = existing
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            } else {
                statement = try database.prepare(sql)
                prepared[sql] = statement
            }
            try database.bind(values, to: statement, sql: sql)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw Failure.statement(sql, String(cString: sqlite3_errmsg(database.db)))
            }
        }

        fileprivate func close() {
            for statement in prepared.values { sqlite3_finalize(statement) }
            prepared.removeAll()
        }
    }

    private func writeUnlocked(_ sql: String, _ values: [Value]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, sql: sql)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure.statement(sql, String(cString: sqlite3_errmsg(db)))
        }
    }

    fileprivate func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.statement(sql, String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    /// SQLite copies text and data immediately (`SQLITE_TRANSIENT`).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate func bind(_ values: [Value], to statement: OpaquePointer, sql: String) throws {
        for (spot, value) in values.enumerated() {
            let i = Int32(spot + 1)
            let result: Int32
            switch value {
            case .text(let s): result = sqlite3_bind_text(statement, i, s, -1, Database.transient)
            case .integer(let z): result = sqlite3_bind_int64(statement, i, z)
            case .decimalNumber(let d): result = sqlite3_bind_double(statement, i, d)
            case .data(let d):
                result = d.withUnsafeBytes {
                    sqlite3_bind_blob(statement, i, $0.baseAddress, Int32(d.count), Database.transient)
                }
            case .null: result = sqlite3_bind_null(statement, i)
            }
            guard result == SQLITE_OK else {
                throw Failure.statement(sql, String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}
