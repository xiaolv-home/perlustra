import AppKit
import PerlustraCore

/// Bars, lines, areas and scatter plots, with their axes.
extension ChartPainter {
    // MARK: Cartesian (bar, line, area, scatter, bubble)

    struct Group {
        var plots: [ResolvedPlot]
        var axis: ChartAxis?
        var scale: Scale
        var secondary: Bool
        /// The first plot is a 100% stacked one: its axis reads in percent.
        var plot0Percent: Bool { plots.first?.plot.isPercent ?? false }
    }

    func range(_ p: ResolvedPlot) -> (Double, Double) {
        if p.plot.isPercent { return (p.series.flatMap(\.values).contains { ($0 ?? 0) < 0 } ? -1 : 0, 1) }
        if p.plot.isStacked && (p.plot.kind == .bar || p.plot.kind == .area || p.plot.kind == .line) {
            var lo = 0.0, hi = 0.0
            let n = p.series.map(\.values.count).max() ?? 0
            for i in 0..<n {
                var pos = 0.0, neg = 0.0
                for s in p.series { let v = i < s.values.count ? (s.values[i] ?? 0) : 0; if v >= 0 { pos += v } else { neg += v } }
                hi = max(hi, pos); lo = min(lo, neg)
            }
            return (lo, hi)
        }
        let all = p.series.flatMap(\.values).compactMap { $0 }
        return (all.min() ?? 0, all.max() ?? 1)
    }

