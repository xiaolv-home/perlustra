import Foundation

/// One cell of Perlustra's own table model. Every table format (CSV, XLSX, ODS, Numbers…)
/// is converted into this before display, so all of them get the same tools.
public enum CellValue: Sendable, Equatable {
    case empty
    case number(Double)
    case text(String)
    case bool(Bool)
    case date(Double)  // Excel serial day number (1900 system)
    case error(String)

    public var isEmpty: Bool { if case .empty = self { return true }; if case .text(let s) = self { return s.isEmpty }; return false }

    /// Numeric value when the cell is (or reads as) a number.
    public var number: Double? {
        switch self {
        case .number(let d), .date(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .text(let s): return CellValue.parseNumber(s)
        default: return nil
        }
    }

    /// Number only for genuinely numeric cells (used by SUM/AVERAGE, which skip text like Excel).
    public var strictNumber: Double? {
        switch self {
        case .number(let d), .date(let d): return d
        default: return nil
        }
    }

    public var display: String {
        switch self {
        case .empty: return ""
        case .number(let d): return CellValue.format(d)
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .date(let d): return CellValue.formatDate(d)
        case .error(let e): return e
        }
    }

    /// CSV/TSV text becomes a number when it unambiguously is one. Codes with leading zeros stay
    /// text, and so does anything with more significant digits than a number can hold exactly (a
    /// 19-digit order number would otherwise lose its last digits and show as 7.24105097e+18).
    public static func infer(_ s: String) -> CellValue {
        if s.isEmpty { return .empty }
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count > 1, t.hasPrefix("0"), !t.hasPrefix("0."), t.allSatisfy({ $0.isNumber }) { return .text(s) }
        if significantDigits(t) > 15 { return .text(s) }
        if let d = parseNumber(t), t.count < 20 { return .number(d) }
        return .text(s)
    }

    /// Digits that carry the value: those of the part before any exponent, without leading zeros.
    static func significantDigits(_ s: String) -> Int {
        let mantissa = s.prefix { $0 != "e" && $0 != "E" }
        return mantissa.filter(\.isNumber).drop { $0 == "0" }.count
    }

    public static func parseNumber(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var percent = false
        if t.hasSuffix("%") { percent = true; t.removeLast() }
        t = t.replacingOccurrences(of: ",", with: "")
        if t.hasPrefix("¥") || t.hasPrefix("$") || t.hasPrefix("￥") { t.removeFirst() }
        guard let first = t.first, first.isNumber || first == "-" || first == "+" || first == "." else { return nil }
        guard let d = Double(t), d.isFinite else { return nil }
        return percent ? d / 100 : d
    }

    public static func format(_ d: Double) -> String {
        if d.isNaN { return "#NUM!" }
        if d == d.rounded(), abs(d) < 1e15 { return String(format: "%.0f", d) }
        var s = String(format: "%.10g", d)
        if s.contains("e") { return s }
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s
    }

    static let epoch: Date = {
        var c = DateComponents(); c.year = 1899; c.month = 12; c.day = 30
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    public static func dateFromSerial(_ d: Double) -> Date { epoch.addingTimeInterval(d * 86400) }
    public static func serial(from date: Date) -> Double { date.timeIntervalSince(epoch) / 86400 }

    /// Parses common date spellings ("2026-10-23", "2026/10/23", "2026年10月23日", with time) to a serial.
    public static func parseDate(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 6, t.first?.isNumber == true else { return nil }
        for fmt in ["yyyy-MM-dd", "yyyy/M/d", "yyyy-M-d", "yyyy年M月d日", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/M/d H:mm", "yyyy.M.d"] {
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            f.isLenient = false
            if let d = f.date(from: t) { return serial(from: d) }
        }
        return nil
    }

    /// Text used when editing a cell (raw, not number-formatted).
    public var editText: String {
        switch self {
        case .number(let d): return CellValue.format(d)
        case .date(let d): return CellValue.formatDate(d)
        default: return display
        }
    }

    public static func formatDate(_ d: Double) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = d == d.rounded(.down) ? "yyyy-MM-dd" : (d < 1 ? "HH:mm:ss" : "yyyy-MM-dd HH:mm")
        return f.string(from: dateFromSerial(d))
    }
}

public struct Sheet: Sendable {
    public var name: String
    public var rows: [[CellValue]]
    /// Original formulas keyed by "row,col" (0-based), shown read-only in the formula bar.
    public var formulas: [Int: String] = [:]
    public var columnCount: Int
    /// Cell key → index into `Workbook.styles` (only non-default styles are stored).
    public var styleIDs: [Int: Int] = [:]
    /// Excel column widths in character units, and row heights in points.
    public var columnWidths: [Int: Double] = [:]
    public var rowHeights: [Int: Double] = [:]
    /// Rows whose height was set by hand (Excel's customHeight); other heights may grow to fit wrapped text.
    public var customHeightRows: Set<Int> = []
    public var defaultColumnWidth: Double?
    public var defaultRowHeight: Double?
    public var merges: [MergeRange] = []
    public var hiddenRows: Set<Int> = []
    public var hiddenColumns: Set<Int> = []
    public var frozenRows = 0
    public var frozenColumns = 0
    public var showGridLines = true
    /// Zoom the sheet was saved at in Excel (percent).
    public var zoomScale: Double = 100
    /// Path of this sheet's XML inside the source .xlsx (used to save edits in place).
    public var sourcePart: String?
    /// Cells whose text mixes formats (part red, part bold…), keyed like `styleIDs`.
    /// Plain cells are not listed; the cell's own style applies to them.
    public var richText: [Int: [RichRun]] = [:]
    /// Data bars and colour scales (see ConditionalFormatting.evaluate).
    public var conditionalFormats: [ConditionalFormat] = []
    /// Conditional formats Perlustra does not draw (cell rules, icon sets…).
    public var otherConditionalFormats = 0
    /// Charts, pictures and shapes drawn over the cells.
    public var drawings: [SheetDrawing] = []
    /// A chart sheet: the whole sheet is one chart, there are no cells.
    public var isChartSheet = false
    /// Hidden in the file (Excel's 隐藏, or 深度隐藏 that only code can show). Perlustra hides it
    /// too, until the reader asks to see hidden sheets.
    public var isHidden = false

