import Foundation

/// Reads a DrawingML chart part (`xl/charts/chartN.xml`, also used inside Word and
/// PowerPoint files) into a ChartSpec. Unknown chart kinds are skipped, not fatal.
public enum ChartParser {
    public static func parse(_ data: Data, theme: DrawingTheme = .office) -> ChartSpec? {
        guard let root = XMLTree.parse(data) else { return nil }
        return parse(root, theme: theme)
    }

    static func parse(_ root: XMLTree, theme: DrawingTheme) -> ChartSpec? {
        guard let chart = root.name == "chart" ? root : root.child("chart") else { return nil }
        var spec = ChartSpec()
        spec.theme = theme
        spec.style = style(root)
        spec.title = chart.child("title").map { text(of: $0, theme: theme) }
        spec.autoTitleDeleted = chart.value(of: "autoTitleDeleted").map(flag) ?? false
        spec.displayBlanksAs = chart.value(of: "dispBlanksAs") ?? "gap"
        if case .solid(let c)? = DrawingStyle.fill(in: root.child("spPr"), theme: theme) { spec.background = c }
        if let l = chart.child("legend") {
            var legend = ChartLegend()
            legend.position = l.value(of: "legendPos") ?? "r"
            legend.overlay = l.value(of: "overlay").map(flag) ?? false
            for e in l.children("legendEntry") where e.value(of: "delete").map(flag) == true {
                if let i = e.value(of: "idx").flatMap(Int.init) { legend.hiddenEntries.insert(i) }
            }
            spec.legend = legend
        }
        guard let area = chart.child("plotArea") else { return spec }
        if case .solid(let c)? = DrawingStyle.fill(in: area.child("spPr"), theme: theme) { spec.plotBackground = c }
        for node in area.children {
            if let plot = plot(node, theme: theme) { spec.plots.append(plot) }
            if let axis = axis(node, theme: theme) { spec.axes.append(axis) }
        }
        return spec
    }

    /// `c:style`, written plain or (by Excel 2010 on) as the fallback of an
    /// `mc:AlternateContent` whose preferred choice is `c14:style` (the same number + 100).
    static func style(_ root: XMLTree) -> Int? {
        for node in root.children {
            if node.name == "style", let v = node["val"].flatMap(Int.init) { return v > 100 ? v - 100 : v }
            if node.name == "AlternateContent" {
                for branch in node.children {
                    if let v = branch.child("style")?["val"].flatMap(Int.init) { return v > 100 ? v - 100 : v }
                }
            }
        }
        return nil
    }

    // MARK: Plots

    private static let kinds: [String: ChartKind] = [
        "barChart": .bar, "bar3DChart": .bar, "lineChart": .line, "line3DChart": .line, "stockChart": .line,
        "areaChart": .area, "area3DChart": .area, "pieChart": .pie, "pie3DChart": .pie, "ofPieChart": .pie,
        "doughnutChart": .doughnut, "scatterChart": .scatter, "radarChart": .radar, "bubbleChart": .bubble,
    ]

    static func plot(_ node: XMLTree, theme: DrawingTheme) -> ChartPlot? {
        guard let kind = kinds[node.name] else { return nil }
        var p = ChartPlot(kind: kind)
        p.horizontal = node.value(of: "barDir") == "bar"
        if let g = node.value(of: "grouping") { p.grouping = g } else if kind == .line || kind == .area { p.grouping = "standard" }
        p.varyColors = node.value(of: "varyColors").map(flag) ?? (kind == .pie || kind == .doughnut)
        if let v = node.value(of: "gapWidth").flatMap(Double.init) { p.gapWidth = v }
        if let v = node.value(of: "overlap").flatMap(Double.init) { p.overlap = v } else if p.isStacked { p.overlap = 100 }
        if let v = node.value(of: "holeSize").flatMap(Double.init) { p.holeSize = v }
        if let v = node.value(of: "firstSliceAng").flatMap(Double.init) { p.firstSliceAngle = v }
        if kind == .line { p.markers = node.value(of: "marker").map(flag) ?? true }
        if kind == .scatter {
            let style = node.value(of: "scatterStyle") ?? "lineMarker"
            p.markers = style != "line" && style != "smooth"
            p.scatterLines = style != "marker"
        }
        if kind == .radar { p.radarFilled = node.value(of: "radarStyle") == "filled" }
        p.axisIDs = node.children("axId").compactMap { $0["val"] }
        p.labels = labels(node.child("dLbls"), theme: theme) ?? ChartLabels()
        for (i, s) in node.children("ser").enumerated() {
            p.series.append(series(s, kind: kind, position: i, theme: theme))
        }
        // Series are drawn in `order`, which can differ from document order.
        let order: [Int] = node.children("ser").map { Int($0.value(of: "order") ?? "") ?? 0 }
        p.series = p.series.indices.sorted { (order[$0], $0) < (order[$1], $1) }.map { p.series[$0] }
        return p
    }

