import Testing
import Foundation
@testable import PerlustraCore

@Suite("公式引擎")
struct FormulaTests {
    /// Row 1 is a header; data in rows 2–5.
    static let wb: Workbook = {
        let sales = Sheet(
            name: "销售",
            rows: [
                [.text("门店"), .text("城市"), .text("营业额"), .text("订单")],
                [.text("A店"), .text("上海"), .number(100), .number(4)],
                [.text("B店"), .text("北京"), .number(250.5), .number(5)],
                [.text("C店"), .text("上海"), .number(80), .number(2)],
                [.text("D店"), .text("深圳"), .text("n/a"), .number(1)],
            ])
        let cities = Sheet(
            name: "城市 表",
            rows: [
                [.text("城市"), .text("区域")], [.text("上海"), .text("华东")], [.text("北京"), .text("华北")], [.text("深圳"), .text("华南")],
            ])
        return Workbook(sheets: [sales, cities], source: "test")
    }()

    func ev(_ f: String, row offset: Int = 0) -> FValue {
        FormulaEngine.evaluate(f, in: FormulaContext(workbook: Self.wb, sheet: 0, rowOffset: offset))
    }

    @Test(
        "聚合函数跳过文本",
        arguments: [
            ("=SUM(C2:C5)", 430.5), ("=AVERAGE(C2:C5)", 143.5), ("=COUNT(C:C)", 3), ("=COUNTA(A2:A5)", 4),
            ("=MAX(C2:C5)", 250.5), ("=MIN(C2:C5)", 80), ("=SUM(D:D)", 12), ("=ROUND(AVERAGE(C2:C4)/3, 2)", 47.83),
        ])
    func aggregates(f: String, expected: Double) {
        #expect(ev(f) == .number(expected))
    }

    @Test("运算优先级、百分号、字符串拼接、比较")
    func operators() {
        #expect(ev("=1+2*3^2") == .number(19))
        #expect(ev("=-2^2") == .number(4))  // Excel: unary minus binds tighter
        #expect(ev("=50%*C2") == .number(50))
        #expect(ev("=A2&\"-\"&B2") == .text("A店-上海"))
        #expect(ev("=C2>C4") == .bool(true))
        #expect(ev("=B2=\"上海\"") == .bool(true))
        #expect(ev("=1/0") == .error("#DIV/0!"))
    }

    @Test("条件函数 SUMIF / COUNTIF / SUMIFS / AVERAGEIF")
    func conditional() {
        #expect(ev("=SUMIF(B2:B5,\"上海\",C2:C5)") == .number(180))
        #expect(ev("=COUNTIF(C2:C5,\">=100\")") == .number(2))
        #expect(ev("=COUNTIF(A2:A5,\"?店\")") == .number(4))
        #expect(ev("=SUMIFS(C2:C5,B2:B5,\"上海\",D2:D5,\">2\")") == .number(100))
        #expect(ev("=AVERAGEIF(B:B,\"上海\",C:C)") == .number(90))
        #expect(ev("=COUNTIFS(B2:B5,\"<>上海\")") == .number(2))
    }

    @Test("VLOOKUP / XLOOKUP / INDEX+MATCH，含跨表与带空格的表名")
    func lookups() {
        #expect(ev("=VLOOKUP(\"北京\",'城市 表'!A:B,2,FALSE)") == .text("华北"))
        #expect(ev("=VLOOKUP(B2,'城市 表'!$A$2:$B$4,2,0)") == .text("华东"))
        #expect(ev("=VLOOKUP(\"广州\",'城市 表'!A:B,2,FALSE)") == .error("#N/A"))
        #expect(ev("=IFERROR(VLOOKUP(\"广州\",'城市 表'!A:B,2,FALSE),\"未知\")") == .text("未知"))
        #expect(ev("=XLOOKUP(\"深圳\",B2:B5,A2:A5)") == .text("D店"))
        #expect(ev("=XLOOKUP(\"杭州\",B2:B5,A2:A5,\"无\")") == .text("无"))
        #expect(ev("=INDEX(A2:A5,MATCH(250.5,C2:C5,0))") == .text("B店"))
        #expect(ev("=MATCH(\"C*\",A2:A5,0)") == .number(3))
    }

