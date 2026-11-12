import Foundation
import SQLite3

/// One column of a table, read from `PRAGMA table_info`.
public struct SQLiteColumn: Sendable, Equatable {
    public let name: String
    /// Declared type from the schema, e.g. "TEXT", "INTEGER". Empty when untyped.
    public let declaredType: String
    public let notNull: Bool
    public let primaryKey: Bool

    public init(name: String, declaredType: String, notNull: Bool, primaryKey: Bool) {
        self.name = name
        self.declaredType = declaredType
        self.notNull = notNull
        self.primaryKey = primaryKey
    }
}

/// A table or view in the database. Row counts are filled in later (`countRows`), because
/// counting a big table takes a while and counting a view means running it.
public struct SQLiteTable: Sendable, Equatable {
    public let name: String
    public let isView: Bool
    /// A virtual table (FTS, R-Tree…): its rows come from a module.
    public let isVirtual: Bool
    public let columns: [SQLiteColumn]
    /// Why the table's structure could not be read (a view over a dropped table, a missing
    /// module). The rest of the database still opens.
    public let problem: String?

    public init(name: String, isView: Bool, isVirtual: Bool = false, columns: [SQLiteColumn], problem: String? = nil) {
        self.name = name
        self.isView = isView
        self.isVirtual = isVirtual
        self.columns = columns
        self.problem = problem
    }
}

/// Everything listed without loading any single table's rows.
public struct SQLiteDatabase: Sendable, Equatable {
    public let tables: [SQLiteTable]
    public let version: String
    /// Opened as an unchanging snapshot (`immutable=1`): a WAL database copied without its
    /// `-shm` file cannot be opened read-only any other way. Changes still sitting in a
    /// `-wal` file are not shown then.
    public let snapshot: Bool

    public init(tables: [SQLiteTable], version: String, snapshot: Bool = false) {
        self.tables = tables
        self.version = version
        self.snapshot = snapshot
    }
}

/// A single value from a row. The type is kept so the UI can right-align numbers and
/// mark NULL and binary distinctly instead of flattening everything to text.
public enum SQLiteCell: Sendable, Equatable {
    case null
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Int)  // byte count

    public var isNull: Bool { if case .null = self { return true }; return false }

    /// The value as text, the way the sqlite3 shell prints it (`1200`, not `1200.0`).
    public var text: String {
        switch self {
        case .null: return "NULL"
        case .text(let t): return t
        case .integer(let i): return String(i)
        case .real(let d): return String(format: "%.15g", d)
        case .blob(let n): return "‹二进制 \(n) 字节›"
        }
    }
}

/// The first `limit` rows of a table.
public struct SQLiteSample: Sendable, Equatable {
    public let table: String
    public let columns: [String]
    public let rows: [[SQLiteCell]]

    public init(table: String, columns: [String], rows: [[SQLiteCell]]) {
        self.table = table
        self.columns = columns
        self.rows = rows
    }
}

public enum SQLiteError: LocalizedError, Equatable {
    case openFailed(String)
    case queryFailed(String)
    case locked
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .openFailed(let s): return "无法打开数据库：\(s)"
        case .queryFailed(let s): return "查询失败：\(s)"
        case .locked: return "数据库正被别的程序写入，稍后再试"
        case .cancelled: return "已取消"
        }
    }
}

/// Stops a running read: set from any thread, checked by SQLite every few thousand steps.
public final class SQLiteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Read-only access to SQLite files via the system libsqlite3. Never writes and never
/// executes user SQL — only fixed schema / count / sample queries against one file.
public enum SQLiteReader {
    /// Quotes an identifier for safe interpolation into fixed SQL.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// One open file. Waits up to `busyTimeout` for a writer to finish, and stops when the
    /// cancellation is set.
    final class Connection {
        let db: OpaquePointer
        let snapshot: Bool
        private let cancel: SQLiteCancellation?

        init(_ url: URL, cancel: SQLiteCancellation?, busyTimeout: Int32 = 3000) throws {
            self.cancel = cancel
            // A WAL database without its -shm file fails on the first read, not on open:
            // try it, and fall back to reading the file as a fixed snapshot.
            if let db = try? Self.open(url.path, flags: SQLITE_OPEN_READONLY), Self.readable(db, busyTimeout) {
                self.db = db
                snapshot = false
            } else {
                let uri = url.standardizedFileURL.absoluteString + "?immutable=1"
                let db = try Self.open(uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
                if let error = Self.check(db) {
                    sqlite3_close(db)
                    throw error
                }
                self.db = db
                snapshot = true
            }
            sqlite3_busy_timeout(db, busyTimeout)
            if let cancel {
                sqlite3_progress_handler(
                    db, 2000,
                    { ctx in
                        guard let ctx else { return 0 }
                        return Unmanaged<SQLiteCancellation>.fromOpaque(ctx).takeUnretainedValue().isCancelled ? 1 : 0
                    }, Unmanaged.passUnretained(cancel).toOpaque())
            }
        }

        deinit { sqlite3_close(db) }

        private static func open(_ path: String, flags: Int32) throws -> OpaquePointer {
            var handle: OpaquePointer?
            let rc = sqlite3_open_v2(path, &handle, flags, nil)
            guard rc == SQLITE_OK, let db = handle else {
                let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
                if handle != nil { sqlite3_close(handle) }
                throw SQLiteError.openFailed(msg)
            }
            return db
        }

        /// Reads the schema once. False when the file needs the snapshot route.
        private static func readable(_ db: OpaquePointer, _ busyTimeout: Int32) -> Bool {
            sqlite3_busy_timeout(db, busyTimeout)
            let rc = sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil)
            if rc == SQLITE_OK { return true }
            // Locked or not a database: the snapshot route would not help, report it as is.
            if rc == SQLITE_BUSY || rc == SQLITE_NOTADB || rc == SQLITE_CORRUPT { return true }
            sqlite3_close(db)
            return false
        }

