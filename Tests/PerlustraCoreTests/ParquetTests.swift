import Foundation
import Testing
@testable import PerlustraCore

@Suite("Parquet 只读预览")
struct ParquetTests {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/parquet/\(name).parquet")
    }

    @Test("常见压缩保留长整数、小数、日期、空值和嵌套字段", arguments: ["none", "snappy", "gzip", "zstd", "brotli", "lz4"])
    func formats(_ codec: String) throws {
        let url = fixture("sample-\(codec)")
        let before = try Data(contentsOf: url)
        let p = try ParquetReader.read(url: url)
        #expect(p.rowCount == 3 && p.rowGroups == 2 && p.columnCount == 11)
        #expect(p.rows.count == 3)
        #expect(p.columns[0].name == "订单号" && p.columns[0].isNumeric)
        #expect(p.columns[1].type == "VARCHAR" && !p.columns[1].isNumeric)
        #expect(p.columns[2].type == "DECIMAL(20,2)" && p.columns[2].isNumeric)
        #expect(p.rows[0][0] == "9007199254740993")
        #expect(p.rows[1][0] == "9223372036854775807")
        #expect(p.rows[0][1] == "北京店")
        #expect(p.rows[0][2] == "1234567890123456.78")
        #expect(p.rows[1][2] == "-0.01")
        #expect(p.rows[0][3] == "2026-11-12")
        #expect(p.rows[0][4]?.contains("01:02:03.123456") == true)
        #expect(p.rows[0][5] == "true" && p.rows[1][5] == "false")
        #expect(p.rows[0][6] == "[1, 2]" && p.rows[1][6] == "[]")
        #expect(p.rows[0][7]?.contains("北京") == true)
        #expect(p.rows[0][8] == "a\0b" && p.rows[1][8] == "")
        #expect(p.rows[0][9] == "\\x00\\x01\\xFF")
        #expect(p.rows[0][10] == "18446744073709551615")
        #expect(p.rows[2][0] == nil && p.rows[2][2] == nil && p.rows[2][6] == nil)
        #expect(!p.truncatedCells)
        #expect(try Data(contentsOf: url) == before, "打开不能改写原文件")
    }

    @Test("空表仍然显示字段和类型")
    func empty() throws {
        let p = try ParquetReader.read(url: fixture("empty"))
        #expect(p.rowCount == 0 && p.rows.isEmpty)
        #expect(p.columns.count == 11 && p.columns[0].name == "订单号")
    }

    @Test("跨行组只预览前 200 行，总行数来自元数据")
    func boundedSample() throws {
        let p = try ParquetReader.read(url: fixture("multi-group"))
        #expect(p.rowCount == 513 && p.rowGroups == 11)
        #expect(p.rows.count == 200 && p.rows[0][0] == "0" && p.rows[199][0] == "199")
    }

    @Test("宽表只读取前 256 列但报告完整列数")
    func wide() throws {
        let p = try ParquetReader.read(url: fixture("wide"))
        #expect(p.columnCount == 270 && p.columns.count == 256)
        #expect(p.rows[0].count == 256 && p.rows[0][255] == "255")
    }

    @Test("超长内容明确标注截断")
    func longCell() throws {
        let p = try ParquetReader.read(url: fixture("long-cell"))
        #expect(p.truncatedCells)
        #expect(p.rows[0][0]?.hasSuffix("[内容过长，已截断]") == true)
        #expect(p.rows[1][0] == "正常")
    }

    @Test("BYTE_STREAM_SPLIT 编码")
    func byteStream() throws {
        let p = try ParquetReader.read(url: fixture("byte-stream"))
        #expect(p.rows == [["1.25", "1"], [nil, "2"], ["-3.5", "3"]])
    }

    @Test("中文、引号和通配符是文件名，不是 SQL 或批量读取")
    func literalFilename() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("地区=北京")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let path = dir.appendingPathComponent("北京 ' [1]*?.parquet")
        try FileManager.default.copyItem(at: fixture("sample-snappy"), to: path)
        try FileManager.default.copyItem(at: fixture("multi-group"), to: dir.appendingPathComponent("北京 ' 1xx.parquet"))
        let p = try ParquetReader.read(url: path)
        #expect(p.rowCount == 3 && p.rows[0][1] == "北京店" && p.columnCount == 11, "目录名不应被当成额外字段")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2, "不在旁边创建临时文件")
    }

    @Test("复制包含列头，保留数字精度，空值留空")
    func copy() throws {
        let p = try ParquetReader.read(url: fixture("sample-snappy"))
        let text = p.copyRows(IndexSet([0, 2]))
        #expect(text.hasPrefix("订单号\t门店\t金额\t"))
        #expect(text.contains("9007199254740993\t北京店\t1234567890123456.78"))
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
    }

    @Test("截断、损坏及不支持的编码明确失败", arguments: ["truncated", "broken-footer", "unsupported-encoding"])
    func damaged(_ name: String) {
        #expect(throws: ParquetError.self) { try ParquetReader.read(url: fixture(name)) }
    }

    @Test("加密文件说明不支持")
    func encrypted() {
        #expect(throws: ParquetError.encrypted) { try ParquetReader.read(url: fixture("encrypted")) }
    }

    @Test("取消的读取不会继续访问文件")
    func cancelled() {
        let c = ParquetCancellation()
        c.cancel()
        #expect(throws: ParquetError.cancelled) { try ParquetReader.read(url: fixture("missing"), cancel: c) }
    }

    @Test("取消打断正在执行的查询")
    func interrupt() throws {
        let token = ParquetCancellation()
        let connection = try ParquetConnection(library: ParquetLibrary.shared.get(), path: fixture("sample-snappy").path, cancel: token)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        let start = Date()
        #expect(throws: ParquetError.cancelled) {
            try connection.query("SELECT sum(a.i * b.i) FROM range(1000000) a(i), range(1000000) b(i)")
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("读取组件不能打开其他文件或加载网络扩展")
    func confinedReads() throws {
        let connection = try ParquetConnection(library: ParquetLibrary.shared.get(), path: fixture("sample-snappy").path, cancel: ParquetCancellation())
        #expect(throws: ParquetError.self) {
            try connection.query("SELECT * FROM read_parquet(?)", path: fixture("empty").path)
        }
        #expect(throws: ParquetError.self) {
            try connection.query("INSTALL httpfs")
        }
    }
}