    func drawCartesian(_ plots: [ResolvedPlot], in area: CGRect) {
        let horizontal = plots.contains { $0.plot.kind == .bar && $0.plot.horizontal }
        let xyPlots = plots.filter { $0.plot.kind == .scatter || $0.plot.kind == .bubble }
        let primaryCats = plots.first { $0.plot.kind != .scatter && $0.plot.kind != .bubble }?.categories ?? plots[0].categories
        let catCount = max(1, primaryCats.count)

        // Value axes: plots sharing a value axis share a scale; a second axis goes on the far side.
        var groups: [Group] = []
        for p in plots {
            let valID = p.plot.axisIDs.count > 1 ? p.plot.axisIDs[1] : nil
            if let i = groups.firstIndex(where: { $0.axis?.id == valID && valID != nil }) { groups[i].plots.append(p); continue }
            let ax = axis(valID)
            groups.append(Group(plots: [p], axis: ax, scale: Scale(min: 0, max: 1, step: 0.2), secondary: !groups.isEmpty))
        }
        for i in groups.indices {
            let lo = groups[i].plots.map { range($0).0 }.min() ?? 0, hi = groups[i].plots.map { range($0).1 }.max() ?? 1
            let a = groups[i].axis
            groups[i].scale = Self.niceScale(
                lo, hi, fixedMin: a?.min, fixedMax: a?.max, unit: a?.majorUnit,
                targetTicks: max(3, Int((horizontal ? area.width : area.height) / (40 * scale))))
        }
        // Scatter: x is a value axis too.
        var xScale: Scale?
        if !xyPlots.isEmpty {
            let xs = xyPlots.flatMap { $0.series }.flatMap { s in s.xValues ?? s.values.indices.map { Double($0 + 1) } }.compactMap { $0 }
            let ax = axis(xyPlots[0].plot.axisIDs.first)
            xScale = Self.niceScale(
                xs.min() ?? 0, xs.max() ?? 1, fixedMin: ax?.min, fixedMax: ax?.max, unit: ax?.majorUnit,
                targetTicks: max(3, Int(area.width / (70 * scale))))
        }

        let catAxis = axis(plots[0].plot.axisIDs.first)
        let font = labelFont
        let lineH = size("国", font).height
        func fmt(_ g: Group, _ v: Double) -> String {
            let code = (g.axis?.sourceLinked == false ? g.axis?.numberFormat : nil) ?? g.plots.first?.series.first?.numberFormat
            return format(v, g.plot0Percent ? "0%" : code)
        }
        // Room for tick labels.
        let primary = groups[0]
        let secondary = groups.count > 1 ? groups[1] : nil
        let valLabelW = { (g: Group?) -> CGFloat in
            guard let g, g.axis?.deleted != true, g.axis?.labelsShown != false else { return 0 }
            return (g.scale.ticks.map { size(fmt(g, $0), font).width }.max() ?? 0) + 6 * scale
        }
        let catLabels = primaryCats
        let catLabelW = (catLabels.map { size($0, font).width }.max() ?? 0) + 6 * scale
        let showCat = catAxis?.deleted != true && catAxis?.labelsShown != false
        var titleLeft: CGFloat = 0, titleBottom: CGFloat = 0
        let valTitle = primary.axis?.title.flatMap { $0.text }
        let catTitle = catAxis?.title.flatMap { $0.text }
        if valTitle != nil { if horizontal { titleBottom = lineH + 4 * scale } else { titleLeft = lineH + 4 * scale } }
        if catTitle != nil { if horizontal { titleLeft = lineH + 4 * scale } else { titleBottom = lineH + 4 * scale } }

        var plotRect: CGRect
        if horizontal {
            let left = (showCat ? min(catLabelW, area.width * 0.35) : 0) + titleLeft
            plotRect = CGRect(
                x: area.minX + left, y: area.minY + 4 * scale,
                width: area.width - left - 8 * scale, height: area.height - lineH - 8 * scale - titleBottom)
        } else {
            let left = valLabelW(primary) + titleLeft
            let right = max(8 * scale, valLabelW(secondary))
            plotRect = CGRect(
                x: area.minX + left, y: area.minY + 6 * scale,
                width: area.width - left - right, height: area.height - (showCat ? lineH + 6 * scale : 0) - 6 * scale - titleBottom)
        }
        guard plotRect.width > 10, plotRect.height > 10 else { return }
        if let bg = spec.plotBackground { ns(bg).setFill(); plotRect.fill() }

        // Positions.
        func valuePos(_ g: Group, _ v: Double) -> CGFloat {
            let t = CGFloat(g.scale.pos(v))
            let rev = g.axis?.reversed == true
            if horizontal { return rev ? plotRect.maxX - t * plotRect.width : plotRect.minX + t * plotRect.width }
            return rev ? plotRect.minY + t * plotRect.height : plotRect.maxY - t * plotRect.height
        }
        let slot = (horizontal ? plotRect.height : plotRect.width) / CGFloat(catCount)
        let catReversed = catAxis?.reversed == true
        func catStart(_ i: Int) -> CGFloat {
            // Horizontal bars: first category at the bottom, like Excel.
            if horizontal { return catReversed ? plotRect.minY + CGFloat(i) * slot : plotRect.maxY - CGFloat(i + 1) * slot }
            return catReversed ? plotRect.maxX - CGFloat(i + 1) * slot : plotRect.minX + CGFloat(i) * slot
        }
        let lineOnBetween = plots.contains { $0.plot.kind == .bar } || plots.contains { $0.plot.kind == .line }

        // Gridlines and value labels.
        for (gi, g) in groups.enumerated() where g.axis?.deleted != true || gi == 0 {
            if g.axis?.majorGridlines ?? (gi == 0) {
                gridColor.setFill()
                for t in g.scale.ticks {
                    let p = valuePos(g, t)
                    if horizontal {
                        CGRect(x: p - 0.5, y: plotRect.minY, width: 1, height: plotRect.height).fill()
                    } else {
                        CGRect(x: plotRect.minX, y: p - 0.5, width: plotRect.width, height: 1).fill()
                    }
                }
            }
            guard g.axis?.deleted != true, g.axis?.labelsShown != false else { continue }
            for t in g.scale.ticks {
                let p = valuePos(g, t)
                if horizontal {
                    label(fmt(g, t), at: CGPoint(x: p, y: plotRect.maxY + 3 * scale), anchor: (0.5, 0))
                } else if gi == 0 {
                    label(fmt(g, t), at: CGPoint(x: plotRect.minX - 4 * scale, y: p), anchor: (1, 0.5))
                } else {
                    label(fmt(g, t), at: CGPoint(x: plotRect.maxX + 4 * scale, y: p), anchor: (0, 0.5))
                }
            }
        }
        if let xScale {
            // Gridlines first, labels after: drawing text changes the current fill colour.
            gridColor.setFill()
            let xs = xScale.ticks.map { plotRect.minX + CGFloat(xScale.pos($0)) * plotRect.width }
            for x in xs { CGRect(x: x - 0.5, y: plotRect.minY, width: 1, height: plotRect.height).fill() }
            for (t, x) in zip(xScale.ticks, xs) { label(format(t, nil), at: CGPoint(x: x, y: plotRect.maxY + 3 * scale), anchor: (0.5, 0)) }
        }
        // Category axis line and labels.
        axisColor.setFill()
        let zero = valuePos(primary, max(primary.scale.min, min(primary.scale.max, 0)))
        if horizontal {
            CGRect(x: zero - 0.5, y: plotRect.minY, width: 1, height: plotRect.height).fill()
        } else if xScale == nil || plots.count > xyPlots.count {
            CGRect(x: plotRect.minX, y: zero - 0.5, width: plotRect.width, height: 1).fill()
        }
        if showCat && plots.count > xyPlots.count {
            let every = horizontal ? max(1, Int(ceil(lineH / max(1, slot)))) : max(1, Int(ceil(catLabelW / max(1, slot))))
            for (i, c) in catLabels.enumerated() where i % every == 0 {
                let s0 = catStart(i)
                if horizontal {
                    let r = CGRect(
                        x: area.minX + titleLeft, y: s0 + slot / 2 - lineH / 2, width: plotRect.minX - area.minX - titleLeft - 4 * scale, height: lineH)
                    drawText(c, font: font, color: labelColor, in: r, align: .right)
                } else {
                    let w = slot * CGFloat(every)
                    let r = CGRect(x: s0 + slot / 2 - w / 2, y: plotRect.maxY + 3 * scale, width: w, height: lineH * 2)
                    drawText(c, font: font, color: labelColor, in: r, align: .center)
                }
            }
        }
        // Axis titles.
        let titleFont = NSFont.systemFont(ofSize: px(9), weight: .medium)
        if let t = catTitle {
            if horizontal {
                verticalTitle(t, font: titleFont, x: area.minX, rect: plotRect)
            } else {
                label(t, at: CGPoint(x: plotRect.midX, y: area.maxY - lineH), anchor: (0.5, 0), font: titleFont)
            }
        }
        if let t = valTitle {
            if horizontal {
                label(t, at: CGPoint(x: plotRect.midX, y: area.maxY - lineH), anchor: (0.5, 0), font: titleFont)
            } else {
                verticalTitle(t, font: titleFont, x: area.minX, rect: plotRect)
            }
        }

        // Series. Bars of every bar plot are laid out together within each category.
        let barPlots = groups.flatMap { g in g.plots.filter { $0.plot.kind == .bar }.map { (g, $0) } }
        var barIndex = 0
        let barSlots = barPlots.reduce(0) { $0 + ($1.1.plot.isStacked ? 1 : $1.1.series.count) }
        for (g, p) in barPlots {
            drawBars(p, group: g, slots: barSlots, first: barIndex, slot: slot, horizontal: horizontal, catStart: catStart, valuePos: { valuePos(g, $0) })
            barIndex += p.plot.isStacked ? 1 : p.series.count
        }
        for g in groups {
            for p in g.plots where p.plot.kind == .area { drawArea(p, slot: slot, catStart: catStart, valuePos: { valuePos(g, $0) }) }
            for p in g.plots where p.plot.kind == .line {
                drawLines(p, slot: slot, onBetween: lineOnBetween, catStart: catStart, valuePos: { valuePos(g, $0) })
            }
            for p in g.plots where p.plot.kind == .scatter || p.plot.kind == .bubble {
                guard let xScale else { continue }
                drawScatter(p, plotRect: plotRect, x: { plotRect.minX + CGFloat(xScale.pos($0)) * plotRect.width }, y: { valuePos(g, $0) })
            }
        }
    }