    static func series(_ s: XMLTree, kind: ChartKind, position: Int, theme: DrawingTheme) -> ChartSeries {
        var out = ChartSeries()
        if let tx = s.child("tx") {
            if let r = tx.child("strRef") {
                out.name = ChartText(text: r.child("strCache").flatMap { firstPoint($0) }, reference: r.child("f")?.text)
            } else if let v = tx.child("v") {
                out.name = ChartText(text: v.text)
            }
        }
        out.categories = values(s.child("cat") ?? s.child("xVal"))
        out.values = values(s.child("val") ?? s.child("yVal"))
        out.bubbleSizes = values(s.child("bubbleSize"))
        let spPr = s.child("spPr")
        switch DrawingStyle.fill(in: spPr, theme: theme) {
        case .solid(let c)?: out.fill = c
        case .none?: out.noFill = true
        case nil: break
        }
        if let line = DrawingStyle.line(in: spPr, theme: theme) {
            out.line = line.color
            out.lineWidth = line.width
            out.noLine = line.none
            out.dashed = line.dashed
        }
        if let m = s.child("marker") {
            out.marker = m.value(of: "symbol")
            out.markerSize = m.value(of: "size").flatMap(Double.init)
        }
        out.smooth = s.value(of: "smooth").map(flag) ?? false
        for d in s.children("dPt") {
            guard let i = d.value(of: "idx").flatMap(Int.init) else { continue }
            if case .solid(let c)? = DrawingStyle.fill(in: d.child("spPr"), theme: theme) { out.pointColors[i] = c }
        }
        out.labels = labels(s.child("dLbls"), theme: theme)
        return out
    }

    private static func labels(_ node: XMLTree?, theme: DrawingTheme, inheriting base: ChartLabels? = nil) -> ChartLabels? {
        guard let node else { return nil }
        if node.value(of: "delete").map(flag) == true { return ChartLabels() }
        var l = ChartLabels()
        l.value = node.value(of: "showVal").map(flag) ?? base?.value ?? false
        l.percent = node.value(of: "showPercent").map(flag) ?? base?.percent ?? false
        l.category = node.value(of: "showCatName").map(flag) ?? base?.category ?? false
        l.seriesName = node.value(of: "showSerName").map(flag) ?? base?.seriesName ?? false
        l.numberFormat = node.child("numFmt")?["formatCode"] ?? base?.numberFormat
        l.position = node.value(of: "dLblPos") ?? base?.position
        l.fontSize = base?.fontSize
        l.bold = base?.bold
        l.color = base?.color
        if let d = node.child("txPr")?.descendants("defRPr").first {
            if let v = d["sz"].flatMap(Double.init) { l.fontSize = v / 100 }
            if let v = d["b"] { l.bold = flag(v) }
            if let v = DrawingStyle.color(in: d.child("solidFill"), theme: theme) { l.color = v }
        }
        for d in node.children("dLbl") {
            guard let i = d.value(of: "idx").flatMap(Int.init) else { continue }
            l.points[i] = labels(d, theme: theme, inheriting: l)
        }
        return l
    }

