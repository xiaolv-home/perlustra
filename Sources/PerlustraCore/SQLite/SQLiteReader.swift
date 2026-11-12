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

/// A table or view in the database, with its column list and row count.
public struct SQLiteTable: Sendable, Equatable {
    public let name: String
    public let isView: Bool
    public let columns: [SQLiteColumn]
    public let rowCount: Int64

    public init(name: String, isView: Bool, columns: [SQLiteColumn], rowCount: Int64) {
        self.name = name
        self.isView = isView
        self.columns = columns
        self.rowCount = rowCount
    }
}

/// Everything listed without loading any single table's rows.
public struct SQLiteDatabase: Sendable, Equatable {
    public let tables: [SQLiteTable]
    public let version: String

    public init(tables: [SQLiteTable], version: String) {
        self.tables = tables
        self.version = version
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
}

/// The first `limit` rows of a table, plus the total row count.
public struct SQLiteSample: Sendable, Equatable {
    public let table: String
    public let columns: [String]
    public let rows: [[SQLiteCell]]
    public let totalRows: Int64

    public init(table: String, columns: [String], rows: [[SQLiteCell]], totalRows: Int64) {
        self.table = table
        self.columns = columns
        self.rows = rows
        self.totalRows = totalRows
    }
}

public enum SQLiteError: LocalizedError, Equatable {
    case openFailed(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let s): return "无法打开数据库：\(s)"
        case .queryFailed(let s): return "查询失败：\(s)"
        }
    }
}

/// Read-only access to SQLite files via the system libsqlite3. Never writes and never
/// executes user SQL — only fixed schema / count / sample queries against one file.
public enum SQLiteReader {
    /// Quotes an identifier for safe interpolation into fixed SQL.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func queryError(_ db: OpaquePointer?, fallback: String) -> SQLiteError {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? fallback
        return .queryFailed(msg.isEmpty ? fallback : msg)
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if handle != nil { sqlite3_close(handle) }
            throw SQLiteError.openFailed(msg)
        }
        return db
    }

    public static func readDatabase(url: URL) throws -> SQLiteDatabase {
        let db = try open(url)
        defer { sqlite3_close(db) }
        let version = String(cString: sqlite3_libversion())
        let tables = try listTables(db)
        return SQLiteDatabase(tables: tables, version: version)
    }

    private static func listTables(_ db: OpaquePointer) throws -> [SQLiteTable] {
        var stmt: OpaquePointer?
        let sql = "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw queryError(db, fallback: "读表列表") }
        defer { sqlite3_finalize(stmt) }

        var out: [SQLiteTable] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let n = sqlite3_column_text(stmt, 0), let t = sqlite3_column_text(stmt, 1) else { continue }
            let name = String(cString: n)
            let isView = String(cString: t) == "view"
            let columns = try columns(of: name, in: db)
            let count = try rowCount(of: name, in: db)
            out.append(SQLiteTable(name: name, isView: isView, columns: columns, rowCount: count))
        }
        return out
    }

    private static func columns(of table: String, in db: OpaquePointer) throws -> [SQLiteColumn] {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(" + quote(table) + ")"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw queryError(db, fallback: "读表结构") }
        defer { sqlite3_finalize(stmt) }
        var out: [SQLiteColumn] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let type = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let notNull = sqlite3_column_int(stmt, 3) != 0
            let pk = sqlite3_column_int(stmt, 5) != 0
            out.append(SQLiteColumn(name: name, declaredType: type, notNull: notNull, primaryKey: pk))
        }
        return out
    }

    private static func rowCount(of table: String, in db: OpaquePointer) throws -> Int64 {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM " + quote(table)
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw queryError(db, fallback: "统计行数") }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    public static func sample(url: URL, table: String, limit: Int) throws -> SQLiteSample {
        let db = try open(url)
        defer { sqlite3_close(db) }
        let total = try rowCount(of: table, in: db)
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM " + quote(table) + " LIMIT \(max(0, limit))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw queryError(db, fallback: "读取数据") }
        guard let stmt else { throw queryError(db, fallback: "读取数据") }
        defer { sqlite3_finalize(stmt) }

        let colCount = Int(sqlite3_column_count(stmt))
        let columns = (0..<colCount).map { i -> String in
            sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "col\(i)"
        }
        var rows: [[SQLiteCell]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [SQLiteCell] = []
            row.reserveCapacity(colCount)
            for i in 0..<colCount {
                row.append(cell(from: stmt, index: Int32(i)))
            }
            rows.append(row)
        }
        return SQLiteSample(table: table, columns: columns, rows: rows, totalRows: total)
    }

    private static func cell(from stmt: OpaquePointer, index: Int32) -> SQLiteCell {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, index))
        case SQLITE_BLOB: return .blob(Int(sqlite3_column_bytes(stmt, index)))
        default:
            if let t = sqlite3_column_text(stmt, index) { return .text(String(cString: t)) }
            return .null
        }
    }
}
