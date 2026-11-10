import AppKit
import PerlustraCore

/// Draws a resolved Office chart into a rectangle of a flipped view (y grows downwards).
/// Not tied to the spreadsheet: anything that has a ResolvedChart and a rectangle can use it.
@MainActor
struct ChartPainter {
    let chart: ResolvedChart
    /// Zoom: 1 = the chart's own size in Excel's screen pixels.
    let scale: CGFloat

    var spec: ChartSpec { chart.spec }
    var theme: DrawingTheme { spec.theme }

    // MARK: Entry

    func draw(in rect: CGRect) {
        guard rect.width > 4, rect.height > 4, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        cardColor.setFill()
        rect.fill()
        frameColor.setStroke()
        let frame = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        frame.stroke()

        var area = rect.insetBy(dx: 10 * scale, dy: 8 * scale)
        if let title = chart.title, !title.isEmpty {
            let t = spec.title
            let font = NSFont.systemFont(ofSize: px(t?.size ?? 14), weight: (t?.bold ?? true) ? .semibold : .regular)
            let h = drawText(
                title, font: font, color: t?.color.map(readable) ?? (isDark ? Theme.ink : NSColor(white: 0.25, alpha: 1)),
                in: CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height * 0.3), align: .center)
            area.origin.y += h + 6 * scale
            area.size.height -= h + 6 * scale
        }
        if let legend = spec.legend, !legendEntries.isEmpty, area.height > 30 * scale {
            area = drawLegend(legend, in: area)
        }
        guard area.width > 20, area.height > 20 else { ctx.restoreGState(); return }
        let radial = chart.plots.filter { $0.plot.kind == .pie || $0.plot.kind == .doughnut }
        let radar = chart.plots.filter { $0.plot.kind == .radar }
        let cartesian = chart.plots.filter { ![.pie, .doughnut, .radar].contains($0.plot.kind) }
        if let p = radial.first, cartesian.isEmpty {
            drawPie(p, in: area)
        } else if let p = radar.first, cartesian.isEmpty {
            drawRadar(p, in: area)
        } else if !cartesian.isEmpty {
            drawCartesian(cartesian, in: area)
        } else {
            drawEmpty(in: area)
        }
        ctx.restoreGState()
    }

    // MARK: Helpers

    func px(_ pt: Double) -> CGFloat { CGFloat(pt) * 4 / 3 * scale }
    var labelFont: NSFont { NSFont.systemFont(ofSize: px(9)) }
    var labelColor: NSColor { isDark ? NSColor(white: 1, alpha: 0.72) : NSColor(white: 0.35, alpha: 1) }

    // MARK: Colours on black

    /// A chart with no colours of its own, or Office's default white, goes dark with the theme: a
    /// white card glares on a black page. One given a real colour keeps it.
    var isDark: Bool { NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    var cardColor: NSColor {
        guard isDark else { return spec.background.map(ns) ?? .white }
        guard let b = spec.background, Self.luminance(b) < 0.9 else { return NSColor(hex: 0x141417) }
        return ns(b)
    }

    var frameColor: NSColor { isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0.85, alpha: 1) }
    var gridColor: NSColor { isDark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0.88, alpha: 1) }
    var axisColor: NSColor { isDark ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0.75, alpha: 1) }

    /// Text given a dark colour for a white card would vanish on a black one.
    func readable(_ c: RGBA) -> NSColor {
        guard isDark, Self.luminance(c) < 0.4, cardColor.brightnessComponentOrZero < 0.5 else { return ns(c) }
        return Int(max(c.r, c.g, c.b)) - Int(min(c.r, c.g, c.b)) < 48 ? Theme.ink : (ns(c).blended(withFraction: 0.45, of: .white) ?? ns(c))
    }

    private static func luminance(_ c: RGBA) -> Double {
        (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
    }

    func ns(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    /// Fill of a bar, area, slice or bubble. A series' outline is not its fill: openpyxl and
    /// Excel's styles give bars a thin white edge and leave the fill to the chart style.
    func color(_ s: ResolvedSeries) -> NSColor {
        ns(s.series.fill ?? styleColor(s.index))
    }

    func lineColor(_ s: ResolvedSeries) -> NSColor {
        ns(s.series.line ?? s.series.fill ?? styleColor(s.index))
    }

    /// The chart style's colour for series `i`, spread over every series in the chart.
    func styleColor(_ i: Int) -> RGBA {
        spec.seriesColor(i, of: chart.plots.reduce(0) { $0 + $1.series.count })
    }

    /// Colour of point `i` when a single series varies its colours (pies, `varyColors`).
    func pointColor(_ i: Int, of count: Int) -> RGBA { spec.seriesColor(i, of: count) }

    @discardableResult
    func drawText(_ s: String, font: NSFont, color: NSColor, in r: CGRect, align: NSTextAlignment) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = ceil(str.boundingRect(with: CGSize(width: max(1, r.width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
        str.draw(with: CGRect(x: r.minX, y: r.minY, width: r.width, height: min(h, r.height)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return min(h, r.height)
    }

    func size(_ s: String, _ font: NSFont) -> CGSize { (s as NSString).size(withAttributes: [.font: font]) }

    func label(_ s: String, at p: CGPoint, anchor: (x: CGFloat, y: CGFloat), font: NSFont? = nil, color: NSColor? = nil) {
        let f = font ?? labelFont
        let sz = size(s, f)
        (s as NSString).draw(
            at: CGPoint(x: p.x - sz.width * anchor.x, y: p.y - sz.height * anchor.y),
            withAttributes: [.font: f, .foregroundColor: color ?? labelColor])
    }

    func format(_ v: Double, _ code: String?) -> String {
        guard let code, !code.isEmpty, code != "General" else {
            if abs(v) >= 10000 || v == v.rounded() { return NumberFormat.format(.number(v), code: "#,##0").text }
            return NumberFormat.format(.number(v), code: abs(v) < 1 ? "0.###" : "#,##0.##").text
        }
        return NumberFormat.format(.number(v), code: code).text
    }

    /// What a data label says, and how it looks.
    func labelText(_ l: ChartLabels, value: Double, series s: ResolvedSeries, category: String?, total: Double?) -> String {
        var parts: [String] = []
        if l.seriesName { parts.append(s.name) }
        if l.category, let category { parts.append(category) }
        if l.value { parts.append(format(value, l.numberFormat ?? s.numberFormat)) }
        if l.percent, let total, total > 0 { parts.append(format(value / total, "0%")) }
        return parts.joined(separator: ", ")
    }

    func font(of l: ChartLabels) -> NSFont? {
        guard l.fontSize != nil || l.bold != nil else { return nil }
        let size = l.fontSize.map { px(CGFloat($0)) } ?? labelFont.pointSize
        return l.bold == true ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    }

    /// A label beside a point, on the side the file asks for (above unless it says otherwise).
    func pointLabel(_ text: String, at q: CGPoint, _ l: ChartLabels) {
        let gap = 5 * scale
        let (at, anchor): (CGPoint, (x: CGFloat, y: CGFloat))
        switch l.position {
        case "l": (at, anchor) = (CGPoint(x: q.x - gap, y: q.y), (1, 0.5))
        case "r": (at, anchor) = (CGPoint(x: q.x + gap, y: q.y), (0, 0.5))
        case "b": (at, anchor) = (CGPoint(x: q.x, y: q.y + gap), (0.5, 0))
        case "ctr": (at, anchor) = (q, (0.5, 0.5))
        default: (at, anchor) = (CGPoint(x: q.x, y: q.y - gap), (0.5, 1))
        }
        label(text, at: at, anchor: anchor, font: font(of: l), color: l.color.map(readable))
    }

    func drawEmpty(in r: CGRect) {
        label("没有可画的数据", at: CGPoint(x: r.midX, y: r.midY), anchor: (0.5, 0.5))
    }

    // MARK: Legend

    var legendEntries: [(String, NSColor, Bool)] {
        let hidden = spec.legend?.hiddenEntries ?? []
        if chart.plots.count == 1, let p = chart.plots.first, p.plot.varyColors || p.plot.kind == .pie || p.plot.kind == .doughnut, p.series.count == 1 {
            let s = p.series[0]
            return p.categories.indices.filter { !hidden.contains($0) }.map { i in
                (p.categories[i], ns(s.series.pointColors[i] ?? pointColor(i, of: p.categories.count)), false)
            }
        }
        var out: [(String, NSColor, Bool)] = []
        var i = 0
        for p in chart.plots {
            for s in p.series {
                defer { i += 1 }
                if hidden.contains(i) { continue }
                let isLine = p.plot.kind == .line || (p.plot.kind == .scatter && !s.series.noLine)
                out.append((s.name, isLine ? lineColor(s) : color(s), isLine))
            }
        }
        return out
    }

    /// Draws the legend at its position and returns the area left for the plot.
    func drawLegend(_ legend: ChartLegend, in area: CGRect) -> CGRect {
        let entries = legendEntries
        let font = labelFont
        let sw = 9 * scale, gap = 5 * scale, pad = 12 * scale
        let rowH = max(size("国", font).height, sw) + 3 * scale
        func swatch(_ c: NSColor, _ line: Bool, at p: CGPoint) {
            c.setFill()
            if line {
                CGRect(x: p.x, y: p.y + sw / 2 - 1 * scale, width: sw * 1.6, height: 2 * scale).fill()
            } else {
                CGRect(x: p.x, y: p.y, width: sw, height: sw).fill()
            }
        }
        let vertical = legend.position == "r" || legend.position == "l" || legend.position == "tr"
        if vertical {
            let w = min(area.width * 0.35, (entries.map { size($0.0, font).width }.max() ?? 0) + sw * 1.6 + gap + pad)
            let totalH = CGFloat(entries.count) * rowH
            let x = legend.position == "l" ? area.minX : area.maxX - w
            var y = legend.position == "tr" ? area.minY : area.midY - min(totalH, area.height) / 2
            for e in entries where y + rowH <= area.maxY + 1 {
                swatch(e.1, e.2, at: CGPoint(x: x + pad / 2, y: y + (rowH - sw) / 2))
                let lx = x + pad / 2 + sw * 1.6 + gap
                drawText(
                    e.0, font: font, color: labelColor,
                    in: CGRect(x: lx, y: y + (rowH - size("国", font).height) / 2 - 1, width: max(1, x + w - lx), height: rowH), align: .left)
                y += rowH
            }
            if legend.overlay { return area }
            return legend.position == "l"
                ? CGRect(x: area.minX + w, y: area.minY, width: area.width - w, height: area.height)
                : CGRect(x: area.minX, y: area.minY, width: area.width - w, height: area.height)
        }
        // Top / bottom: entries flow in lines, centred.
        var lines: [[(String, NSColor, Bool, CGFloat)]] = [[]]
        var lineW: CGFloat = 0
        for e in entries {
            let w = sw * 1.6 + gap + size(e.0, font).width + pad
            if lineW + w > area.width && !(lines.last?.isEmpty ?? true) { lines.append([]); lineW = 0 }
            lines[lines.count - 1].append((e.0, e.1, e.2, w))
            lineW += w
        }
        let h = CGFloat(lines.count) * rowH + 4 * scale
        var y = legend.position == "t" ? area.minY : area.maxY - h + 2 * scale
        for line in lines {
            var x = area.midX - line.reduce(0) { $0 + $1.3 } / 2
            for e in line {
                swatch(e.1, e.2, at: CGPoint(x: x, y: y + (rowH - sw) / 2))
                label(e.0, at: CGPoint(x: x + sw * 1.6 + gap, y: y + rowH / 2), anchor: (0, 0.5))
                x += e.3
            }
            y += rowH
        }
        if legend.overlay { return area }
        return legend.position == "t"
            ? CGRect(x: area.minX, y: area.minY + h, width: area.width, height: area.height - h)
            : CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - h)
    }

    // MARK: Axes and scales

    struct Scale {
        var min: Double, max: Double, step: Double
        var ticks: [Double] {
            guard step > 0, max > min else { return [min] }
            var out: [Double] = []
            var v = min
            while v <= max + step * 1e-9 && out.count < 50 { out.append(abs(v) < step * 1e-9 ? 0 : v); v += step }
            return out
        }
        func pos(_ v: Double) -> Double { max > min ? (v - min) / (max - min) : 0 }
    }

    /// Round tick values covering the data, starting at zero when the data allows (as Excel does).
    static func niceScale(_ lo: Double, _ hi: Double, fixedMin: Double? = nil, fixedMax: Double? = nil, unit: Double? = nil, targetTicks: Int = 6) -> Scale {
        var a = fixedMin ?? min(lo, 0), b = fixedMax ?? max(hi, 0)
        if fixedMin == nil && lo > 0 && hi > 0 && (hi - lo) / hi < 0.16 { a = lo }  // all values close together: don't start at 0
        if a == b { b = a == 0 ? 1 : a + abs(a) * 0.5 }
        let raw = (b - a) / Double(max(2, targetTicks - 1))
        let mag = pow(10, floor(log10(raw)))
        let step = unit ?? ([1, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? 10 * mag)
        let lo2 = fixedMin ?? (floor(a / step) * step)
        let hi2 = fixedMax ?? (ceil(b / step) * step)
        return Scale(min: lo2, max: hi2 == lo2 ? lo2 + step : hi2, step: step)
    }

    func axis(_ id: String?) -> ChartAxis? { spec.axes.first { $0.id == id } }

}