    func verticalTitle(_ t: String, font: NSFont, x: CGFloat, rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let sz = size(t, font)
        ctx.saveGState()
        ctx.translateBy(x: x + sz.height / 2, y: rect.midY)
        ctx.rotate(by: -.pi / 2)
        (t as NSString).draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2), withAttributes: [.font: font, .foregroundColor: labelColor])
        ctx.restoreGState()
    }

    func drawBars(
        _ p: ResolvedPlot, group: Group, slots: Int, first: Int, slot: CGFloat, horizontal: Bool,
        catStart: (Int) -> CGFloat, valuePos: (Double) -> CGFloat
    ) {
        let n = CGFloat(max(1, slots))
        let gap = CGFloat(p.plot.gapWidth) / 100
        let overlap = p.plot.isStacked ? 1 : CGFloat(p.plot.overlap) / 100
        let barW = slot / (n - (n - 1) * max(0, overlap) + gap)
        let step = barW * (1 - max(0, overlap))
        let clusterW = barW + step * (n - 1)
        let count = p.series.map(\.values.count).max() ?? 0
        let labels = p.plot.labels
        for i in 0..<count {
            var pos = 0.0, neg = 0.0
            let total = p.series.reduce(0.0) { $0 + abs(i < $1.values.count ? ($1.values[i] ?? 0) : 0) }
            for (k, s) in p.series.enumerated() {
                guard i < s.values.count, var v = s.values[i] else { continue }
                if p.plot.isPercent { v = total > 0 ? v / total : 0 }
                var base = 0.0
                if p.plot.isStacked { if v >= 0 { base = pos; pos += v } else { base = neg; neg += v } }
                let lane = CGFloat(first + (p.plot.isStacked ? 0 : k))
                let offset = catStart(i) + (slot - clusterW) / 2 + lane * step
                let a = valuePos(base), b = valuePos(base + v)
                let r =
                    horizontal
                    ? CGRect(x: min(a, b), y: offset, width: abs(b - a), height: barW)
                    : CGRect(x: offset, y: min(a, b), width: barW, height: abs(b - a))
                let fill = s.series.pointColors[i].map(ns) ?? (p.plot.varyColors && p.series.count == 1 ? ns(pointColor(i, of: p.categories.count)) : color(s))
                if !s.series.noFill { fill.setFill(); r.fill() }
                if let lc = s.series.line, !s.series.noLine {
                    ns(lc).setStroke()
                    let path = NSBezierPath(rect: r)
                    path.lineWidth = CGFloat(s.series.lineWidth ?? 0.75) * scale
                    path.stroke()
                }
                let l = (s.series.labels ?? labels).at(i)
                if l.any {
                    let text = labelText(l, value: s.values[i] ?? 0, series: s, category: i < p.categories.count ? p.categories[i] : nil, total: total)
                    let font = font(of: l), ink = l.color.map(readable)
                    let high = v >= 0
                    let pad = 3 * scale
                    if l.position == "ctr" || (l.position == nil && p.plot.isStacked) {
                        label(text, at: CGPoint(x: r.midX, y: r.midY), anchor: (0.5, 0.5), font: font, color: ink)
                    } else if horizontal {
                        let inside = l.position == "inEnd", base = l.position == "inBase"
                        let edge =
                            base ? (high ? r.minX + pad : r.maxX - pad) : inside ? (high ? r.maxX - pad : r.minX + pad) : (high ? r.maxX + pad : r.minX - pad)
                        let leading = base ? high : inside ? !high : high
                        label(text, at: CGPoint(x: edge, y: r.midY), anchor: (leading ? 0 : 1, 0.5), font: font, color: ink)
                    } else {
                        let inside = l.position == "inEnd", base = l.position == "inBase"
                        let edge =
                            base ? (high ? r.maxY - pad : r.minY + pad) : inside ? (high ? r.minY + pad : r.maxY - pad) : (high ? r.minY - pad : r.maxY + pad)
                        let above = base ? high : inside ? !high : high
                        label(text, at: CGPoint(x: r.midX, y: edge), anchor: (0.5, above ? 1 : 0), font: font, color: ink)
                    }
                }
            }
        }
    }

    func points(_ s: ResolvedSeries, slot: CGFloat, onBetween: Bool, catStart: (Int) -> CGFloat, y: (Double) -> CGFloat, values: [Double?]) -> [CGPoint?] {
        values.enumerated().map { i, v in
            guard let v else { return nil }
            let x = onBetween ? catStart(i) + slot / 2 : catStart(i)
            return CGPoint(x: x, y: y(v))
        }
    }

    func stackedValues(_ p: ResolvedPlot) -> [[Double?]] {
        guard p.plot.isStacked else { return p.series.map(\.values) }
        let n = p.series.map(\.values.count).max() ?? 0
        var acc = [Double](repeating: 0, count: n)
        let totals = (0..<n).map { i in p.series.reduce(0.0) { $0 + abs(i < $1.values.count ? ($1.values[i] ?? 0) : 0) } }
        return p.series.map { s in
            (0..<n).map { i in
                var v = i < s.values.count ? (s.values[i] ?? 0) : 0
                if p.plot.isPercent { v = totals[i] > 0 ? v / totals[i] : 0 }
                acc[i] += v
                return acc[i]
            }
        }
    }

    func stroke(_ pts: [CGPoint?], color: NSColor, width: CGFloat, dashed: Bool, smooth: Bool, spanGaps: Bool) {
        var runs: [[CGPoint]] = [[]]
        for p in pts {
            if let p { runs[runs.count - 1].append(p) } else if !spanGaps, !(runs.last?.isEmpty ?? true) { runs.append([]) }
        }
        color.setStroke()
        for run in runs where run.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            if dashed { path.setLineDash([4 * scale, 3 * scale], count: 2, phase: 0) }
            path.move(to: run[0])
            for i in 1..<run.count {
                if smooth {
                    let p0 = run[max(0, i - 2)], p1 = run[i - 1], p2 = run[i], p3 = run[min(run.count - 1, i + 1)]
                    let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                    let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                    path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
                } else {
                    path.line(to: run[i])
                }
            }
            path.stroke()
        }
    }

    func marker(_ p: CGPoint, _ s: ResolvedSeries, color: NSColor) {
        let sym = s.series.marker ?? "circle"
        guard sym != "none" else { return }
        let r = CGFloat(s.series.markerSize ?? 5) * scale * 0.6
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        let path: NSBezierPath
        switch sym {
        case "square": path = NSBezierPath(rect: rect)
        case "diamond":
            path = NSBezierPath()
            path.move(to: CGPoint(x: p.x, y: rect.minY)); path.line(to: CGPoint(x: rect.maxX, y: p.y))
            path.line(to: CGPoint(x: p.x, y: rect.maxY)); path.line(to: CGPoint(x: rect.minX, y: p.y)); path.close()
        case "triangle":
            path = NSBezierPath()
            path.move(to: CGPoint(x: p.x, y: rect.minY)); path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY)); path.close()
        default: path = NSBezierPath(ovalIn: rect)
        }
        color.setFill()
        path.fill()
        (isDark ? cardColor : NSColor.white.withAlphaComponent(0.9)).setStroke()
        path.lineWidth = 0.75 * scale
        path.stroke()
    }

    func drawLines(_ p: ResolvedPlot, slot: CGFloat, onBetween: Bool, catStart: (Int) -> CGFloat, valuePos: (Double) -> CGFloat) {
        let stacked = stackedValues(p)
        for (k, s) in p.series.enumerated() {
            let vals: [Double?] = p.plot.isStacked ? stacked[k].enumerated().map { i, v in i < s.values.count && s.values[i] != nil ? v : nil } : s.values
            let pts = points(s, slot: slot, onBetween: onBetween, catStart: catStart, y: valuePos, values: vals)
            let c = lineColor(s)
            if !s.series.noLine {
                stroke(
                    pts, color: c, width: CGFloat(s.series.lineWidth ?? 2.25) * scale, dashed: s.series.dashed, smooth: s.series.smooth,
                    spanGaps: spec.displayBlanksAs == "span")
            }
            if p.plot.markers { for case let q? in pts { marker(q, s, color: c) } }
            let labels = s.series.labels ?? p.plot.labels
            for (i, q) in pts.enumerated() {
                let l = labels.at(i)
                guard l.any, let q, i < s.values.count, let v = s.values[i] else { continue }
                pointLabel(labelText(l, value: v, series: s, category: i < p.categories.count ? p.categories[i] : nil, total: nil), at: q, l)
            }
        }
    }

    func drawArea(_ p: ResolvedPlot, slot: CGFloat, catStart: (Int) -> CGFloat, valuePos: (Double) -> CGFloat) {
        let stacked = stackedValues(p)
        // Stacked: from the top band down, so each lower band shows. Side by side: in order,
        // later series in front (as Excel draws them).
        for k in p.plot.isStacked ? Array(p.series.indices.reversed()) : Array(p.series.indices) {
            let s = p.series[k]
            let top = stacked[k]
            let below: [Double?] = p.plot.isStacked && k > 0 ? stacked[k - 1] : top.map { _ in 0 }
            let n = top.count
            guard n > 1 else { continue }
            let path = NSBezierPath()
            for i in 0..<n {
                let x = catStart(i) + slot / 2
                let pt = CGPoint(x: x, y: valuePos(top[i] ?? 0))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            for i in (0..<n).reversed() { path.line(to: CGPoint(x: catStart(i) + slot / 2, y: valuePos(below[i] ?? 0))) }
            path.close()
            color(s).withAlphaComponent(p.plot.isStacked ? 1 : 0.85).setFill()
            path.fill()
        }
    }

    func drawScatter(_ p: ResolvedPlot, plotRect: CGRect, x: (Double) -> CGFloat, y: (Double) -> CGFloat) {
        let maxSize = p.series.flatMap { $0.sizes ?? [] }.compactMap { $0 }.max() ?? 1
        for s in p.series {
            let xs = s.xValues ?? s.values.indices.map { Double($0 + 1) }
            let pts: [CGPoint?] = s.values.enumerated().map { i, v in
                guard let v, i < xs.count, let xv = xs[i] else { return nil }
                return CGPoint(x: x(xv), y: y(v))
            }
            let c = lineColor(s)
            if p.plot.kind == .bubble {
                for (i, q) in pts.enumerated() {
                    guard let q else { continue }
                    let sz = (s.sizes.flatMap { i < $0.count ? $0[i] : nil } ?? 1) ?? 1
                    let r = max(3, sqrt(max(0, sz) / maxSize) * min(plotRect.width, plotRect.height) * 0.12)
                    color(s).withAlphaComponent(0.7).setFill()
                    NSBezierPath(ovalIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)).fill()
                }
                continue
            }
            if p.plot.scatterLines && !s.series.noLine {
                stroke(pts, color: c, width: CGFloat(s.series.lineWidth ?? 2) * scale, dashed: s.series.dashed, smooth: s.series.smooth, spanGaps: false)
            }
            if p.plot.markers || s.series.marker != nil { for case let q? in pts { marker(q, s, color: c) } }
            let labels = s.series.labels ?? p.plot.labels
            for (i, q) in pts.enumerated() {
                let l = labels.at(i)
                guard l.any, let q, let v = s.values[i] else { continue }
                pointLabel(labelText(l, value: v, series: s, category: nil, total: nil), at: q, l)
            }
        }
    }
}
