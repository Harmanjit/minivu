import Foundation
import SQLite3

/// A value SQLite stores. SQLite has exactly these five storage classes.
public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// One result row, read by column name.
public struct SQLiteRow: Sendable {
    /// Shared by every row of a query result. Swift dictionaries are
    /// copy-on-write, so a thousand rows hold one copy, not a thousand.
    let columns: [String: Int]
    let values: [SQLiteValue]

    /// `.null` for a NULL value or a column the query didn't select.
    public subscript(_ column: String) -> SQLiteValue {
        guard let index = columns[column] else { return .null }
        return values[index]
    }

    public func int(_ c: String) -> Int64? {
        switch self[c] {
        case .integer(let v): v
        case .real(let v): Int64(exactly: v.rounded(.towardZero))
        default: nil
        }
    }

    public func double(_ c: String) -> Double? {
        switch self[c] {
        case .real(let v): v
        case .integer(let v): Double(v)
        default: nil
        }
    }

    public func string(_ c: String) -> String? {
        if case .text(let v) = self[c] { return v }
        return nil
    }

    public func data(_ c: String) -> Data? {
        switch self[c] {
        case .blob(let v): v
        case .text(let v): Data(v.utf8)
        default: nil
        }
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    /// The SQLite result code (SQLITE_BUSY, SQLITE_CONSTRAINT...).
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        sql.map { "SQLite error \(code): \(message) in \($0)" } ?? "SQLite error \(code): \(message)"
    }
}