    /// `cat` / `val` / `xVal` / `yVal`: a reference (num / str / multi-level) or literal values.
    static func values(_ node: XMLTree?) -> ChartValues? {
        guard let node else { return nil }
        var v = ChartValues()
        if let r = node.child("numRef") {
            v.reference = r.child("f")?.text
            if let c = r.child("numCache") { readCache(c, into: &v, numeric: true) }
        } else if let r = node.child("strRef") {
            v.numeric = false
            v.reference = r.child("f")?.text
            if let c = r.child("strCache") { readCache(c, into: &v, numeric: false) }
        } else if let r = node.child("multiLvlStrRef") {
            v.numeric = false
            v.reference = r.child("f")?.text
            if let c = r.child("multiLvlStrCache") {
                // Innermost level first in the file; label each point with the levels joined.
                v.cachedCount = c.value(of: "ptCount").flatMap(Int.init) ?? 0
                for lvl in c.children("lvl").reversed() {
                    for pt in lvl.children("pt") {
                        guard let i = pt["idx"].flatMap(Int.init) else { continue }
                        let t = pt.child("v")?.text ?? ""
                        v.cachedText[i] = v.cachedText[i].map { $0.isEmpty ? t : $0 + " " + t } ?? t
                    }
                }
            }
        } else if let lit = node.child("numLit") {
            readCache(lit, into: &v, numeric: true)
        } else if let lit = node.child("strLit") {
            v.numeric = false
            readCache(lit, into: &v, numeric: false)
        } else {
            return nil
        }
        return v
    }

    private static func readCache(_ c: XMLTree, into v: inout ChartValues, numeric: Bool) {
        v.cachedCount = c.value(of: "ptCount").flatMap(Int.init) ?? 0
        if let f = c.child("formatCode")?.text, !f.isEmpty { v.numberFormat = f }
        for pt in c.children("pt") {
            guard let i = pt["idx"].flatMap(Int.init) else { continue }
            let t = pt.child("v")?.text ?? ""
            v.cachedText[i] = t
            if let d = Double(t) { v.cachedNumbers[i] = d }
            v.cachedCount = max(v.cachedCount, i + 1)
        }
    }

    private static func firstPoint(_ cache: XMLTree) -> String? {
        cache.children("pt").first?.child("v")?.text
    }

    // MARK: Axes

    static func axis(_ node: XMLTree, theme: DrawingTheme) -> ChartAxis? {
        let kind: ChartAxis.Kind
        switch node.name {
        case "catAx": kind = .category
        case "valAx": kind = .value
        case "dateAx": kind = .date
        case "serAx": kind = .series
        default: return nil
        }
        var a = ChartAxis(id: node.value(of: "axId") ?? UUID().uuidString, kind: kind)
        a.position = node.value(of: "axPos") ?? (kind == .value ? "l" : "b")
        a.deleted = node.value(of: "delete").map(flag) ?? false
        a.title = node.child("title").map { text(of: $0, theme: theme) }
        if let f = node.child("numFmt") {
            a.numberFormat = f["formatCode"]
            a.sourceLinked = f["sourceLinked"].map(flag) ?? false
        }
        if let s = node.child("scaling") {
            a.min = s.value(of: "min").flatMap(Double.init)
            a.max = s.value(of: "max").flatMap(Double.init)
            a.reversed = s.value(of: "orientation") == "maxMin"
            a.logBase = s.value(of: "logBase").flatMap(Double.init)
        }
        a.majorUnit = node.value(of: "majorUnit").flatMap(Double.init)
        a.majorGridlines = node.child("majorGridlines") != nil
        a.crossAxis = node.value(of: "crossAx")
        a.labelsShown = node.value(of: "tickLblPos") != "none"
        return a
    }

    // MARK: Text

    /// A `title` (or `tx`) with rich text or a cell reference.
    static func text(of node: XMLTree, theme: DrawingTheme) -> ChartText {
        var t = ChartText()
        let tx = node.child("tx") ?? node
        if let rich = tx.child("rich") {
            let paragraphs = rich.children("p").map { p in p.descendants("t").map(\.text).joined() }
            t.text = paragraphs.joined(separator: "\n")
            if let r = rich.descendants("rPr").first ?? rich.descendants("defRPr").first {
                t.size = r["sz"].flatMap(Double.init).map { $0 / 100 }
                t.bold = r["b"].map(flag)
                t.color = DrawingStyle.color(in: r.child("solidFill"), theme: theme)
            }
        } else if let r = tx.child("strRef") {
            t.reference = r.child("f")?.text
            t.text = r.child("strCache").flatMap { firstPoint($0) }
        }
        if t.size == nil, let d = node.child("txPr")?.descendants("defRPr").first {
            t.size = d["sz"].flatMap(Double.init).map { $0 / 100 }
            t.bold = t.bold ?? d["b"].map(flag)
        }
        return t
    }

    static func flag(_ s: String) -> Bool { s == "1" || s == "true" }
}
