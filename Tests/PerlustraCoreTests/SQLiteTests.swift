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

    @Test("列出表、视图、列；行数另数，视图不数")
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
        #expect(users.problem == nil)
        #expect(users.columns.count == 3)
        #expect(users.columns[0].name == "id")
        #expect(users.columns[0].primaryKey)
        #expect(users.columns[1].name == "name")
        #expect(users.columns[1].notNull)

        let adult = db.tables.first { $0.name == "adult" }!
        #expect(adult.isView)

        let counts = try SQLiteReader.countRows(url: url, tables: ["users", "empty"])
        #expect(counts == ["users": 3, "empty": 0])
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
        #expect(s.rows.count == 2)
        #expect(s.rows[0][0] == .integer(1))
        #expect(s.rows[0][1] == .text("a"))
        #expect(s.rows[0][2] == .blob(2))
        #expect(s.rows[0][3] == .real(1.5))
        #expect(s.rows[1][0] == .null)
        #expect(s.rows[1][1] == .null)
        #expect(SQLiteCell.real(1200).text == "1200", "整数值的小数不带 .0")
        #expect(SQLiteCell.real(0.1 + 0.2).text == "0.3")
    }

    @Test("空表也给出列名")
    func emptyTableColumns() throws {
        let url = try Self.makeDatabase { db in Self.exec(db, "CREATE TABLE t (a TEXT, b INTEGER)") }
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try SQLiteReader.sample(url: url, table: "t", limit: 10)
        #expect(s.columns == ["a", "b"] && s.rows.isEmpty)
    }

    @Test("一个视图引用的表被删了：只有它标成读不出来，其余照常")
    func brokenView() throws {
        let url = try Self.makeDatabase { db in
            Self.exec(db, "CREATE TABLE a (x); CREATE TABLE b (y); INSERT INTO a VALUES (1)")
            Self.exec(db, "CREATE VIEW v AS SELECT * FROM b; DROP TABLE b")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteReader.readDatabase(url: url)
        #expect(db.tables.map(\.name) == ["a", "v"])
        #expect(db.tables[0].problem == nil && db.tables[0].columns.count == 1)
        #expect(db.tables[1].problem != nil)
        #expect(try SQLiteReader.sample(url: url, table: "a", limit: 10).rows == [[.integer(1)]])
    }

    @Test("FTS 背后的影子表不列出来，虚拟表本身列出来")
    func shadowTables() throws {
        let url = try Self.makeDatabase { db in Self.exec(db, "CREATE VIRTUAL TABLE f USING fts5(a); INSERT INTO f VALUES ('hi')") }
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteReader.readDatabase(url: url)
        #expect(db.tables.map(\.name) == ["f"])
        #expect(db.tables[0].isVirtual)
    }

    @Test("WAL 库单独拷出来、没有 -shm 文件：按快照打开，不在旁边生成文件")
    func walWithoutShm() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perlustra-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("w.db")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        Self.exec(handle!, "PRAGMA journal_mode=WAL; CREATE TABLE t (x); INSERT INTO t VALUES (7); PRAGMA wal_checkpoint(TRUNCATE)")
        sqlite3_close(handle)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }

        let db = try SQLiteReader.readDatabase(url: url)
        #expect(db.snapshot)
        #expect(db.tables.map(\.name) == ["t"])
        #expect(try SQLiteReader.sample(url: url, table: "t", limit: 10).rows == [[.integer(7)]])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["w.db"], "只读查看不在旁边留下文件")
    }

    @Test("有程序正在写：等一会儿，还锁着就明说，不当成空表")
    func locked() throws {
        let url = try Self.makeDatabase { db in Self.exec(db, "CREATE TABLE t (x); INSERT INTO t VALUES (1)") }
        defer { try? FileManager.default.removeItem(at: url) }
        var writer: OpaquePointer?
        #expect(sqlite3_open(url.path, &writer) == SQLITE_OK)
        Self.exec(writer!, "BEGIN EXCLUSIVE; INSERT INTO t VALUES (2)")
        defer { Self.exec(writer!, "ROLLBACK"); sqlite3_close(writer) }
        let c = try SQLiteReader.Connection(url, cancel: nil, busyTimeout: 50)
        #expect(throws: SQLiteError.locked) { try c.query("SELECT * FROM t") { _ in } }
    }

    @Test("取消能打断正在跑的慢查询")
    func cancel() throws {
        let url = try Self.makeDatabase { db in
            Self.exec(db, "CREATE TABLE t (i INTEGER)")
            Self.exec(db, "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c LIMIT 5000) INSERT INTO t SELECT i FROM c")
            // 两两配对 2500 万次：不打断要好几秒。
            Self.exec(db, "CREATE VIEW slow AS SELECT a.i FROM t a, t b WHERE a.i + b.i = -1")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let token = SQLiteCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        let start = Date()
        #expect(throws: SQLiteError.cancelled) { try SQLiteReader.sample(url: url, table: "slow", limit: 10, cancel: token) }
        #expect(Date().timeIntervalSince(start) < 1.5)
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