/// A thin wrapper over the SQLite C library that ships with macOS.
///
/// Used by the thumbnail cache and the catalog (DESIGN.md 4.5, 4.6). It
/// exists so the rest of minivu never sees an `OpaquePointer`, and does only
/// three things beyond calling C: it caches compiled statements, it
/// serialises access from many threads, and it nests transactions.
///
/// **Threads.** One connection, one recursive lock around every call. The
/// connection is opened without SQLite's own mutex (`NOMUTEX`) because the
/// lock already guarantees one caller at a time; taking two locks per call
/// would be wasted work. The lock is recursive so a `transaction` body can
/// call `execute` and `query`.
///
/// **Statement cache.** Compiling SQL is most of the cost of a small query.
/// Each distinct SQL string is compiled once and kept, so pass values as
/// `?` arguments rather than building SQL strings with values in them.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var statements: [String: OpaquePointer] = [:]
    private var transactionDepth = 0

    /// SQLITE_TRANSIENT: SQLite copies bound text and blobs immediately, so
    /// the Swift buffers may go away as soon as `bind` returns. The C macro
    /// is `(sqlite3_destructor_type)-1`, which Swift can't import.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /// Opens (creating if needed) the database file at `url`.
    ///
    /// WAL journaling lets readers proceed while a write is in progress, and
    /// with `synchronous=NORMAL` a commit is an append to the log with no
    /// fsync: durable against app crashes, and at worst loses the last
    /// transactions on power loss, which is fine for a cache and a catalog.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try open(path: url.path)
        try executeScript("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
    }

    /// A private database in memory, gone when the object is. For tests.
    public static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(memoryPath: ":memory:")
    }

    private init(memoryPath: String) throws {
        try open(path: memoryPath)
    }

    private func open(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        var db: OpaquePointer?
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(db)
            throw SQLiteError(code: code, message: message, sql: nil)
        }
        handle = db
        // Another process (or a second connection) holding a write lock
        // makes SQLite wait up to 3 s instead of failing with SQLITE_BUSY.
        sqlite3_busy_timeout(db, 3000)
        try executeScript("PRAGMA foreign_keys = ON;")
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    // MARK: - Running SQL

    /// Runs one statement that returns no rows you need (INSERT, UPDATE,
    /// DELETE, CREATE...).
    public func execute(_ sql: String, _ arguments: [SQLiteValue] = []) throws {
        try withStatement(sql, arguments) { statement in
            var code = sqlite3_step(statement)
            // Some statements (a few PRAGMAs) return a row anyway; step past it.
            while code == SQLITE_ROW { code = sqlite3_step(statement) }
            guard code == SQLITE_DONE else { throw error(code, sql) }
        }
    }

    /// Runs several statements separated by semicolons, with no arguments.
    /// Not cached: meant for schema setup and migrations.
    public func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        guard code == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw SQLiteError(code: code, message: text, sql: sql)
        }
    }

    /// Runs one statement and returns all its rows.
    public func query(_ sql: String, _ arguments: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try withStatement(sql, arguments) { statement in
            let count = sqlite3_column_count(statement)
            var columns: [String: Int] = [:]
            for i in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, i))
                if columns[name] == nil { columns[name] = Int(i) }
            }
            var rows: [SQLiteRow] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw error(code, sql) }
                var values: [SQLiteValue] = []
                values.reserveCapacity(Int(count))
                for i in 0..<count { values.append(Self.column(statement, i)) }
                rows.append(SQLiteRow(columns: columns, values: values))
            }
            return rows
        }
    }

    /// Runs `body` in a transaction: committed if it returns, rolled back if
    /// it throws.
    ///
    /// The outermost call uses `BEGIN IMMEDIATE`, which takes the write lock
    /// up front. A plain `BEGIN` would take it at the first write and could
    /// then fail with SQLITE_BUSY halfway through. Nested calls become
    /// savepoints, so an inner failure rolls back only the inner work.
    ///
    /// Other threads wait for the whole transaction, so keep bodies short
    /// and never do slow non-database work (decoding) inside them.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let depth = transactionDepth
        let savepoint = "minivu_savepoint_\(depth)"
        try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try execute(depth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
            return result
        } catch {
            if depth == 0 {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO \(savepoint)")
                try? execute("RELEASE \(savepoint)")
            }
            throw error
        }
    }

    /// The rowid of the most recent INSERT on this connection. Read it
    /// inside the same `transaction` as the insert if other threads write.
    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE.
    public var changes: Int {
        lock.lock(); defer { lock.unlock() }
        return Int(sqlite3_changes(handle))
    }

    /// The schema version number stored in the file header, 0 for a new
    /// database. Used to decide which migrations to run.
    public func userVersion() throws -> Int {
        Int(try query("PRAGMA user_version").first?.int("user_version") ?? 0)
    }

    public func setUserVersion(_ v: Int) throws {
        // PRAGMA values can't be bound as arguments; `v` is an Int, so this
        // interpolation can't inject SQL.
        try executeScript("PRAGMA user_version = \(v)")
    }

    // MARK: - Statements

    /// Finds or compiles the statement for `sql`, binds `arguments`, runs
    /// `body`, and always resets the statement afterwards. An un-reset
    /// statement keeps a read transaction open, which would stop the WAL
    /// from ever being checkpointed.
    private func withStatement<T>(_ sql: String, _ arguments: [SQLiteValue],
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == arguments.count else {
            throw SQLiteError(code: SQLITE_RANGE,
                              message: "expected \(expected) arguments, got \(arguments.count)", sql: sql)
        }
        for (offset, value) in arguments.enumerated() {
            try bind(value, at: Int32(offset + 1), in: statement, sql: sql)
        }
        return try body(statement)
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        // PERSISTENT tells SQLite the statement will be reused many times,
        // so it allocates it outside the short-lived lookaside pool.
        var hasMoreStatements = false
        let code = sql.withCString { text in
            let result = sqlite3_prepare_v3(handle, text, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, &tail)
            // Anything but whitespace after the first statement would be
            // silently ignored by SQLite; refuse it instead.
            if let tail { hasMoreStatements = !String(cString: tail).allSatisfy(\.isWhitespace) }
            return result
        }
        guard code == SQLITE_OK, let statement else { throw error(code, sql) }
        guard !hasMoreStatements else {
            sqlite3_finalize(statement)
            throw SQLiteError(code: SQLITE_MISUSE, message: "more than one statement; use executeScript", sql: sql)
        }
        statements[sql] = statement
        return statement
    }

    private func bind(_ value: SQLiteValue, at index: Int32, in statement: OpaquePointer, sql: String) throws {
        let code: Int32
        switch value {
        case .null:
            code = sqlite3_bind_null(statement, index)
        case .integer(let v):
            code = sqlite3_bind_int64(statement, index, v)
        case .real(let v):
            code = sqlite3_bind_double(statement, index, v)
        case .text(let v):
            code = v.withCString { sqlite3_bind_text(statement, index, $0, Int32(v.utf8.count), Self.transient) }
        case .blob(let v):
            if v.isEmpty {
                // An empty Data has no base address, and binding a nil
                // pointer would store NULL instead of an empty blob.
                code = sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                code = v.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                }
            }
        }
        guard code == SQLITE_OK else { throw error(code, sql) }
    }

    private static func column(_ statement: OpaquePointer, _ i: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, i) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, i))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, i))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, i) else { return .text("") }
            let count = Int(sqlite3_column_bytes(statement, i))
            return .text(String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            // Ask for the pointer before the length, as SQLite documents.
            guard let bytes = sqlite3_column_blob(statement, i) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, i))))
        default:
            return .null
        }
    }

    private func error(_ code: Int32, _ sql: String?) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
}
