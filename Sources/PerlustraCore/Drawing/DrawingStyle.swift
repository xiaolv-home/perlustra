import Foundation

/// DrawingML colours, fills and outlines (shared by charts, shapes and text).
public struct DrawingTheme: Sendable {
    /// dk1, lt1, dk2, lt2, accent1…accent6, hlink, folHlink — the order ThemeParser returns.
    public var colors: [RGBA]
    public init(colors: [RGBA]) { self.colors = colors.count >= 12 ? colors : ThemeParser.officeDefault }
    public static let office = DrawingTheme(colors: ThemeParser.officeDefault)

    public func scheme(_ name: String) -> RGBA? {
        let index: Int?
        switch name {
        case "dk1", "tx1": index = 0
        case "lt1", "bg1": index = 1
        case "dk2", "tx2": index = 2
        case "lt2", "bg2": index = 3
        case "accent1": index = 4
        case "accent2": index = 5
        case "accent3": index = 6
        case "accent4": index = 7
        case "accent5": index = 8
        case "accent6": index = 9
        case "hlink": index = 10
        case "folHlink": index = 11
        default: index = nil
        }
        return index.map { colors[$0] }
    }

    /// Excel's default series colours: the six accents, then the same six darker, then lighter.
    public func seriesColor(_ i: Int) -> RGBA {
        let base = colors[4 + i % 6]
        switch (i / 6) % 3 {
        case 0: return base
        case 1: return base.lumMod(0.6)
        default: return base.lumMod(0.8, off: 0.2)
        }
    }
}

public struct DrawingLine: Sendable, Equatable {
    public var color: RGBA?
    /// Points.
    public var width: Double?
    public var none = false
    public var dashed = false
    public var headArrow = false
    public var tailArrow = false
    public init() {}
}

enum DrawingStyle {
    /// The colour inside an element that holds one (`solidFill`, `fgClr`, a gradient stop…).
    static func color(in node: XMLTree?, theme: DrawingTheme, placeholder: RGBA? = nil) -> RGBA? {
        guard let node else { return nil }
        for c in node.children {
            if let v = colorElement(c, theme: theme, placeholder: placeholder) { return v }
        }
        return nil
    }

    static func colorElement(_ c: XMLTree, theme: DrawingTheme, placeholder: RGBA?) -> RGBA? {
        var base: RGBA?
        switch c.name {
        case "srgbClr": base = c["val"].flatMap { RGBA(hex: $0) }
        case "schemeClr": base = c["val"] == "phClr" ? placeholder : c["val"].flatMap(theme.scheme)
        case "sysClr": base = (c["lastClr"] ?? (c["val"] == "window" ? "FFFFFF" : "000000")).flatMap { RGBA(hex: $0) }
        case "prstClr": base = c["val"].flatMap(preset)
        case "scrgbClr":
            func pct(_ k: String) -> UInt8 { UInt8(max(0, min(255, (Double(c[k] ?? "0") ?? 0) / 100000 * 255))) }
            base = RGBA(r: pct("r"), g: pct("g"), b: pct("b"))
        case "hslClr":
            let h = (Double(c["hue"] ?? "0") ?? 0) / 60000 / 360, s = (Double(c["sat"] ?? "0") ?? 0) / 100000, l = (Double(c["lum"] ?? "0") ?? 0) / 100000
            base = RGBA.fromHSL(h, s, l, a: 255)
        default: return nil
        }
        guard var color = base else { return nil }
        // Modifiers, in document order.
        for m in c.children {
            let v = (Double(m["val"] ?? "") ?? 0) / 100000
            switch m.name {
            case "lumMod": color = color.lumMod(v)
            case "lumOff": color = color.lumMod(1, off: v)
            case "tint": color = color.mix(with: RGBA(r: 255, g: 255, b: 255), amount: 1 - v)
            case "shade": color = color.mix(with: RGBA(r: 0, g: 0, b: 0), amount: 1 - v)
            case "alpha": color.a = UInt8(max(0, min(255, v * 255)))
            default: break
            }
        }
        return color
    }

