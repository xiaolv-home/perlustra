import Foundation
import Testing
@testable import PerlustraApp

/// Which viewer opens which file, and what comes next if it fails. What the user sees first
/// depends on this order, so it is pinned down here.
@MainActor
@Suite("打开文件时依次尝试哪些渲染器")
struct RendererRegistryTests {
    private func chain(_ name: String, _ content: String) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return RendererRegistry.chain(for: FileContext(url: url)).map { String(describing: $0) }
    }

    @Test("Markdown 先写作渲染，再退回纯文本和十六进制")
    func markdown() throws {
        let c = try chain("笔记.md", "# 标题\n\n正文\n")
        #expect(c.first == "MarkdownRenderer")
        #expect(c.contains("TextRenderer"))
        #expect(c.last == "HexRenderer")
    }

    @Test("CSV 先按表格打开")
    func csv() throws {
        #expect(try chain("表.csv", "a,b\n1,2\n").first == "SpreadsheetRenderer")
    }

    @Test("SQLite 数据库用专用渲染器打开")
    func sqlite() throws {
        let c = try chain("数据.sqlite", "SQLite format 3\0" + String(repeating: "\0", count: 64))
        #expect(c.first == "SQLiteRenderer")
        #expect(c.last == "HexRenderer")
    }

    @Test("JSON 打不开时能退回纯文本")
    func json() throws {
        let c = try chain("配置.json", "{\"a\": 1}")
        #expect(c.first == "JSONRenderer")
        #expect(c.contains("TextRenderer"))
    }

    @Test("认不出的二进制内容最后总有十六进制兜底")
    func unknown() throws {
        #expect(try chain("未知.xyz", "\u{1}\u{2}\u{3}\u{0}\u{4}").last == "HexRenderer")
    }
}