    public init(name: String, rows: [[CellValue]], formulas: [Int: String] = [:]) {
        self.name = name
        // Drop trailing blank cells and rows (spreadsheet apps write styled-but-empty cells).
        var rows = rows
        for i in rows.indices { while let last = rows[i].last, last.isEmpty { rows[i].removeLast() } }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        self.rows = rows
        self.formulas = formulas
        self.columnCount = rows.reduce(0) { max($0, $1.count) }
    }

    public static func key(_ r: Int, _ c: Int) -> Int { r &* 16384 &+ c }

    public func cell(_ r: Int, _ c: Int) -> CellValue {
        guard r >= 0, r < rows.count, c >= 0, c < rows[r].count else { return .empty }
        return rows[r][c]
    }

    public mutating func appendColumn(header: String?, values: [CellValue], startRow: Int) {
        let col = columnCount
        for r in 0..<rows.count {
            while rows[r].count < col { rows[r].append(.empty) }
            if r == startRow - 1, let header {
                rows[r].append(.text(header))
            } else {
                rows[r].append(r - startRow < values.count && r >= startRow ? values[r - startRow] : .empty)
            }
        }
        columnCount += 1
    }

    public static func columnName(_ i: Int) -> String {
        var n = i, s = ""
        repeat { s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n = n / 26 - 1 } while n >= 0
        return s
    }

    public static func columnIndex(_ letters: String) -> Int? {
        var v = 0
        for ch in letters.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { return nil }
            v = v * 26 + Int(a - 64)
        }
        return v > 0 ? v - 1 : nil
    }
}

/// A piece of a rich-text cell with its own formatting. Nil means "as the cell's style".
public struct RichRun: Sendable, Equatable {
    public var text: String
    public var color: RGBA?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strike: Bool?
    public var size: Double?
    public init(text: String) { self.text = text }
    /// No formatting of its own.
    public var isPlain: Bool { color == nil && bold == nil && italic == nil && underline == nil && strike == nil && size == nil }
}

public struct Workbook: Sendable {
    public var sheets: [Sheet]
    public var source: String
    /// Resolved cell styles; index 0 is the default.
    public var styles: [CellStyle] = [CellStyle()]
    public var notes: [String] = []
    /// How a delimited source was written, so saving keeps the same bytes conventions.
    public var csv: CSVFormat?
    /// The sheet the file opens on (Excel's active tab).
    public var activeSheet = 0
    public init(sheets: [Sheet], source: String) { self.sheets = sheets; self.source = source }

    public func style(_ sheet: Int, _ r: Int, _ c: Int) -> CellStyle? {
        guard let id = sheets[sheet].styleIDs[Sheet.key(r, c)], id > 0, id < styles.count else { return nil }
        return styles[id]
    }

    /// Display text honouring the cell's number format, plus a colour from [Red]-style sections.
    public func formatted(_ sheet: Int, _ r: Int, _ c: Int) -> NumberFormat.Result {
        let v = sheets[sheet].cell(r, c)
        guard let fmt = style(sheet, r, c)?.numberFormat else { return NumberFormat.Result(text: v.display, color: nil) }
        return NumberFormat.format(v, code: fmt)
    }

    public func sheetIndex(named n: String) -> Int? {
        sheets.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }
}

public struct CSVFormat: Sendable, Equatable {
    public var delimiter: UInt8
    public var encoding: String.Encoding
    public var bom: Bool
    public var crlf: Bool
    public init(delimiter: UInt8, encoding: String.Encoding, bom: Bool, crlf: Bool) {
        self.delimiter = delimiter; self.encoding = encoding; self.bom = bom; self.crlf = crlf
    }
}
