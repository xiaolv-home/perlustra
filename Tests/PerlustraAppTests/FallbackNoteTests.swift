import Testing
import Foundation
@testable import PerlustraApp

/// The plain-words explanation shown when another viewer took over from the usual one.
@MainActor
@Suite("换一种方式显示时的说明")
struct FallbackNoteTests {
    @Test("Parquet 加密或组件问题保留具体原因，不误报损坏")
    func parquetReason() {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/parquet/encrypted.parquet")
        let reason = "暂不支持需要密钥的加密 Parquet 文件"
        let note = HexRenderer().fallbackNote(for: FileContext(url: url), reason: reason)
        #expect(note.showsRawContent && note.message.contains(reason))
        #expect(!note.message.contains("损坏"))
    }

    @Test("十六进制显示的是原始数据，要马上说明")
    func hex() {
        let note = HexRenderer().fallbackNote(for: nil, reason: "")
        #expect(note.showsRawContent)
        #expect(note.message.contains("原始数据"))
    }

    @Test("系统预览不算原始内容，会带上原因")
    func quickLook() {
        let note = QuickLookRenderer().fallbackNote(for: nil, reason: "PDF 无法解析")
        #expect(!note.showsRawContent)
        #expect(note.message.contains("系统预览") && note.message.contains("PDF 无法解析"))
    }

    @Test("其他渲染器用通用说明，没有原因时不留空括号")
    func generic() {
        let note = PDFRenderer().fallbackNote(for: nil, reason: "")
        #expect(!note.showsRawContent)
        #expect(!note.message.contains("（"))
    }
}
