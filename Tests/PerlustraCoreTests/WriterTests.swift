import Testing
import Foundation
@testable import PerlustraCore

@Suite("表格保存")
struct WriterTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures")

    func temp(_ name: String) -> URL {
        let dir = TestTemp.dir("writer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test("xlsx 局部修补：改值、改数字、写公式、新增行、清空，样式与合并原样保留")
    func patch() throws {
        let src = Self.fixtures.appendingPathComponent("office/report-styled.xlsx")
        try #require(FileManager.default.fileExists(atPath: src.path))
        let file = temp("report.xlsx")
        try FileManager.default.copyItem(at: src, to: file)
        var wb = try SpreadsheetReader.readXLSX(url: file)
        var s = wb.sheets[0]
        s.rows[2][0] = .text("南京东路店 & <新>")
        s.rows[3][3] = .number(999.5)
        while s.rows[2].count < 7 { s.rows[2].append(.empty) }
        s.rows[2][6] = .number(2_569_135)
        s.formulas[Sheet.key(2, 6)] = "=D3*2"
        while s.rows.count < 10 { s.rows.append([]) }
        s.rows[9] = [.empty, .text("新增行")]
        s.rows[4][5] = .empty
        s.columnCount = 7
        wb.sheets[0] = s
        let edited: Set<Int> = [Sheet.key(2, 0), Sheet.key(3, 3), Sheet.key(2, 6), Sheet.key(9, 1), Sheet.key(4, 5)]
        try XLSXPatcher.save(base: file, to: file, workbook: wb, edited: [0: edited])

        let back = try SpreadsheetReader.readXLSX(url: file)
        let b = back.sheets[0]
        #expect(b.cell(2, 0) == .text("南京东路店 & <新>"))
        #expect(b.cell(3, 3) == .number(999.5))
        #expect(b.formulas[Sheet.key(2, 6)] == "=D3*2")
        #expect(b.cell(9, 1) == .text("新增行"))
        #expect(b.cell(4, 5).isEmpty)
        // Untouched content and formatting survive.
        #expect(back.style(0, 0, 0)?.fill == RGBA(hex: "C0392B"))
        #expect(back.formatted(0, 3, 3).text == "¥999.50")  // number format kept on the edited cell
        #expect(back.formatted(0, 2, 2).text == "2019年3月8日")
        #expect(b.merges.contains(MergeRange(r0: 0, c0: 0, r1: 0, c1: 5)))
        #expect(b.frozenRows == 2)
        #expect(b.hiddenColumns.contains(5))
        #expect(b.cell(5, 0) == .text("西湖店"))
    }

    @Test("全新 xlsx：多表、日期、公式")
    func fresh() throws {
        let out = temp("new.xlsx")
        try XLSXWriter.write(
            sheets: [
                (
                    name: "数据", rows: [[.text("名称"), .text("值"), .text("日期")], [.text("甲"), .number(3), .date(45000)], [.text("乙"), .number(4), .empty]],
                    formulas: [:]
                ),
                (name: "汇总", rows: [[.text("合计"), .number(7)]], formulas: [Sheet.key(0, 1): "=SUM(数据!B2:B3)"]),
            ], to: out)
        let wb = try SpreadsheetReader.readXLSX(url: out)
        #expect(wb.sheets.map(\.name) == ["数据", "汇总"])
        #expect(wb.sheets[0].cell(1, 1) == .number(3))
        if case .date = wb.sheets[0].cell(1, 2) {} else { Issue.record("date lost") }
        #expect(wb.sheets[1].formulas[Sheet.key(0, 1)] == "=SUM(数据!B2:B3)")
    }

    @Test("CSV 按原编码与换行写回，必要时转 UTF-8")
    func csv() throws {
        let out = temp("a.csv")
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let rows: [[CellValue]] = [[.text("门店"), .text("备注")], [.text("上海"), .text("含逗号, 和\"引号\"")], [.number(1.5), .empty]]
        let kept = try CSVWriter.write(rows: rows, format: CSVFormat(delimiter: 44, encoding: gbk, bom: false, crlf: true), to: out)
        #expect(kept)
        let data = try Data(contentsOf: out)
        #expect(String(data: data, encoding: gbk) == "门店,备注\r\n上海,\"含逗号, 和\"\"引号\"\"\"\r\n1.5,\r\n")
        let wb = try SpreadsheetReader.readDelimited(url: out, delimiter: nil)
        #expect(wb.sheets[0].cell(1, 1) == .text("含逗号, 和\"引号\""))
        // Emoji cannot be represented in GB18030? (it can) — use a non-encodable case for Shift_JIS instead.
        let kept2 = try CSVWriter.write(rows: [[.text("中文简体：汉字 ✓ 😀")]], format: CSVFormat(delimiter: 44, encoding: .shiftJIS, bom: false, crlf: false), to: out)
        #expect(!kept2)
        #expect(try Data(contentsOf: out).prefix(3) == Data([0xEF, 0xBB, 0xBF]))
    }

    @Test("xlsx 表尾连续新增多行时保持 OOXML 行号严格递增")
    func patchMultipleTrailingRowsInOrder() throws {
        let file = temp("trailing.xlsx")
        try XLSXWriter.write(
            sheets: [(name: "Sheet1", rows: [[.text("A"), .text("B")], [.number(1), .number(2)]], formulas: [:])],
            to: file
        )
        var wb = try SpreadsheetReader.readXLSX(url: file)
        var s = wb.sheets[0]
        while s.rows.count <= 15 { s.rows.append([]) }
        s.rows[10] = [.text("第11行")]
        s.rows[12] = [.text("第13行")]
        s.rows[15] = [.text("第16行")]
        wb.sheets[0] = s
        let edited: Set<Int> = [Sheet.key(10, 0), Sheet.key(12, 0), Sheet.key(15, 0)]
        try XLSXPatcher.save(base: file, to: file, workbook: wb, edited: [0: edited])

        let xmlData = try #require(ArchiveReader.extract(url: file, matching: { $0 == "xl/worksheets/sheet1.xml" })?.1)
        let xml = String(decoding: xmlData, as: UTF8.self)
        let pos11 = try #require(xml.range(of: "r=\"11\"")?.lowerBound)
        let pos13 = try #require(xml.range(of: "r=\"13\"")?.lowerBound)
        let pos16 = try #require(xml.range(of: "r=\"16\"")?.lowerBound)
        #expect(pos11 < pos13)
        #expect(pos13 < pos16)

        let back = try SpreadsheetReader.readXLSX(url: file).sheets[0]
        #expect(back.cell(10, 0) == .text("第11行"))
        #expect(back.cell(12, 0) == .text("第13行"))
        #expect(back.cell(15, 0) == .text("第16行"))
    }
}