        /// The error reading the schema gives, if any.
        private static func check(_ db: OpaquePointer) -> SQLiteError? {
            let rc = sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil)
            return rc == SQLITE_OK ? nil : error(db, rc)
        }

        static func error(_ db: OpaquePointer, _ rc: Int32) -> SQLiteError {
            switch rc & 0xff {
            case SQLITE_INTERRUPT: return .cancelled
            case SQLITE_BUSY, SQLITE_LOCKED: return .locked
            default:
                let msg = String(cString: sqlite3_errmsg(db))
                return .queryFailed(msg.isEmpty ? "错误 \(rc)" : msg)
            }
        }

        /// Runs a fixed query and hands each row to `row`. Any error — including one in the
        /// middle of the rows — is thrown, never taken for the end of the data.
        func query(_ sql: String, _ row: (OpaquePointer) throws -> Void) throws {
            if cancel?.isCancelled == true { throw SQLiteError.cancelled }
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let stmt else { throw Self.error(db, rc) }
            defer { sqlite3_finalize(stmt) }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { return }
                guard rc == SQLITE_ROW else { throw Self.error(db, rc) }
                try row(stmt)
            }
        }
    }

    public static func readDatabase(url: URL, cancel: SQLiteCancellation? = nil) throws -> SQLiteDatabase {
        let c = try Connection(url, cancel: cancel)
        let version = String(cString: sqlite3_libversion())
        var tables: [SQLiteTable] = []
        for (name, type) in try list(c) {
            var columns: [SQLiteColumn] = []
            var problem: String?
            do {
                columns = try self.columns(of: name, in: c)
            } catch SQLiteError.cancelled {
                throw SQLiteError.cancelled
            } catch {
                problem = (error as? SQLiteError).flatMap(\.errorDescription) ?? error.localizedDescription
            }
            tables.append(SQLiteTable(name: name, isView: type == "view", isVirtual: type == "virtual", columns: columns, problem: problem))
        }
        return SQLiteDatabase(tables: tables, version: version, snapshot: c.snapshot)
    }

    /// Names and kinds of the user's tables and views. `PRAGMA table_list` knows the shadow
    /// tables behind FTS and R-Tree and leaves them out; older SQLite falls back to sqlite_master.
    private static func list(_ c: Connection) throws -> [(String, String)] {
        var out: [(String, String)] = []
        do {
            try c.query("PRAGMA main.table_list") { stmt in
                let name = text(stmt, 1), type = text(stmt, 2)
                guard type == "table" || type == "view" || type == "virtual", !name.hasPrefix("sqlite_") else { return }
                out.append((name, type))
            }
        } catch SQLiteError.cancelled {
            throw SQLiteError.cancelled
        } catch {
            out = []
            try c.query("SELECT name, type, sql FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'") { stmt in
                let virtual = text(stmt, 2).uppercased().hasPrefix("CREATE VIRTUAL")
                out.append((text(stmt, 0), virtual ? "virtual" : text(stmt, 1)))
            }
        }
        return out.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private static func columns(of table: String, in c: Connection) throws -> [SQLiteColumn] {
        var out: [SQLiteColumn] = []
        try c.query("PRAGMA main.table_info(" + quote(table) + ")") { stmt in
            out.append(
                SQLiteColumn(
                    name: text(stmt, 1), declaredType: text(stmt, 2),
                    notNull: sqlite3_column_int(stmt, 3) != 0, primaryKey: sqlite3_column_int(stmt, 5) != 0))
        }
        return out
    }

    /// Row counts of the given tables (not views: counting one means running it). A table
    /// that cannot be counted is left out; the whole call stops when cancelled.
    public static func countRows(url: URL, tables: [String], cancel: SQLiteCancellation? = nil) throws -> [String: Int64] {
        let c = try Connection(url, cancel: cancel)
        var out: [String: Int64] = [:]
        for name in tables {
            do {
                try c.query("SELECT COUNT(*) FROM main." + quote(name)) { out[name] = sqlite3_column_int64($0, 0) }
            } catch SQLiteError.cancelled {
                throw SQLiteError.cancelled
            } catch {
                continue
            }
        }
        return out
    }

    public static func sample(url: URL, table: String, limit: Int, cancel: SQLiteCancellation? = nil) throws -> SQLiteSample {
        let c = try Connection(url, cancel: cancel)
        var columns: [String] = []
        var rows: [[SQLiteCell]] = []
        try c.query("SELECT * FROM main." + quote(table) + " LIMIT \(max(0, limit))") { stmt in
            let n = Int(sqlite3_column_count(stmt))
            if columns.isEmpty {
                columns = (0..<n).map { i in sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "col\(i)" }
            }
            rows.append((0..<n).map { cell(from: stmt, index: Int32($0)) })
        }
        // No rows: the column names still come from the statement.
        if columns.isEmpty, rows.isEmpty {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(c.db, "SELECT * FROM main." + quote(table) + " LIMIT 0", -1, &stmt, nil) == SQLITE_OK, let stmt {
                columns = (0..<sqlite3_column_count(stmt)).map { i in sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "col\(i)" }
                sqlite3_finalize(stmt)
            }
        }
        return SQLiteSample(table: table, columns: columns, rows: rows)
    }

    /// Text of a column, keeping characters after an embedded NUL.
    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, index) else { return "" }
        let n = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
    }

    private static func cell(from stmt: OpaquePointer, index: Int32) -> SQLiteCell {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, index))
        case SQLITE_BLOB: return .blob(Int(sqlite3_column_bytes(stmt, index)))
        default: return .text(text(stmt, index))
        }
    }
}
