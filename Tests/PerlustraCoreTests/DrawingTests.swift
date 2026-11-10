import Testing
import Foundation
@testable import PerlustraCore

@Suite("表格上的图表、图片、形状")
struct DrawingTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures")

    static func workbook() throws -> Workbook {
        let url = fixtures.appendingPathComponent("office/charts.xlsx")
        try #require(FileManager.default.fileExists(atPath: url.path), "先运行 scripts/gen-chart-fixtures.py")
        return try SpreadsheetReader.readXLSX(url: url)
    }

    static func charts(_ sheet: Sheet) -> [ChartSpec] {
        sheet.drawings.flatMap(\.items).compactMap {
            if case .chart(let c) = $0.content { return c }; return nil
        }
    }

    /// openpyxl 写的图表只有单元格引用、没有缓存值 —— 用户那份周报就是这样,以前整页空白。
    @Test("只有引用没有缓存值的图表:数从单元格里取")
    func uncachedChartReadsCells() throws {
        let wb = try Self.workbook()
        let sheet = try #require(wb.sheets.first { $0.name == "图表分析" })
        let charts = Self.charts(sheet)
        #expect(charts.count == 5)
        let first = charts[0]
        #expect(first.plots.first?.kind == .bar)
        #expect(first.plots.first?.series.first?.values?.cachedNumbers.isEmpty == true, "夹具得是没有缓存值的")
        let r = first.resolved(using: wb)
        #expect(r.title == "图1 · 各战区 GMV 三周对比")
        let s = r.plots[0].series
        #expect(s.map(\.name) == ["本周", "上周", "去年同期"])
        #expect(s[0].categories == ["华东", "华南", "华北", "西南", "西北", "华中"])
        #expect(s[0].values == [1000, 1137, 1274, 1411, 1548, 1685])
        #expect(s[2].values.first == 800)
    }

    @Test("锚在单元格上:位置、大小;用到的范围外的图也给它留出行列")
    func anchorsAndRoom() throws {
        let wb = try Self.workbook()
        let sheet = try #require(wb.sheets.first { $0.name == "图表分析" })
        let first = try #require(sheet.drawings.first)
        #expect(first.anchor.from == DrawingAnchor.Marker(row: 3, col: 1))  // B4
        #expect((first.anchor.width ?? 0) > 400 && (first.anchor.height ?? 0) > 200)
        // AB4 上的那张图远在数据右边:列数得扩到能放下它
        #expect(sheet.columnCount > 27 + 6)
    }

    @Test("组合图:柱 + 折线,各自的坐标轴")
    func combo() throws {
        let wb = try Self.workbook()
        let charts = Self.charts(try #require(wb.sheets.first { $0.name == "图表分析" }))
        let combo = try #require(charts.first { $0.plots.count == 2 })
        #expect(Set(combo.plots.map(\.kind)) == [.bar, .line])
        #expect(Set(combo.plots.map { $0.axisIDs.last ?? "" }).count == 2, "折线在副坐标轴上")
        let r = combo.resolved(using: wb)
        #expect(r.plots.map(\.plot.kind) == [.bar, .line], "柱在下、线在上")
    }

    @Test("横向条形、堆积、各类图表都认得")
    func kinds() throws {
        let wb = try Self.workbook()
        let main = Self.charts(try #require(wb.sheets.first { $0.name == "图表分析" }))
        #expect(main.contains { $0.plots.first?.horizontal == true })
        #expect(main.contains { $0.plots.first?.grouping == "stacked" })
        let other = Self.charts(try #require(wb.sheets.first { $0.name == "各种图表" }))
        #expect(Set(other.compactMap { $0.plots.first?.kind }) == [.line, .area, .pie, .doughnut, .radar, .scatter])
        let scatter = try #require(other.first { $0.plots.first?.kind == .scatter }).resolved(using: wb)
        #expect(scatter.plots[0].series[0].xValues == [0, 1.5, 3, 4.5, 6, 7.5])
        #expect(scatter.plots[0].series[0].values == [4, 1, 0, 1, 4, 9])
        let pie = try #require(other.first { $0.plots.first?.kind == .pie }).resolved(using: wb)
        #expect(pie.plots[0].plot.varyColors, "饼图每块一种颜色")
    }

    @Test("没写填充色的系列按图表样式配色:白边框不能当填充,单色样式由深到浅")
    func styleColors() throws {
        let wb = try Self.workbook()
        let main = Self.charts(try #require(wb.sheets.first { $0.name == "图表分析" }))
        let clustered = try #require(main.first { $0.style == 12 })
        let s = clustered.plots[0].series
        #expect(s.allSatisfy { $0.fill == nil && $0.line == RGBA(hex: "F2F2F2") }, "只有边框没有填充")
        let colors = (0..<3).map { clustered.seriesColor($0, of: 3) }
        let accent2 = clustered.theme.seriesColor(1)
        #expect(colors[1] == accent2, "中间那组就是主题色")
        let lum = colors.map { Int($0.r) + Int($0.g) + Int($0.b) }
        #expect(lum[0] < lum[1] && lum[1] < lum[2], "第一组最深、最后一组最浅")
        #expect(colors.allSatisfy { $0.r > $0.b }, "都还是同一种红")
        let stacked = try #require(main.first { $0.style == 13 })
        #expect(stacked.seriesColor(0, of: 2) != stacked.seriesColor(1, of: 2), "堆叠的两段分得开")
        // 没有样式、样式 2/10(彩色)沿用主题六色
        var plain = ChartSpec()
        #expect(plain.seriesColor(1, of: 3) == plain.theme.seriesColor(1))
        plain.style = 10
        #expect(plain.seriesColor(1, of: 3) == plain.theme.seriesColor(1))
    }

    @Test("Excel 2010 起样式写在 AlternateContent 里(c14:style = 编号 + 100)")
    func styleInAlternateContent() throws {
        let xml = """
            <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">
            <mc:AlternateContent><mc:Choice Requires="c14" xmlns:c14="http://schemas.microsoft.com/office/drawing/2007/8/2/chart"><c14:style val="112"/></mc:Choice><mc:Fallback><c:style val="12"/></mc:Fallback></mc:AlternateContent>
            <c:chart><c:plotArea/></c:chart></c:chartSpace>
            """
        #expect(ChartParser.parse(Data(xml.utf8))?.style == 12)
    }

    @Test("图片和整页图表")
    func picturesAndChartSheets() throws {
        let wb = try Self.workbook()
        let pics = try #require(wb.sheets.first { $0.name == "图片" }).drawings.flatMap(\.items)
        guard case .picture(let p)? = pics.first?.content else { Issue.record("没读到图片"); return }
        #expect(p.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        let cs = try #require(wb.sheets.first { $0.name == "整页图表" })
        #expect(cs.isChartSheet)
        #expect(Self.charts(cs).count == 1)
        #expect(cs.rows.count > 10 && cs.columnCount > 5, "整页图表也得有地方画")
    }

    /// Excel 自己写的图表带缓存;引用的表在这个文件里找不到时(比如图表是从别的文件粘过来的)
    /// 就用缓存。
    @Test("有缓存值、引用跟不过去:用缓存")
    func cachedValues() throws {
        let xml = """
            <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
            <c:chart><c:autoTitleDeleted val="0"/><c:plotArea><c:lineChart><c:grouping val="standard"/>
            <c:ser><c:idx val="0"/><c:order val="0"/><c:tx><c:strRef><c:f>别的表!$B$1</c:f><c:strCache><c:ptCount val="1"/><c:pt idx="0"><c:v>销量</c:v></c:pt></c:strCache></c:strRef></c:tx>
            <c:spPr><a:ln w="28575"><a:solidFill><a:schemeClr val="accent2"><a:lumMod val="75000"/></a:schemeClr></a:solidFill></a:ln></c:spPr>
            <c:cat><c:strRef><c:f>别的表!$A$2:$A$4</c:f><c:strCache><c:ptCount val="3"/><c:pt idx="0"><c:v>一</c:v></c:pt><c:pt idx="1"><c:v>二</c:v></c:pt><c:pt idx="2"><c:v>三</c:v></c:pt></c:strCache></c:strRef></c:cat>
            <c:val><c:numRef><c:f>别的表!$B$2:$B$4</c:f><c:numCache><c:formatCode>0.0</c:formatCode><c:ptCount val="3"/><c:pt idx="0"><c:v>1.5</c:v></c:pt><c:pt idx="2"><c:v>3</c:v></c:pt></c:numCache></c:numRef></c:val>
            </c:ser><c:axId val="1"/><c:axId val="2"/></c:lineChart>
            <c:catAx><c:axId val="1"/><c:axPos val="b"/><c:crossAx val="2"/></c:catAx>
            <c:valAx><c:axId val="2"/><c:axPos val="l"/><c:majorGridlines/><c:numFmt formatCode="0%" sourceLinked="0"/><c:crossAx val="1"/></c:valAx>
            </c:plotArea><c:legend><c:legendPos val="b"/></c:legend></c:chart></c:chartSpace>
            """
        let spec = try #require(ChartParser.parse(Data(xml.utf8)))
        let r = spec.resolved(using: Workbook(sheets: [Sheet(name: "其它", rows: [])], source: "t"))
        let s = r.plots[0].series[0]
        #expect(s.name == "销量")
        #expect(s.categories == ["一", "二", "三"])
        #expect(s.values == [1.5, nil, 3], "缺的点是空,不是 0")
        #expect(s.numberFormat == "0.0")
        #expect(spec.legend?.position == "b")
        let value = try #require(spec.axes.first { $0.kind == .value })
        #expect(value.majorGridlines && value.numberFormat == "0%" && !value.sourceLinked)
        // accent2 (ED7D31) 亮度乘 0.75
        let line = try #require(spec.plots[0].series[0].line)
        #expect(line != RGBA(hex: "ED7D31") && line.r > line.b)
        #expect(spec.plots[0].series[0].lineWidth == 2.25)
    }

    /// Excel 和 WPS 给单个点加标签时，写成系列整体关闭 + 这几个点各自打开。
    @Test("数据标签：只开几个点、位置和样式跟着点走，单独关掉的点不显示")
    func pointLabels() throws {
        let point = { (idx: Int, pos: String, on: Int) in
            """
            <c:dLbl><c:idx val="\(idx)"/><c:txPr><a:bodyPr/><a:p><a:pPr><a:defRPr sz="1400" b="1"><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></a:defRPr></a:pPr></a:p></c:txPr>\
            <c:dLblPos val="\(pos)"/><c:showVal val="\(on)"/></c:dLbl>
            """
        }
        let xml = """
            <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
            <c:chart><c:plotArea><c:lineChart><c:grouping val="standard"/>
            <c:ser><c:idx val="0"/><c:order val="0"/>
            <c:dLbls>\(point(1, "l", 1))\(point(7, "r", 1))<c:showVal val="0"/></c:dLbls>
            </c:ser>
            <c:ser><c:idx val="1"/><c:order val="1"/>
            <c:dLbls><c:dLbl><c:idx val="2"/><c:delete val="1"/></c:dLbl><c:dLblPos val="b"/><c:showVal val="1"/></c:dLbls>
            </c:ser>
            <c:axId val="1"/><c:axId val="2"/></c:lineChart></c:plotArea></c:chart></c:chartSpace>
            """
        let spec = try #require(ChartParser.parse(Data(xml.utf8)))
        let first = try #require(spec.plots[0].series[0].labels)
        #expect(!first.any && first.anyAtAll)
        #expect(first.at(0).any == false)
        let one = first.at(1)
        #expect(one.value && one.position == "l" && one.fontSize == 14 && one.bold == true)
        #expect(one.color == RGBA(hex: "FF0000"))
        #expect(first.at(7).position == "r")
        let second = try #require(spec.plots[0].series[1].labels)
        #expect(second.at(0).value && second.at(0).position == "b")
        #expect(second.at(2).any == false, "整个系列开着，这个点单独关掉")
    }

    @Test(
        "单元格引用",
        arguments: [
            ("'图表 分析'!$B$61:$B$68", "图表 分析", 60, 1, 67, 1),
            ("Sheet1!C3", "Sheet1", 2, 2, 2, 2),
            ("'It''s'!$A:$A", "It's", 0, 0, ChartReference.huge, 0),
        ])
    func references(text: String, sheet: String, r0: Int, c0: Int, r1: Int, c1: Int) throws {
        let ref = try #require(ChartReference(text))
        #expect(ref.areas == [ChartReference.Area(sheet: sheet, r0: r0, c0: c0, r1: r1, c1: c1)])
    }

    @Test("多块引用和外部文件")
    func multiAreaReferences() {
        #expect(ChartReference("(S!$A$1:$A$2,S!$C$1:$C$2)")?.areas.count == 2)
        #expect(ChartReference("[1]Sheet1!$A$1") == nil, "外部文件的引用跟不过去,交给缓存")
    }

    /// 文本框、组合里的形状、箭头线 —— 用户的表里常见的「说明框」。
    @Test("形状、文本框、组合")
    func shapes() throws {
        let xml = """
            <xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
            <xdr:twoCellAnchor><xdr:from><xdr:col>1</xdr:col><xdr:colOff>9525</xdr:colOff><xdr:row>2</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>
            <xdr:to><xdr:col>5</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>8</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>
            <xdr:sp><xdr:nvSpPr><xdr:cNvPr id="2" name="TextBox 1"/><xdr:cNvSpPr txBox="1"/></xdr:nvSpPr>
            <xdr:spPr><a:prstGeom prst="roundRect"/><a:solidFill><a:srgbClr val="FFF2CC"/></a:solidFill><a:ln w="12700"><a:solidFill><a:srgbClr val="BF9000"/></a:solidFill></a:ln></xdr:spPr>
            <xdr:txBody><a:bodyPr anchor="ctr"/><a:p><a:pPr algn="ctr"/><a:r><a:rPr sz="1400" b="1"><a:solidFill><a:srgbClr val="C00000"/></a:solidFill></a:rPr><a:t>注意:</a:t></a:r><a:r><a:t>华东下滑</a:t></a:r></a:p><a:p><a:r><a:t>第二行</a:t></a:r></a:p></xdr:txBody></xdr:sp>
            <xdr:clientData/></xdr:twoCellAnchor>
            <xdr:absoluteAnchor><xdr:pos x="0" y="0"/><xdr:ext cx="1905000" cy="952500"/>
            <xdr:grpSp><xdr:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1905000" cy="952500"/><a:chOff x="0" y="0"/><a:chExt cx="200" cy="100"/></a:xfrm></xdr:grpSpPr>
            <xdr:sp><xdr:spPr><a:xfrm><a:off x="100" y="0"/><a:ext cx="100" cy="50"/></a:xfrm><a:prstGeom prst="ellipse"/></xdr:spPr><xdr:style><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="3"><a:schemeClr val="accent1"/></a:fillRef><a:effectRef idx="0"><a:schemeClr val="accent1"/></a:effectRef><a:fontRef idx="minor"><a:schemeClr val="lt1"/></a:fontRef></xdr:style></xdr:sp>
            <xdr:cxnSp><xdr:spPr><a:xfrm><a:off x="0" y="50"/><a:ext cx="100" cy="50"/></a:xfrm><a:prstGeom prst="straightConnector1"/><a:ln><a:tailEnd type="triangle"/></a:ln></xdr:spPr></xdr:cxnSp>
            </xdr:grpSp><xdr:clientData/></xdr:absoluteAnchor>
            </xdr:wsDr>
            """
        let drawings = DrawingParser.parse(Data(xml.utf8), path: "xl/drawings/drawing1.xml", theme: .office) { _ in nil }
        #expect(drawings.count == 2)
        let box = drawings[0]
        #expect(box.anchor.from?.colOffset == 1 && box.anchor.to == DrawingAnchor.Marker(row: 8, col: 5))
        guard case .shape(let s) = box.items[0].content else { Issue.record("不是形状"); return }
        #expect(s.geometry == "roundRect" && s.fill == RGBA(hex: "FFF2CC") && s.line?.color == RGBA(hex: "BF9000"))
        #expect(s.verticalAnchor == "ctr")
        #expect(s.paragraphs.map(\.text) == ["注意:华东下滑", "第二行"])
        #expect(s.paragraphs[0].alignment == "ctr" && s.paragraphs[0].runs[0].bold && s.paragraphs[0].runs[0].size == 14)
        #expect(s.paragraphs[0].runs[0].color == RGBA(hex: "C00000"))

        let group = drawings[1]
        #expect(group.anchor.x == 0 && group.anchor.width == 200)
        #expect(group.items.count == 2)
        #expect(group.items[0].frame == UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5), "组合里的子形状按比例放")
        guard case .shape(let ellipse) = group.items[0].content, case .shape(let arrow) = group.items[1].content else { Issue.record("组合没展开"); return }
        #expect(ellipse.geometry == "ellipse" && ellipse.fill == DrawingTheme.office.scheme("accent1"), "spPr 没写填充就用样式里的主题色")
        #expect(arrow.isLine && arrow.line?.tailArrow == true)
    }

    @Test("关系路径")
    func relsPaths() {
        #expect(OfficeRels.relsPath(for: "xl/worksheets/sheet3.xml") == "xl/worksheets/_rels/sheet3.xml.rels")
        #expect(OfficeRels.resolve("../charts/chart1.xml", from: "xl/drawings/drawing1.xml") == "xl/charts/chart1.xml")
        #expect(OfficeRels.resolve("/xl/media/image1.png", from: "xl/drawings/drawing1.xml") == "xl/media/image1.png")
    }
}
