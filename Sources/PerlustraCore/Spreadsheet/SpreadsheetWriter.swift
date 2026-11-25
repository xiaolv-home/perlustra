import Foundation

// MARK: - XLSX: patch edited cells into the original package

/// Row heights / column widths the user changed (final sheet coordinates).
public struct SheetLayoutEdits: Sendable, Equatable {
    public var rows = Set<Int>()
    public var cols = Set<Int>()
    public init() {}
    public var isEmpty: Bool { rows.isEmpty && cols.isEmpty }
}

public enum XLSXPatcher {
    /// Rewrites only what changed in `base` (an .xlsx) and writes the result to `dest`:
    /// edited cells, inserted/deleted rows and columns (`structure`, in the order they were made)
    /// and changed row heights / column widths. Everything else in the package — styles, charts,
    /// comments, other sheets — is copied as-is.
    public static func save(
        base: URL, to dest: URL, workbook wb: Workbook, edited: [Int: Set<Int>],
        structure: [Int: [StructOp]] = [:], layout: [Int: SheetLayoutEdits] = [:],
        mergesChanged: Set<Int> = []
    ) throws {
        let parts = try ArchiveReader.extractAll(url: base) { _ in true }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("perlustra-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (path, data) in parts where !path.hasSuffix("/") {
            let f = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: f)
        }
        var touchedFormulas = false
        let sheetsToWrite = Set(edited.filter { !$0.value.isEmpty }.keys)
            .union(structure.filter { !$0.value.isEmpty }.keys)
            .union(layout.filter { !$0.value.isEmpty }.keys)
            .union(mergesChanged)
        for si in sheetsToWrite.sorted() {
            guard wb.sheets.indices.contains(si), let part = wb.sheets[si].sourcePart else {
                throw SaveError("找不到工作表 \(si + 1) 在原文件中的位置")
            }
            let url = work.appendingPathComponent(part)
            guard var xml = try? String(contentsOf: url, encoding: .utf8) else { throw SaveError("无法读取 \(part)") }
            let sheet = wb.sheets[si]
            let keys = edited[si] ?? []
            let ops = structure[si] ?? []
            let lay = layout[si] ?? SheetLayoutEdits()
            if keys.contains(where: { sheet.formulas[$0] != nil }) { touchedFormulas = true }
            let prefix = try namespacePrefix(xml)
            if !ops.isEmpty {
                touchedFormulas = true
                try checkTables(work: work, part: part, ops: ops)
                xml = try restructure(xml, ops: ops, sheet: sheet, prefix: prefix)
            } else if mergesChanged.contains(si) {
                xml = rewriteMerges(xml, sheet: sheet, prefix: prefix)
            }
            if !ops.isEmpty || !lay.cols.isEmpty {
                xml = updateCols(xml, ops: ops, widths: lay.cols, sheet: sheet, prefix: prefix)
            }
            let patched = try patchSheet(xml, sheet: sheet, keys: keys, heightRows: lay.rows)
            try patched.write(to: url, atomically: true, encoding: .utf8)
        }
        if structure.values.contains(where: { !$0.isEmpty }) {
            adjustWorkbookReferences(work: work, workbook: wb, structure: structure)
        }
        // Ask Excel/WPS/Numbers to recalculate on open; drop the now-stale calculation chain.
        let wbURL = work.appendingPathComponent("xl/workbook.xml")
        if var w = try? String(contentsOf: wbURL, encoding: .utf8) {
            w = forceFullCalc(w)
            try w.write(to: wbURL, atomically: true, encoding: .utf8)
        }
        if touchedFormulas { removeCalcChain(work) }
        let tmp = AtomicWrite.tempNear(dest, ext: "xlsx")
        try Zip.pack(directory: work, to: tmp)
        // Sanity check: the result must read back before it replaces anything.
        _ = try SpreadsheetReader.readXLSX(url: tmp)
        try AtomicWrite.replace(dest, with: tmp)
    }

    /// Namespace prefix used for SpreadsheetML elements (usually none, sometimes "x:").
    static func namespacePrefix(_ xml: String) throws -> String {
        guard let r = xml.range(of: #"<(\w+:)?sheetData\b"#, options: .regularExpression) else {
            throw SaveError("工作表结构无法识别（缺少 sheetData）")
        }
        let tag = xml[r].dropFirst()
        return tag.hasPrefix("sheetData") ? "" : String(tag.prefix { $0 != ":" }) + ":"
    }

    static func ref(_ r: Int, _ c: Int) -> String { Sheet.columnName(c) + "\(r + 1)" }

    /// XML for one cell, keeping its original style attribute.
    static func cellXML(_ sheet: Sheet, _ r: Int, _ c: Int, prefix: String, style: String?) -> String? {
        let key = Sheet.key(r, c)
        let s = style.map { " s=\"\($0)\"" } ?? ""
        let tag = prefix + "c"
        let value = sheet.cell(r, c)
        let formula = sheet.formulas[key].map { f -> String in
            var t = f; if t.hasPrefix("=") { t.removeFirst() }; return t
        }
        let f = formula.map { "<\(prefix)f>\(XMLEscape.text($0))</\(prefix)f>" } ?? ""
        switch value {
        case .empty:
            if formula != nil { return "<\(tag) r=\"\(ref(r, c))\"\(s)>\(f)</\(tag)>" }
            return style == nil ? nil : "<\(tag) r=\"\(ref(r, c))\"\(s)/>"
        case .number(let d), .date(let d):
            return "<\(tag) r=\"\(ref(r, c))\"\(s)>\(f)<\(prefix)v>\(CellValue.format(d) == "#NUM!" ? "0" : String(d.isFinite ? d : 0))</\(prefix)v></\(tag)>"
        case .bool(let b):
            return "<\(tag) r=\"\(ref(r, c))\"\(s) t=\"b\">\(f)<\(prefix)v>\(b ? 1 : 0)</\(prefix)v></\(tag)>"
        case .error(let e):
            return
                "<\(tag) r=\"\(ref(r, c))\"\(s) t=\"e\">\(f)<\(prefix)v>\(XMLEscape.text(e.hasPrefix("#") ? String(e.prefix(while: { $0 != " " && $0 != "（" })) : "#VALUE!"))</\(prefix)v></\(tag)>"
        case .text(let t):
            if formula != nil {
                return "<\(tag) r=\"\(ref(r, c))\"\(s) t=\"str\">\(f)<\(prefix)v>\(XMLEscape.text(t))</\(prefix)v></\(tag)>"
            }
            let space = t.hasPrefix(" ") || t.hasSuffix(" ") || t.contains("\n") ? " xml:space=\"preserve\"" : ""
            return "<\(tag) r=\"\(ref(r, c))\"\(s) t=\"inlineStr\"><\(prefix)is><\(prefix)t\(space)>\(XMLEscape.text(t))</\(prefix)t></\(prefix)is></\(tag)>"
        }
    }

    private static let rowNumAttrRE: NSRegularExpression? = try? NSRegularExpression(pattern: #"\br="(\d+)""#)
    private static let cellRefAttrRE: NSRegularExpression? = try? NSRegularExpression(pattern: #"\br="([A-Z]+)(\d+)""#)
    private static let cellStyleAttrRE: NSRegularExpression? = try? NSRegularExpression(pattern: #"\bs="(\d+)""#)
    private static let defaultRowRE: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<row\\b([^>]*?)(/>|>(.*?)</row>)", options: [.dotMatchesLineSeparators])
    private static let defaultCellRE: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<c\\b([^>]*?)(/>|>(.*?)</c>)", options: [.dotMatchesLineSeparators])

    private static func rowRegex(prefix: String) throws -> NSRegularExpression {
        if prefix.isEmpty, let r = defaultRowRE { return r }
        let p = NSRegularExpression.escapedPattern(for: prefix)
        return try NSRegularExpression(pattern: "<\(p)row\\b([^>]*?)(/>|>(.*?)</\(p)row>)", options: [.dotMatchesLineSeparators])
    }

    private static func cellRegex(prefix: String) throws -> NSRegularExpression {
        if prefix.isEmpty, let r = defaultCellRE { return r }
        let p = NSRegularExpression.escapedPattern(for: prefix)
        return try NSRegularExpression(pattern: "<\(p)c\\b([^>]*?)(/>|>(.*?)</\(p)c>)", options: [.dotMatchesLineSeparators])
    }

    static func patchSheet(_ xml: String, sheet: Sheet, keys: Set<Int>, heightRows: Set<Int> = []) throws -> String {
        let prefix = try namespacePrefix(xml)

        var doc = xml
        // Empty <sheetData/> → open/close pair.
        doc = doc.replacingOccurrences(of: "<\(prefix)sheetData/>", with: "<\(prefix)sheetData></\(prefix)sheetData>")
        doc = doc.replacingOccurrences(of: "<\(prefix)sheetData />", with: "<\(prefix)sheetData></\(prefix)sheetData>")

        // Index rows once: number → range of the whole <row …>…</row> (or self-closing) element.
        let rowRE = try rowRegex(prefix: prefix)
        var rows: [(num: Int, range: NSRange)] = []
        let dns = doc as NSString
        guard let sdStart = doc.range(of: "<\(prefix)sheetData"), let sdEnd = doc.range(of: "</\(prefix)sheetData>") else {
            throw SaveError("工作表结构无法识别")
        }
        let dataRange = NSRange(sdStart.lowerBound..<sdEnd.upperBound, in: doc)
        var implicit = 0
        for m in rowRE.matches(in: doc, range: dataRange) {
            let attrs = dns.substring(with: m.range(at: 1))
            let n: Int
            if let am = rowNumAttrRE?.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) {
                n = Int((attrs as NSString).substring(with: am.range(at: 1))) ?? implicit + 1
            } else {
                n = implicit + 1
            }
            implicit = n
            rows.append((n - 1, m.range))
        }

        var byRow = Dictionary(grouping: keys, by: { $0 / 16384 })
        for r in heightRows where byRow[r] == nil { byRow[r] = [] }
        // Patch from the bottom up so earlier ranges stay valid; keep a fixed tail anchor so
        // multiple rows appended past the end stay in ascending OOXML `r` order.
        var mutable = NSMutableString(string: doc)
        var tailAnchor: Int?
        for (r, rowKeys) in byRow.sorted(by: { $0.key > $1.key }) {
            let cols = rowKeys.map { $0 % 16384 }.sorted()
            let height = heightRows.contains(r) ? sheet.rowHeights[r] : nil
            if let existing = rows.first(where: { $0.num == r }) {
                let rowXML = mutable.substring(with: existing.range)
                var newRow = try patchRow(rowXML, sheet: sheet, row: r, cols: cols, prefix: prefix)
                if heightRows.contains(r) { newRow = setRowHeight(newRow, height) }
                mutable.replaceCharacters(in: existing.range, with: newRow)
            } else {
                let cells = cols.compactMap { cellXML(sheet, r, $0, prefix: prefix, style: sheet.styleIDs[Sheet.key(r, $0)].map(String.init)) }.joined()
                guard !cells.isEmpty || height != nil else { continue }
                let ht = height.map { " ht=\"\(fmtNum($0))\" customHeight=\"1\"" } ?? ""
                let newRow = "<\(prefix)row r=\"\(r + 1)\"\(ht)>\(cells)</\(prefix)row>"
                if let next = rows.filter({ $0.num > r }).min(by: { $0.num < $1.num }) {
                    mutable.insert(newRow, at: next.range.location)
                } else {
                    let pos = tailAnchor ?? mutable.range(of: "</\(prefix)sheetData>").location
                    mutable.insert(newRow, at: pos)
                    tailAnchor = pos
                }
            }
        }
        mutable = NSMutableString(string: fixDimension(mutable as String, sheet: sheet, prefix: prefix))
        return mutable as String
    }

    static func fmtNum(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
    }

    /// Sets (or, for nil, clears) an explicit height on a <row> element.
    static func setRowHeight(_ row: String, _ ht: Double?) -> String {
        guard let close = row.firstIndex(of: ">") else { return row }
        var open = String(row[..<close])
        let rest = String(row[close...])
        open = open.replacingOccurrences(of: #"\s(ht|customHeight)="[^"]*""#, with: "", options: .regularExpression)
        let selfClosing = open.hasSuffix("/")
        if selfClosing { open.removeLast() }
        if let ht { open += " ht=\"\(fmtNum(ht))\" customHeight=\"1\"" }
        return open + (selfClosing ? "/" : "") + rest
    }

    static func patchRow(_ rowXML: String, sheet: Sheet, row r: Int, cols: [Int], prefix: String) throws -> String {
        var row = rowXML
        if row.hasSuffix("/>") {
            // <row r="3" …/> → <row r="3" …></row>
            row = String(row.dropLast(2)) + "></\(prefix)row>"
        }
        let cellRE = try cellRegex(prefix: prefix)
        for c in cols.reversed() {
            let ns = row as NSString
            var cells: [(col: Int, range: NSRange, style: String?)] = []
            var implicitCol = -1
            for m in cellRE.matches(in: row, range: NSRange(location: 0, length: ns.length)) {
                let attrs = ns.substring(with: m.range(at: 1))
                let ans = attrs as NSString
                var col = implicitCol + 1
                if let rm = cellRefAttrRE?.firstMatch(in: attrs, range: NSRange(location: 0, length: ans.length)) {
                    col = Sheet.columnIndex(ans.substring(with: rm.range(at: 1))) ?? col
                }
                implicitCol = col
                let style = cellStyleAttrRE?.firstMatch(in: attrs, range: NSRange(location: 0, length: ans.length)).map { ans.substring(with: $0.range(at: 1)) }
                cells.append((col, m.range, style))
            }
            let mrow = NSMutableString(string: row)
            if let hit = cells.first(where: { $0.col == c }) {
                let xml = cellXML(sheet, r, c, prefix: prefix, style: hit.style) ?? ""
                mrow.replaceCharacters(in: hit.range, with: xml)
            } else if let xml = cellXML(sheet, r, c, prefix: prefix, style: sheet.styleIDs[Sheet.key(r, c)].map(String.init)) {
                if let next = cells.first(where: { $0.col > c }) {
                    mrow.insert(xml, at: next.range.location)
                } else {
                    let end = mrow.range(of: "</\(prefix)row>", options: .backwards)
                    mrow.insert(xml, at: end.location)
                }
            }
            row = mrow as String
        }
        // Spans become stale when cells are added; they are optional, so drop them.
        row = row.replacingOccurrences(of: #" spans="[^"]*""#, with: "", options: .regularExpression)
        return row
    }

    /// Grows <dimension ref="A1:F7"/> to cover newly written cells.
    static func fixDimension(_ xml: String, sheet: Sheet, prefix: String) -> String {
        let maxRow = max(1, sheet.rows.count)
        let maxCol = max(1, sheet.columnCount)
        let ref = "A1:\(Sheet.columnName(maxCol - 1))\(maxRow)"
        return xml.replacingOccurrences(of: #"<\#(prefix)dimension ref="[^"]*""#, with: "<\(prefix)dimension ref=\"\(ref)\"", options: .regularExpression)
    }

    static func forceFullCalc(_ w: String) -> String {
        if let r = w.range(of: #"<(\w+:)?calcPr\b[^>]*"#, options: .regularExpression) {
            var tag = String(w[r])
            if tag.contains("fullCalcOnLoad") {
                tag = tag.replacingOccurrences(of: #"fullCalcOnLoad="[^"]*""#, with: "fullCalcOnLoad=\"1\"", options: .regularExpression)
            } else {
                tag += " fullCalcOnLoad=\"1\""
            }
            return w.replacingCharacters(in: r, with: tag)
        }
        let prefix =
            w.range(of: #"<(\w+:)?workbook\b"#, options: .regularExpression).map { String(w[$0]).dropFirst().components(separatedBy: "workbook")[0] } ?? ""
        let calc = "<\(prefix)calcPr fullCalcOnLoad=\"1\"/>"
        // calcPr precedes these elements in the schema.
        for later in [
            "oleSize", "customWorkbookViews", "pivotCaches", "smartTagPr", "smartTagTypes", "webPublishing", "fileRecoveryPr", "webPublishObjects", "extLst",
        ] {
            if let r = w.range(of: "<\(prefix)\(later)") { return w.replacingCharacters(in: r.lowerBound..<r.lowerBound, with: calc) }
        }
        if let r = w.range(of: "</\(prefix)workbook>") { return w.replacingCharacters(in: r.lowerBound..<r.lowerBound, with: calc) }
        return w
    }

    static func removeCalcChain(_ work: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: work.appendingPathComponent("xl/calcChain.xml"))
        let rels = work.appendingPathComponent("xl/_rels/workbook.xml.rels")
        if var s = try? String(contentsOf: rels, encoding: .utf8) {
            s = s.replacingOccurrences(of: #"<Relationship\b[^>]*calcChain[^>]*/>"#, with: "", options: .regularExpression)
            try? s.write(to: rels, atomically: true, encoding: .utf8)
        }
        let ct = work.appendingPathComponent("[Content_Types].xml")
        if var s = try? String(contentsOf: ct, encoding: .utf8) {
            s = s.replacingOccurrences(of: #"<Override\b[^>]*calcChain[^>]*/>"#, with: "", options: .regularExpression)
            try? s.write(to: ct, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - XLSX: brand-new workbook (export, or saving formats we cannot patch)

public enum XLSXWriter {
    public static func write(sheets: [(name: String, rows: [[CellValue]], formulas: [Int: String])], to dest: URL) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("perlustra-new-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        func put(_ path: String, _ s: String) throws {
            let f = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try s.write(to: f, atomically: true, encoding: .utf8)
        }
        let xmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        var overrides = ""
        var sheetEntries = ""
        var rels = ""
        var usedNames = Set<String>()
        for (i, sh) in sheets.enumerated() {
            var name = String(sh.name.replacingOccurrences(of: #"[\[\]\*\?/\\:]"#, with: "_", options: .regularExpression).prefix(31))
            if name.isEmpty { name = "Sheet\(i + 1)" }
            while usedNames.contains(name.lowercased()) { name = String(name.prefix(28)) + "_\(i + 1)" }
            usedNames.insert(name.lowercased())
            overrides +=
                "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            sheetEntries += "<sheet name=\"\(XMLEscape.text(name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            rels +=
                "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
            var body = ""
            var tmp = Sheet(name: name, rows: sh.rows, formulas: sh.formulas)
            tmp.columnCount = sh.rows.reduce(0) { max($0, $1.count) }
            for (r, row) in sh.rows.enumerated() {
                var cells = ""
                for c in row.indices {
                    let isDate: Bool = {
                        if case .date = row[c] { return true }; return false
                    }()
                    if let x = XLSXPatcher.cellXML(tmp, r, c, prefix: "", style: isDate ? "1" : nil) { cells += x }
                }
                if !cells.isEmpty { body += "<row r=\"\(r + 1)\">\(cells)</row>" }
            }
            try put(
                "xl/worksheets/sheet\(i + 1).xml",
                xmlHead
                    + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheetData>\(body)</sheetData></worksheet>"
            )
        }
        let n = sheets.count
        try put(
            "[Content_Types].xml",
            xmlHead
                + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\(overrides)</Types>"
        )
        try put(
            "_rels/.rels",
            xmlHead
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        )
        try put(
            "xl/workbook.xml",
            xmlHead
                + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheetEntries)</sheets><calcPr fullCalcOnLoad=\"1\"/></workbook>"
        )
        try put(
            "xl/_rels/workbook.xml.rels",
            xmlHead
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)<Relationship Id=\"rId\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"
        )
        try put(
            "xl/styles.xml",
            xmlHead
                + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"yyyy-mm-dd\"/></numFmts><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs></styleSheet>"
        )
        let tmp = AtomicWrite.tempNear(dest, ext: "xlsx")
        try Zip.pack(directory: work, to: tmp)
        _ = try SpreadsheetReader.readXLSX(url: tmp)
        try AtomicWrite.replace(dest, with: tmp)
    }
}

// MARK: - CSV / TSV

public enum CSVWriter {
    public static func text(rows: [[CellValue]], delimiter: UInt8, crlf: Bool) -> String {
        let d = Character(UnicodeScalar(delimiter))
        let nl = crlf ? "\r\n" : "\n"
        return rows.map { row in
            row.map { v -> String in
                var s: String
                switch v {
                case .number(let x): s = CellValue.format(x)
                case .date(let x): s = CellValue.formatDate(x)
                default: s = v.display
                }
                if s.contains(d) || s.contains("\"") || s.contains("\n") || s.contains("\r") {
                    s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return s
            }.joined(separator: String(d))
        }.joined(separator: nl) + nl
    }

    /// Writes with the given format. Returns false if the text needed a fallback to UTF-8
    /// because the original encoding (e.g. GBK) cannot represent some characters.
    @discardableResult
    public static func write(rows: [[CellValue]], format: CSVFormat, to dest: URL) throws -> Bool {
        let s = text(rows: rows, delimiter: format.delimiter, crlf: format.crlf)
        var data: Data
        var kept = true
        if let d = s.data(using: format.encoding, allowLossyConversion: false) {
            data = d
            if format.bom {
                switch format.encoding {
                case .utf8: data = Data([0xEF, 0xBB, 0xBF]) + data
                case .utf16LittleEndian: data = Data([0xFF, 0xFE]) + data
                case .utf16BigEndian: data = Data([0xFE, 0xFF]) + data
                default: break
                }
            }
        } else {
            kept = false
            data = Data([0xEF, 0xBB, 0xBF]) + Data(s.utf8)
        }
        let tmp = AtomicWrite.tempNear(dest, ext: "csv")
        try data.write(to: tmp)
        try AtomicWrite.replace(dest, with: tmp)
        return kept
    }
}
