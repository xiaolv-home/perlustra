import AppKit
import PerlustraCore

/// Pie, doughnut and radar charts.
extension ChartPainter {
    // MARK: Pie and doughnut

    func drawPie(_ p: ResolvedPlot, in area: CGRect) {
        guard let s = p.series.first else { return drawEmpty(in: area) }
        let values = s.values.map { max(0, $0 ?? 0) }
        let total = values.reduce(0, +)
        guard total > 0 else { return drawEmpty(in: area) }
        let labels = s.series.labels ?? p.plot.labels
        let pad: CGFloat = labels.anyAtAll ? 26 * scale : 6 * scale
        let radius = max(4, min(area.width, area.height) / 2 - pad)
        let c = CGPoint(x: area.midX, y: area.midY)
        let hole = p.plot.kind == .doughnut ? CGFloat(p.plot.holeSize) / 100 * radius : 0
        // Excel starts at 12 o'clock and goes clockwise; the view is flipped, so angles grow clockwise.
        var angle = -90 + p.plot.firstSliceAngle
        for (i, v) in values.enumerated() where v > 0 {
            let sweep = v / total * 360
            let path = NSBezierPath()
            if hole > 0 {
                path.appendArc(withCenter: c, radius: radius, startAngle: CGFloat(angle), endAngle: CGFloat(angle + sweep), clockwise: false)
                path.appendArc(withCenter: c, radius: hole, startAngle: CGFloat(angle + sweep), endAngle: CGFloat(angle), clockwise: true)
            } else {
                path.move(to: c)
                path.appendArc(withCenter: c, radius: radius, startAngle: CGFloat(angle), endAngle: CGFloat(angle + sweep), clockwise: false)
            }
            path.close()
            ns(s.series.pointColors[i] ?? pointColor(i, of: values.count)).setFill()
            path.fill()
            (isDark ? cardColor : NSColor.white).setStroke()
            path.lineWidth = 1.2 * scale
            path.stroke()
            let l = labels.at(i)
            if l.any {
                var parts: [String] = []
                if l.category, i < p.categories.count { parts.append(p.categories[i]) }
                if l.value { parts.append(format(v, l.numberFormat ?? s.numberFormat)) }
                if l.percent { parts.append(format(v / total, "0%")) }
                let mid = (angle + sweep / 2) * .pi / 180
                let rr = hole > 0 ? (radius + hole) / 2 : radius * 0.68
                label(
                    parts.joined(separator: " "), at: CGPoint(x: c.x + CGFloat(cos(mid)) * rr, y: c.y + CGFloat(sin(mid)) * rr), anchor: (0.5, 0.5),
                    font: font(of: l), color: l.color.map(ns) ?? .white)
            }
            angle += sweep
        }
    }

    // MARK: Radar

    func drawRadar(_ p: ResolvedPlot, in area: CGRect) {
        let n = p.categories.count
        guard n >= 3 else { return drawEmpty(in: area) }
        let all = p.series.flatMap(\.values).compactMap { $0 }
        let sc = Self.niceScale(min(0, all.min() ?? 0), all.max() ?? 1, targetTicks: 5)
        let labelH = size("国", labelFont).height
        let radius = max(4, min(area.width, area.height) / 2 - labelH * 2)
        let c = CGPoint(x: area.midX, y: area.midY)
        func point(_ i: Int, _ v: Double) -> CGPoint {
            let a = -Double.pi / 2 + Double(i) / Double(n) * 2 * .pi
            let r = radius * CGFloat(sc.pos(v))
            return CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
        }
        frameColor.setStroke()
        for t in sc.ticks where t > sc.min {
            let ring = NSBezierPath()
            for i in 0..<n { let q = point(i, t); if i == 0 { ring.move(to: q) } else { ring.line(to: q) } }
            ring.close(); ring.lineWidth = 1; ring.stroke()
        }
        for i in 0..<n {
            // Set every time: the category label drawn below changes the current colours.
            frameColor.setStroke()
            let spoke = NSBezierPath(); spoke.move(to: c); spoke.line(to: point(i, sc.max)); spoke.lineWidth = 1; spoke.stroke()
            let q = point(i, sc.max)
            let dx = q.x - c.x, dy = q.y - c.y
            label(
                p.categories[i], at: CGPoint(x: q.x + dx * 0.08, y: q.y + dy * 0.08),
                anchor: (dx < -1 ? 1 : (dx > 1 ? 0 : 0.5), dy < -1 ? 1 : (dy > 1 ? 0 : 0.5)))
        }
        for s in p.series {
            let path = NSBezierPath()
            for i in 0..<n {
                let q = point(i, i < s.values.count ? (s.values[i] ?? 0) : 0)
                if i == 0 { path.move(to: q) } else { path.line(to: q) }
            }
            path.close()
            if p.plot.radarFilled { color(s).withAlphaComponent(0.45).setFill(); path.fill() }
            lineColor(s).setStroke()
            path.lineWidth = 2 * scale
            path.stroke()
        }
    }
}