    /// Fill of a shape-properties element: nil = not given (inherit), `.none` = `noFill`.
    enum Fill: Sendable, Equatable { case none, solid(RGBA) }

    static func fill(in spPr: XMLTree?, theme: DrawingTheme, placeholder: RGBA? = nil) -> Fill? {
        guard let spPr else { return nil }
        if spPr.child("noFill") != nil { return Fill.none }
        if let s = spPr.child("solidFill"), let c = color(in: s, theme: theme, placeholder: placeholder) { return .solid(c) }
        if let g = spPr.child("gradFill") {
            // Gradients are drawn with their middle stop: close enough to read the chart.
            let stops = g.child("gsLst")?.children("gs") ?? []
            if let mid = stops.isEmpty ? nil : stops[stops.count / 2], let c = color(in: mid, theme: theme, placeholder: placeholder) { return .solid(c) }
        }
        if let p = spPr.child("pattFill"), let c = color(in: p.child("fgClr"), theme: theme, placeholder: placeholder) { return .solid(c) }
        return nil
    }

    static func line(in spPr: XMLTree?, theme: DrawingTheme, placeholder: RGBA? = nil) -> DrawingLine? {
        guard let ln = spPr?.child("ln") else { return nil }
        var l = DrawingLine()
        if let w = ln["w"].flatMap(Double.init) { l.width = w / 12700 }
        if ln.child("noFill") != nil { l.none = true }
        if let s = ln.child("solidFill") { l.color = color(in: s, theme: theme, placeholder: placeholder) }
        if let d = ln.value(of: "prstDash"), d != "solid" { l.dashed = true }
        if let h = ln.child("headEnd"), (h["type"] ?? "none") != "none" { l.headArrow = true }
        if let t = ln.child("tailEnd"), (t["type"] ?? "none") != "none" { l.tailArrow = true }
        return l
    }

    private static func preset(_ name: String) -> RGBA? {
        let table: [String: String] = [
            "black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "008000", "blue": "0000FF",
            "yellow": "FFFF00", "orange": "FFA500", "gray": "808080", "grey": "808080", "darkGray": "A9A9A9",
            "lightGray": "D3D3D3", "navy": "000080", "purple": "800080", "cyan": "00FFFF", "magenta": "FF00FF",
            "brown": "A52A2A", "pink": "FFC0CB", "gold": "FFD700", "silver": "C0C0C0", "teal": "008080",
        ]
        return table[name].flatMap { RGBA(hex: $0) }
    }
}

extension RGBA {
    /// DrawingML luminance modulation: l' = l × mod + off.
    public func lumMod(_ mod: Double, off: Double = 0) -> RGBA {
        var (h, s, l) = hsl
        l = min(1, max(0, l * mod + off))
        return RGBA.fromHSL(h, s, l, a: a)
    }

    /// Mixes towards another colour by `amount` (0 = unchanged, 1 = the other colour).
    /// Office's `shade` / `tint`, worked in linear light as Office does: `linearShade(0.65)`
    /// keeps 65 % of the colour, `linearTint(0.65)` keeps 65 % and adds white for the rest.
    public func linearShade(_ keep: Double) -> RGBA { linearMap { $0 * keep } }
    public func linearTint(_ keep: Double) -> RGBA { linearMap { $0 * keep + (1 - keep) } }

    private func linearMap(_ f: (Double) -> Double) -> RGBA {
        func ch(_ x: UInt8) -> UInt8 {
            let c = Double(x) / 255
            let lin = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            let out = max(0, min(1, f(lin)))
            let s = out <= 0.0031308 ? out * 12.92 : 1.055 * pow(out, 1 / 2.4) - 0.055
            return UInt8((s * 255).rounded())
        }
        return RGBA(r: ch(r), g: ch(g), b: ch(b), a: a)
    }

    public func mix(with o: RGBA, amount: Double) -> RGBA {
        let t = max(0, min(1, amount))
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) * (1 - t) + Double(y) * t).rounded()) }
        return RGBA(r: m(r, o.r), g: m(g, o.g), b: m(b, o.b), a: a)
    }
}