    @Test("相对引用随行偏移，绝对引用不动（计算列填充）")
    func relativeFill() {
        #expect(ev("=C2/D2", row: 1) == .number(50.1))  // becomes C3/D3
        #expect(ev("=C2/$D$2", row: 2) == .number(20))  // C4 / D2
        #expect(ev("=IF(C2>90,\"高\",\"低\")", row: 2) == .text("低"))
    }

    @Test("文本与日期函数")
    func textAndDates() {
        #expect(ev("=LEFT(\"上海市黄浦区\",3)") == .text("上海市"))
        #expect(ev("=MID(\"ABCDEF\",2,3)") == .text("BCD"))
        #expect(ev("=LEN(\"中文\")") == .number(2))
        #expect(ev("=SUBSTITUTE(\"a-b-c\",\"-\",\"/\")") == .text("a/b/c"))
        #expect(ev("=TEXTJOIN(\",\",TRUE,B2:B4)") == .text("上海,北京,上海"))
        #expect(ev("=YEAR(DATE(2026,10,23))") == .number(2026))
        #expect(ev("=DAYS(DATE(2026,10,23),DATE(2026,10,1))") == .number(22))
        #expect(ev("=TEXT(1234.5,\"#,##0.00\")") == .text("1,234.50"))
    }

    @Test("错误输入给出提示而不是崩溃")
    func errors() {
        if case .error(let e) = ev("=SUM(") { #expect(e.contains("ERROR")) } else { Issue.record("expected error") }
        if case .error(let e) = ev("=FOO(1)") { #expect(e.contains("#NAME?")) } else { Issue.record("expected error") }
        if case .error(let e) = ev("=VLOOKUP(1,不存在!A:B,2,0)") { #expect(e.contains("找不到工作表")) } else { Issue.record("expected error") }
    }
}

@Suite("表格读取与视图")
struct SpreadsheetReaderTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures")

    @Test("xlsx：多表、共享字符串、日期、公式原文，以及缺缓存值的公式自动计算")
    func xlsx() throws {
        let url = Self.fixtures.appendingPathComponent("office/sales.xlsx")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let wb = try SpreadsheetReader.readXLSX(url: url)
        #expect(wb.sheets.map(\.name) == ["销售", "城市"])
        let s = wb.sheets[0]
        #expect(s.cell(0, 0) == .text("门店"))
        #expect(s.rows.count == 301)
        if case .date = s.cell(1, 2) {} else { Issue.record("C2 should be a date, got \(s.cell(1, 2))") }
        #expect(s.formulas[Sheet.key(1, 5)] == "=D2/E2")
        let d = s.cell(1, 3).number!, e = s.cell(1, 4).number!
        #expect(abs((s.cell(1, 5).number ?? 0) - d / e) < 1e-9)
        let region = FormulaEngine.evaluate("=VLOOKUP(B2,城市!A:B,2,FALSE)", in: FormulaContext(workbook: wb, sheet: 0))
        if case .text(let t) = region { #expect(["华东", "华北", "华南", "西南"].contains(t)) } else { Issue.record("lookup failed: \(region)") }
    }

    @Test("ods：重复行列展开")
    func ods() throws {
        let url = Self.fixtures.appendingPathComponent("office/stock.ods")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let wb = try SpreadsheetReader.readODS(url: url)
        let s = wb.sheets[0]
        #expect(s.name == "库存")
        #expect(s.rows.count == 5)
        #expect(s.cell(1, 1) == .number(12))
        #expect(s.cell(4, 0) == .text("梨"))
    }

    @Test("CSV（GBK）转为表格并识别数字")
    func csv() throws {
        let url = Self.fixtures.appendingPathComponent("data/sales-gbk.csv")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let wb = try SpreadsheetReader.readDelimited(url: url, delimiter: 44)
        let s = wb.sheets[0]
        #expect(s.cell(0, 0) == .text("门店"))
        if case .number = s.cell(1, 3) {} else { Issue.record("营业额 should be numeric") }
        #expect(CellValue.infer("007") == .text("007"))
        #expect(CellValue.infer("1,234.5") == .number(1234.5))
        // Long IDs keep every digit instead of turning into 7.24105097e+18.
        #expect(CellValue.infer("7241050970000123456") == .text("7241050970000123456"))
        #expect(CellValue.infer("-7241050970000123456") == .text("-7241050970000123456"))
        #expect(CellValue.infer("1234567890123456") == .text("1234567890123456"))
        #expect(CellValue.infer("123456789012345") == .number(123_456_789_012_345))
        #expect(CellValue.infer("902483485492") == .number(902_483_485_492))
        #expect(CellValue.infer("0.000000000000001") == .number(0.000000000000001))
        #expect(CellValue.infer("1.5e18") == .number(1.5e18))
    }

    @Test("筛选、排序、隐藏行与选区统计")
    func query() {
        let s = FormulaTests.wb.sheets[0]
        var q = SheetQuery()
        #expect(q.visibleRows(in: s) == [0, 1, 2, 3, 4])
        q.filters[1] = .values(["上海"])
        #expect(q.visibleRows(in: s) == [0, 1, 3])
        q.filters = [2: .greater(90)]
        #expect(q.visibleRows(in: s) == [0, 1, 2])
        q.filters = [:]
        q.sortColumn = 2; q.ascending = false
        #expect(q.visibleRows(in: s) == [0, 2, 1, 3, 4])  // text "n/a" sorts after numbers
        q.hiddenRows = [1]
        #expect(q.visibleRows(in: s) == [0, 2, 3, 4])
        let st = SelectionStats([.number(1), .text("2"), .empty, .text("x"), .number(3)])
        #expect(st.sum == 6)
        #expect(st.numeric == 3)
        #expect(st.average == 2)
        #expect(st.nonEmpty == 4)
        #expect(q.distinctValues(in: s, column: 1).first?.0 == "上海")
    }

    @Test("带前缀的 xlsx（.NET Open XML SDK 写法：<x:row>、绝对路径、BOM）能读出内容")
    func prefixedXLSX() throws {
        let dir = TestTemp.dir("prefixed")
        let pkg = dir.appendingPathComponent("pkg")
        func put(_ path: String, _ s: String) throws {
            let f = pkg.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(s.utf8).write(to: f)
        }
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        try put("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#)
        try put(
            "xl/workbook.xml",
            #"<?xml version="1.0" encoding="utf-8"?><x:workbook xmlns:x="\#(main)"><x:sheets><x:sheet name="字段清单" sheetId="1" r:id="R1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></x:sheets></x:workbook>"#
        )
        try put(
            "xl/_rels/workbook.xml.rels",
            "\u{FEFF}"
                + #"<?xml version="1.0" encoding="utf-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Type="worksheet" Target="/xl/worksheets/sheet1.xml" Id="R1"/><Relationship Type="sharedStrings" Target="/xl/sharedStrings.xml" Id="R2"/></Relationships>"#
        )
        try put("xl/sharedStrings.xml", #"<?xml version="1.0"?><x:sst xmlns:x="\#(main)"><x:si><x:t>表名</x:t></x:si></x:sst>"#)
        try put(
            "xl/worksheets/sheet1.xml",
            #"<?xml version="1.0"?><x:worksheet xmlns:x="\#(main)"><x:sheetData><x:row r="1"><x:c r="A1" t="s"><x:v>0</x:v></x:c><x:c r="B1" t="inlineStr"><x:is><x:t>字段</x:t></x:is></x:c></x:row><x:row r="2"><x:c r="A2" t="inlineStr"><x:is><x:t>ods_order</x:t></x:is></x:c><x:c r="B2"><x:v>42</x:v></x:c></x:row></x:sheetData></x:worksheet>"#
        )
        let url = dir.appendingPathComponent("prefixed.xlsx")
        try Zip.pack(directory: pkg, to: url)
        let wb = try SpreadsheetReader.readXLSX(url: url)
        #expect(wb.sheets.first?.name == "字段清单")
        #expect(wb.sheets.first?.rows.count == 2)
        #expect(wb.sheets.first?.cell(0, 0) == .text("表名"))
        #expect(wb.sheets.first?.cell(0, 1) == .text("字段"))
        #expect(wb.sheets.first?.cell(1, 1) == .number(42))
    }

    @Test("共享公式从属格可以出现在主格之前；超远合并不会撑满一百万行")
    func sharedFormulaOrderAndRowCap() throws {
        let dir = TestTemp.dir("shared-order")
        let pkg = dir.appendingPathComponent("pkg")
        func put(_ path: String, _ s: String) throws {
            let f = pkg.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(s.utf8).write(to: f)
        }
        try put("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#)
        try put(
            "xl/workbook.xml",
            #"<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>"#
        )
        try put(
            "xl/_rels/workbook.xml.rels",
            #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#
        )
        let sheet = """
            <?xml version="1.0"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData>
                <row r="2"><c r="A2"><f t="shared" si="0"/><v>2</v></c></row>
                <row r="1"><c r="A1"><f t="shared" si="0" ref="A1:A2">A1+1</f><v>1</v></c></row>
                <row r="500000"><c r="B500000"><v>9</v></c></row>
              </sheetData>
              <mergeCells count="1"><mergeCell ref="A1:A1048576"/></mergeCells>
            </worksheet>
            """
        try put("xl/worksheets/sheet1.xml", sheet)
        let url = dir.appendingPathComponent("shared.xlsx")
        try Zip.pack(directory: pkg, to: url)
        let sh = try SpreadsheetReader.readXLSX(url: url).sheets[0]
        #expect(sh.formulas[Sheet.key(0, 0)] == "=A1+1")
        #expect(sh.formulas[Sheet.key(1, 0)] == "=A2+1")
        #expect(sh.rows.count > 2)
        #expect(sh.rows.count < 200_000)
    }

    @Test("UTF-16 表格超过 32MB 时拒绝整文件解码")
    func wideCSVRefused() throws {
        let url = TestTemp.dir("wide-csv").appendingPathComponent("wide.csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data([0xFF, 0xFE, 0x41, 0x00]))
        let big = UInt64(SpreadsheetReader.wideTextLimit) + 8
        try handle.truncate(atOffset: big)
        try handle.close()
        do {
            _ = try SpreadsheetReader.readDelimited(url: url, delimiter: 44)
            Issue.record("应当拒绝超过 32MB 的 UTF-16 表格")
        } catch let error as SpreadsheetError {
            #expect(error.message.contains("32MB"))
        }
    }
}

/// 原文件隐藏的工作表 Perlustra 也隐藏（可以手动显示），并从文件的当前工作表打开。
@Suite("隐藏的工作表")
struct HiddenSheetTests {
    /// 四张表：第 2 张隐藏、第 3 张深度隐藏，打开在第 4 张。
    static func file() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perlustra-hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plain = dir.appendingPathComponent("plain.xlsx")
        try XLSXWriter.write(sheets: ["概览", "底稿", "参数", "看板"].map { (name: $0, rows: [[.text($0)]], formulas: [:]) }, to: plain)
        let unpacked = dir.appendingPathComponent("x")
        for (path, data) in try ArchiveReader.extractAll(url: plain, matching: { _ in true }) {
            var data = data
            if path == "xl/workbook.xml" {
                data = Data(
                    String(decoding: data, as: UTF8.self)
                        .replacingOccurrences(of: "<sheets>", with: "<bookViews><workbookView activeTab=\"3\"/></bookViews><sheets>")
                        .replacingOccurrences(of: "name=\"底稿\"", with: "name=\"底稿\" state=\"hidden\"")
                        .replacingOccurrences(of: "name=\"参数\"", with: "name=\"参数\" state=\"veryHidden\"").utf8)
            }
            let u = unpacked.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
        }
        let out = dir.appendingPathComponent("hidden.xlsx")
        try Zip.pack(directory: unpacked, to: out)
        return out
    }

    @Test("隐藏、深度隐藏都读进来并标上；当前工作表按文件里的 activeTab")
    func readsVisibility() throws {
        let wb = try SpreadsheetReader.readXLSX(url: Self.file())
        #expect(wb.sheets.map(\.name) == ["概览", "底稿", "参数", "看板"])
        #expect(wb.sheets.map(\.isHidden) == [false, true, true, false])
        #expect(wb.activeSheet == 3)
        // 深度隐藏的表也算进下标，引用它的公式能算出来。
        #expect(FormulaEngine.evaluate("=参数!A1", in: FormulaContext(workbook: wb, sheet: 0)).cell == .text("参数"))
    }
}

@Suite("从指定行开始排序和筛选")
struct SortFromRowTests {
    /// A title, captions, then rows whose cells must stay together.
    private var report: Sheet {
        Sheet(
            name: "报表",
            rows: [
                [.text("北京战区月度门店数"), .empty, .empty],
                [.text("月份"), .text("门店"), .text("金额")],
                [.text("1月"), .text("甲"), .number(30)],
                [.text("2月"), .text("乙"), .number(10)],
                [.text("3月"), .text("丙"), .number(20)],
                [.text("4月"), .text("丁"), .number(40)],
            ])
    }

    @Test("标题行下面的表头会被认出来")
    func titleAboveCaptions() {
        #expect(SheetQuery.guessedHeaderRow(in: report) == 1)
    }

    @Test("冻结了标题行时也认下一行表头")
    func frozenTitle() {
        var s = report
        s.frozenRows = 1
        #expect(SheetQuery.guessedHeaderRow(in: s) == 1)
    }

    @Test("冻结到表头时就用冻结行，普通首行表头不变")
    func ordinaryHeaders() {
        var s = report
        s.frozenRows = 2
        #expect(SheetQuery.guessedHeaderRow(in: s) == 1)
        let plain = Sheet(name: "a", rows: [[.text("名"), .text("值"), .text("注")], [.text("甲"), .number(1), .empty]])
        #expect(SheetQuery.guessedHeaderRow(in: plain) == 0)
        let noHeader = Sheet(name: "b", rows: [[.number(1), .number(2), .number(3)], [.number(4), .number(5), .number(6)]])
        #expect(SheetQuery.guessedHeaderRow(in: noHeader) == nil)
    }

    @Test("排序时每行整行一起移动")
    func rowsMoveWhole() {
        let s = report
        var q = SheetQuery()
        q.headerRowIndex = 1
        q.sortColumn = 2
        q.ascending = false
        let order = q.visibleRows(in: s)
        #expect(order == [0, 1, 5, 2, 4, 3])
        let shown = order.dropFirst(2).map { "\(s.cell($0, 0).display)\(s.cell($0, 1).display)\(s.cell($0, 2).display)" }
        #expect(shown == ["4月丁40", "1月甲30", "3月丙20", "2月乙10"])
    }

    @Test("指定行以上不动，以下才排序")
    func sortBelowRow() {
        var q = SheetQuery()
        q.startData(at: 4)
        q.sortColumn = 2
        q.ascending = false
        #expect(q.headerRowIndex == 3)
        #expect(q.visibleRows(in: report) == [0, 1, 2, 3, 5, 4])
    }

    @Test("指定行以上不被筛掉")
    func filterBelowRow() {
        var q = SheetQuery()
        q.startData(at: 4)
        q.filters[1] = .values(["丁"])
        #expect(q.visibleRows(in: report) == [0, 1, 2, 3, 5])
        #expect(q.distinctValues(in: report, column: 1).map(\.0).sorted() == ["丁", "丙"].sorted())
    }

    @Test("从第一行开始就没有表头")
    func fromTop() {
        var q = SheetQuery()
        q.startData(at: 0)
        #expect(q.headerRowIndex == nil)
        #expect(q.firstDataRow == 0)
    }
}
