import Foundation
import Testing
import SQLite3
@testable import PerlustraCore

/// SQLiteReader 用系统 libsqlite3 只读打开；这里自建临时库验证，不依赖 fixtures。
@Suite("SQLite 读取")
struct SQLiteTests {
    static func exec(_ db: OpaquePointer, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err { sqlite3_free(err) }
    }

    /// 建一个临时数据库文件，用闭包填数据；用完由调用方删除。
    static func makeDatabase(_ populate: (OpaquePointer) -> Void) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perlustra-sqlite-\(UUID().uuidString).db")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            throw SQLiteError.openFailed("测试库创建失败")
        }
        populate(db)
        sqlite3_close(db)
        return url
    }

    @Test("列出表、视图、列与行数")
    func readDatabase() throws {
        let url = try Self.makeDatabase { db in
            Self.exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL)")
            Self.exec(db, "CREATE TABLE empty (a TEXT)")
            Self.exec(db, "CREATE VIEW adult AS SELECT id, name FROM users WHERE score > 60")
            Self.exec(db, "INSERT INTO users (name, score) VALUES ('张三', 88.5), ('李四', 55), ('王五', NULL)")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try SQLiteReader.readDatabase(url: url)
        #expect(db.tables.map(\.name) == ["adult", "empty", "users"])

        let users = db.tables.first { $0.name == "users" }!
        #expect(!users.isView)
        #expect(users.rowCount == 3)
        #expect(users.columns.count == 3)
        #expect(users.columns[0].name == "id")
        #expect(users.columns[0].primaryKey)
        #expect(users.columns[1].name == "name")
        #expect(users.columns[1].notNull)

        let adult = db.tables.first { $0.name == "adult" }!
        #expect(adult.isView)

        let empty = db.tables.first { $0.name == "empty" }!
        #expect(empty.rowCount == 0)
    }

    @Test("采样前 N 行，保留类型与 NULL")
    func sample() throws {
        let url = try Self.makeDatabase { db in
            Self.exec(db, "CREATE TABLE t (id INTEGER, name TEXT, data BLOB, score REAL)")
            Self.exec(db, "INSERT INTO t VALUES (1, 'a', x'0102', 1.5), (NULL, NULL, NULL, NULL)")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try SQLiteReader.sample(url: url, table: "t", limit: 200)
        #expect(s.columns == ["id", "name", "data", "score"])
        #expect(s.totalRows == 2)
        #expect(s.rows.count == 2)
        #expect(s.rows[0][0] == .integer(1))
        #expect(s.rows[0][1] == .text("a"))
        #expect(s.rows[0][2] == .blob(2))
        #expect(s.rows[0][3] == .real(1.5))
        #expect(s.rows[1][0] == .null)
        #expect(s.rows[1][1] == .null)
    }

    @Test("损坏文件报错而不是崩")
    func corrupt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perlustra-sqlite-corrupt-\(UUID().uuidString).db")
        try Data("这不是数据库".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SQLiteError.self) { try SQLiteReader.readDatabase(url: url) }
    }

    @Test("表名与列名含引号也能正确引用")
    func quoting() throws {
        let url = try Self.makeDatabase { db in
            Self.exec(db, "CREATE TABLE \"we\"\"ird\" (\"a\"\"b\" TEXT)")
            Self.exec(db, "INSERT INTO \"we\"\"ird\" VALUES ('x')")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try SQLiteReader.readDatabase(url: url)
        #expect(db.tables.map(\.name) == ["we\"ird"])
        #expect(db.tables[0].columns[0].name == "a\"b")
        let s = try SQLiteReader.sample(url: url, table: "we\"ird", limit: 10)
        #expect(s.rows[0][0] == .text("x"))
    }
}
