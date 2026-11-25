import AppKit
import PerlustraCore

/// The AI's hands on a table: it reads and calculates with Perlustra's own formula engine (exact
/// numbers, never guessed), builds summaries, adds computed columns, filters the view and saves
/// results as new files. The original file is never changed.
extension SpreadsheetRenderer: AIDocumentTools {
    var aiSuggestions: [String]? {
        [
            "先看懂这张表：有哪些列、多少行、有没有空值和异常值",
            "按第一个分类列分组汇总金额，存成新的 Excel，并告诉我排名前 5",
            "找出明显异常的数字（比如负数、远超平均的值），选中给我看",
            "根据这张表写一份分析报告（Word），要有关键数字和结论",
        ]
    }

    var aiContext: String {
        guard let f = file else { return "" }
        guard workbookLoaded else { return "当前打开的是表格「\(f.name)」（原样预览中，用表格工具时会自动载入）" }
        var s = "当前打开的是表格「\(f.name)」，正在看工作表「\(sheet.name)」（\(Fmt.number(sheet.rows.count)) 行 × \(sheet.columnCount) 列"
        if let h = query.headerRowIndex { s += "，第 \(h + 1) 行是表头" }
        s += "）"
        if let sel = selectionAddress { s += "，选中了 \(sel)" }
        if query.isFiltered { s += "，视图已筛选（显示 \(Fmt.number(visible.count)) 行）" }
        return s + "。"
    }

    /// "B2:D30" for the current selection (nil for a single cell at A1 nobody chose).
    var selectionAddress: String? {
        guard let g = rects.last, !visible.isEmpty else { return nil }
        let r0 = visible[min(g.r0, visible.count - 1)] + 1, r1 = visible[min(g.r1, visible.count - 1)] + 1
        if g.cellCount == 1 { return g.r0 == 0 && g.c0 == 0 ? nil : "\(Sheet.columnName(g.c0))\(r0)" }
        return "\(Sheet.columnName(g.c0))\(r0):\(Sheet.columnName(g.c1))\(r1)"
    }

    var aiTools: [AIToolSpec] {
        let sheetArg = Schema.string("工作表名称（不填则为当前工作表）")
        let col = Schema.string("列：列字母（如 B）或表头里的列名（如 销售额）")
        return [
            AIToolSpec(
                "sheet_overview", "查看当前表格的结构：各工作表大小、表头各列名称与类型、前几行样例、当前选区。处理表格前先调用。",
                Schema.object(["sheet": sheetArg])),
            AIToolSpec(
                "read_cells", "读取一个区域的单元格值（制表符分隔，带行号）。区域如 A1:F50、B:D、2:20。一次最多 300 行。",
                Schema.object(["range": Schema.string("区域"), "sheet": sheetArg], required: ["range"])),
            AIToolSpec(
                "calculate",
                "用 Perlustra 的公式引擎精确计算一个 Excel 公式并返回结果，如 SUM(C:C)、AVERAGEIFS(D:D,B:B,\"上海\")、VLOOKUP(\"S01\",A:C,3,0)、COUNTIF。可跨文件引用：[其他文件.xlsx]工作表!A:C（同一文件夹内的文件）。任何数字结论都应该用它算，不要心算。",
                Schema.object(["formula": Schema.string("公式，可带或不带 ="), "sheet": sheetArg], required: ["formula"])),
            AIToolSpec(
                "summarize", "分组汇总（数据透视）：按一列或多列分组，对数值列求合计/行数/平均/最大/最小/不同值个数，结果按第一项降序，带总计行。可只统计满足条件的行，可直接存成新的 Excel 文件。",
                Schema.object(
                    [
                        "group_by": Schema.array("分组列（列字母或列名）", items: col),
                        "values": Schema.array("要统计的列；aggregate=count 时可省略", items: col),
                        "aggregate": Schema.string("统计方式", enum: SheetSummary.Aggregate.allCases.map(\.rawValue)),
                        "where_column": Schema.string("（可选）只统计这一列满足条件的行"),
                        "where_op": Schema.string("（可选）条件", enum: ["equals", "contains", "greater", "less", "not_blank"]),
                        "where_value": Schema.string("（可选）条件值"),
                        "save_as": Schema.string("（可选）把结果另存为的文件路径，.xlsx 或 .csv；相对路径以当前文件所在文件夹为准"),
                        "sheet": sheetArg,
                    ], required: ["group_by", "aggregate"])),
            AIToolSpec(
                "add_column",
                "在表格最右边加一列计算结果（只在屏幕上，不改原文件，可再用 export_view 存成新文件）。公式按第一行数据来写，相对引用会逐行下移，例如数据从第 2 行开始时写 =C2*D2 或 =VLOOKUP(A2,[门店表.xlsx]门店!A:C,2,0)。",
                Schema.object(["name": Schema.string("新列的标题"), "formula": Schema.string("按第一行数据写的公式")], required: ["name", "formula"])),
            AIToolSpec(
                "filter_view", "筛选屏幕上的表格，让用户直接看到结果（不改文件）。op=clear 清除所有筛选。",
                Schema.object(
                    [
                        "column": col,
                        "op": Schema.string("条件", enum: ["equals", "contains", "not_contains", "greater", "less", "between", "blank", "not_blank", "clear"]),
                        "value": Schema.string("条件值；between 写成 \"10,20\""), "sort": Schema.string("（可选）筛完后按这列排序", enum: ["asc", "desc"]),
                    ],
                    required: ["op"])),
            AIToolSpec(
                "select_cells", "在表格里选中并滚动到一个区域，给用户指出位置（如找到的异常值）。",
                Schema.object(["range": Schema.string("区域，如 B12 或 A5:F5")], required: ["range"])),
            AIToolSpec(
                "export_view", "把当前屏幕上的视图（已应用的筛选、排序和计算列）另存为新的 .xlsx 或 .csv 文件。",
                Schema.object(["path": Schema.string("文件路径；相对路径以当前文件所在文件夹为准")], required: ["path"])),
        ]
    }

    func aiRun(_ name: String, _ args: AIJSON) async -> AIToolOutput {
        if !workbookLoaded {
            viewMode = 0
            loadWorkbookForTools()
            await workbookTask?.value
            guard workbookLoaded else { return .error("这个表格无法载入表格工具") }
        }
        if let n = args["sheet"]?.string, !n.isEmpty {
            guard let i = workbook.sheetIndex(named: n) else {
                return .error("没有叫「\(n)」的工作表。现有：" + workbook.sheets.map(\.name).joined(separator: "、"))
            }
            if i != sheetIndex { switchSheet(i) }
        }
        switch name {
        case "sheet_overview": return overview()
        case "read_cells": return readCells(args["range"]?.string ?? "")
        case "calculate": return await calculate(args["formula"]?.string ?? "")
        case "summarize": return summarize(args)
        case "add_column": return await addColumn(args)
        case "filter_view": return filterView(args)
        case "select_cells": return selectCells(args["range"]?.string ?? "")
        case "export_view": return exportView(args["path"]?.string ?? "")
        default: return .error("未知的表格工具 \(name)")
        }
    }

    // MARK: Reading

    private func overview() -> AIToolOutput {
        var out: [String] = []
        out.append(
            "文件「\(file?.name ?? "")」共 \(workbook.sheets.count) 张工作表："
                + workbook.sheets.enumerated().map { i, s in
                    "\(s.name)（\(Fmt.number(s.rows.count)) 行 × \(s.columnCount) 列\(s.isHidden ? "，原文件中隐藏" : "")）" + (i == sheetIndex ? "←当前" : "")
                }.joined(separator: "；"))
        let s = sheet
        let first = query.firstDataRow
        if let h = query.headerRowIndex {
            out.append("表头在第 \(h + 1) 行，数据从第 \(first + 1) 行开始到第 \(s.rows.count) 行。各列：")
        } else {
            out.append("没有表头行，数据从第 1 行开始。各列：")
        }
        let probe = Array(first..<min(s.rows.count, first + 200))
        for c in 0..<min(s.columnCount, 60) {
            let title = query.headerRowIndex.map { s.cell($0, c).display } ?? ""
            let vals = probe.map { s.cell($0, c) }.filter { !$0.isEmpty }
            let numbers = vals.filter { $0.strictNumber != nil }.count
            let kind =
                vals.isEmpty
                ? "空"
                : numbers * 10 >= vals.count * 8
                    ? "数字"
                    : vals.contains {
                        if case .date = $0 { return true }; return false
                    } ? "日期" : "文字"
            let sample = vals.prefix(3).map { String($0.display.prefix(20)) }.joined(separator: " / ")
            out.append("  \(Sheet.columnName(c)) \(title.isEmpty ? "（无标题）" : "「\(title)」") \(kind)  例：\(sample)")
        }
        if s.columnCount > 60 { out.append("  …共 \(s.columnCount) 列，只列出前 60 列") }
        if !s.merges.isEmpty { out.append("有 \(s.merges.count) 处合并单元格。") }
        if let sel = selectionAddress { out.append("用户当前选中 \(sel)。") }
        if query.isFiltered { out.append("视图已筛选，显示 \(Fmt.number(visible.count)) 行。") }
        return AIToolOutput(out.joined(separator: "\n"))
    }

    /// Sheet rows/columns a range covers, clamped to the data.
    private func span(_ text: String) -> (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        let s = sheet
        let maxRow = max(0, s.rows.count - 1), maxCol = max(0, s.columnCount - 1)
        if let rr = try? FormulaParser.parse("=" + t) {
            switch rr {
            case .ref(let c): return (c.row...c.row, c.col...c.col)
            case .range(let r):
                let r1 = min(r.r1 == Int.max ? maxRow : r.r1, maxRow), c1 = min(r.c1 == Int.max ? maxCol : r.c1, maxCol)
                guard r.r0 <= r1, r.c0 <= c1 else { return nil }
                return (r.r0...r1, r.c0...c1)
            default: break
            }
        }
        // Whole rows "2:20".
        let parts = t.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2, parts[0] >= 1, parts[0] <= parts[1] { return ((parts[0] - 1)...min(parts[1] - 1, maxRow), 0...maxCol) }
        return nil
    }

    private func readCells(_ range: String) -> AIToolOutput {
        guard let sp = span(range) else { return .error("看不懂区域「\(range)」，请写成 A1:F50 / B:D / 2:20") }
        let s = sheet
        let rows = Array(sp.rows.prefix(300))
        let cols = Array(sp.cols.prefix(40))
        var lines = ["行\t" + cols.map { Sheet.columnName($0) }.joined(separator: "\t")]
        for r in rows {
            lines.append(
                "\(r + 1)\t"
                    + cols.map { c in
                        let v = workbook.formatted(sheetIndex, r, c).text
                        return (v.isEmpty ? s.cell(r, c).display : v).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                    }.joined(separator: "\t"))
        }
        if sp.rows.count > rows.count { lines.append("…（区域共 \(sp.rows.count) 行，只读了前 300 行；需要后面的请再读下一段）") }
        if sp.cols.count > cols.count { lines.append("…（区域共 \(sp.cols.count) 列，只读了前 40 列）") }
        return AIToolOutput(lines.joined(separator: "\n"))
    }

    private func calculate(_ formula: String) async -> AIToolOutput {
        let t = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .error("公式是空的") }
        let f = t.hasPrefix("=") ? t : "=" + t
        let wb = workbook, si = sheetIndex
        let books = await externalBooks(for: f)
        let missing = FormulaEngine.externalBookNames(in: f).filter { books[$0.lowercased()] == nil }
        if !missing.isEmpty { return .error("找不到引用的文件：" + missing.joined(separator: "、") + "（需要和当前文件在同一文件夹）") }
        let v = await Task.detached(priority: .userInitiated) {
            FormulaEngine.evaluate(f, in: FormulaContext(workbook: wb, sheet: si, externalWorkbooks: books))
        }.value
        calcText = f
        resultText = v.display
        resultIsError = v.isErrorValue
        return AIToolOutput("\(f) = \(v.display)", isError: v.isErrorValue)
    }

    // MARK: Columns

    /// A column given as a letter ("B") or by its header ("销售额").
    func aiColumn(_ text: String?) -> Int? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let h = query.headerRowIndex {
            let s = sheet
            if let c = (0..<s.columnCount).first(where: { s.cell(h, $0).display.trimmingCharacters(in: .whitespaces) == t }) { return c }
            if let c = (0..<s.columnCount).first(where: { s.cell(h, $0).display.localizedCaseInsensitiveContains(t) }) { return c }
        }
        let letters = t.uppercased().replacingOccurrences(of: "列", with: "")
        if letters.allSatisfy({ $0.isASCII && $0.isLetter }), let c = Sheet.columnIndex(letters), c < max(1, sheet.columnCount) { return c }
        return nil
    }

    private func columnError(_ t: String?) -> AIToolOutput {
        let names =
            query.headerRowIndex.map { h in
                (0..<min(sheet.columnCount, 40)).map { "\(Sheet.columnName($0))=\(sheet.cell(h, $0).display)" }.joined(separator: "，")
            } ?? ""
        return .error("找不到列「\(t ?? "")」。" + (names.isEmpty ? "" : "现有列：\(names)"))
    }

    private func rule(_ op: String, _ value: String) -> FilterRule? {
        switch op {
        case "equals": return .equals(value)
        case "contains": return .contains(value)
        case "not_contains": return .notContains(value)
        case "greater": return CellValue.parseNumber(value).map { .greater($0) }
        case "less": return CellValue.parseNumber(value).map { .less($0) }
        case "between":
            let n = value.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "~" || $0 == "-" }).compactMap { CellValue.parseNumber(String($0)) }
            return n.count == 2 ? .between(min(n[0], n[1]), max(n[0], n[1])) : nil
        case "blank": return .blank
        case "not_blank": return .notBlank
        default: return nil
        }
    }

    private func summarize(_ args: AIJSON) -> AIToolOutput {
        let groupNames = args["group_by"]?.stringList ?? []
        var groups: [Int] = []
        for g in groupNames { guard let c = aiColumn(g) else { return columnError(g) }; groups.append(c) }
        var values: [Int] = []
        for v in args["values"]?.stringList ?? [] { guard let c = aiColumn(v) else { return columnError(v) }; values.append(c) }
        guard let agg = SheetSummary.Aggregate(rawValue: args["aggregate"]?.string ?? "sum") else {
            return .error("aggregate 只能是 sum/count/average/max/min/distinct")
        }
        if values.isEmpty && agg != .count { return .error("要统计哪一列？请给出 values") }
        let s = sheet
        var rows = Array(query.firstDataRow..<s.rows.count)
        var condition = ""
        if let wc = args["where_column"]?.string, !wc.isEmpty {
            guard let c = aiColumn(wc) else { return columnError(wc) }
            let op = args["where_op"]?.string ?? "equals"
            guard let r = rule(op, args["where_value"]?.string ?? "") else { return .error("条件写得不对") }
            rows = rows.filter { r.matches(s.cell($0, c)) }
            condition = "（只统计 \(wc) \(r.summary) 的 \(Fmt.number(rows.count)) 行）"
        }
        // Skip blank rows (common at the bottom of exported sheets).
        rows = rows.filter { r in !(groups + values).allSatisfy { s.cell(r, $0).isEmpty } }
        let table = SheetSummary.groupBy(s, rows: rows, header: query.headerRowIndex, groupColumns: groups, valueColumns: values, aggregate: agg)
        var text = "分组汇总\(condition)，共 \(table.count - (groups.isEmpty ? 1 : 2)) 组：\n" + SheetSummary.tsv(table, limit: 200)
        var created: [URL] = []
        if let path = args["save_as"]?.string, !path.isEmpty {
            switch AIFiles.writeTable([(name: "汇总", rows: table)], to: path, near: file?.url) {
            case .success(let url):
                text += "\n\n已另存为 \(url.path)"
                created.append(url)
            case .failure(let e): return .error(text + "\n\n另存失败：\(e.message)")
            }
        }
        return AIToolOutput(text, createdFiles: created)
    }

    private func addColumn(_ args: AIJSON) async -> AIToolOutput {
        guard let f = args["formula"]?.string, !f.isEmpty else { return .error("缺少公式") }
        let name = args["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "计算列"
        switch await appendComputedColumn(formula: f, baseRow: query.firstDataRow, name: name) {
        case .failure(let e): return .error("公式有误：\(e.message)")
        case .success(let r):
            let sample = r.sample.map(\.display).joined(separator: " / ")
            return AIToolOutput(
                "已在 \(Sheet.columnName(r.column)) 列加入「\(name)」，共 \(r.rows) 行" + (r.errors > 0 ? "，其中 \(r.errors) 行出错" : "") + "。前几行：\(sample)。（只在屏幕上，原文件未改）",
                isError: r.errors == r.rows && r.rows > 0)
        }
    }

    private func filterView(_ args: AIJSON) -> AIToolOutput {
        let op = args["op"]?.string ?? ""
        if op == "clear" { clearFilters(); return AIToolOutput("已清除筛选，显示全部 \(Fmt.number(visible.count)) 行") }
        guard let c = aiColumn(args["column"]?.string) else { return columnError(args["column"]?.string) }
        guard let r = rule(op, args["value"]?.string ?? "") else { return .error("条件写得不对（op=\(op)）") }
        setFilter(r, column: c)
        if let sort = args["sort"]?.string { self.sort(column: c, ascending: sort != "desc") }
        return AIToolOutput("已筛选：\(Sheet.columnName(c)) 列 \(r.summary)，现在显示 \(Fmt.number(visible.count)) 行")
    }

    private func selectCells(_ range: String) -> AIToolOutput {
        guard let sp = span(range) else { return .error("看不懂区域「\(range)」") }
        guard let v0 = viewRow(ofSheetRow: sp.rows.lowerBound) else { return .error("第 \(sp.rows.lowerBound + 1) 行被筛选或隐藏了，看不到") }
        let v1 = viewRow(ofSheetRow: sp.rows.upperBound) ?? v0
        let a = GridPoint(row: v0, col: sp.cols.lowerBound), b = GridPoint(row: v1, col: sp.cols.upperBound)
        gridSelect([GridRect(a, b)], active: a, anchor: a)
        grid.scrollTo(row: v0, col: sp.cols.lowerBound)
        return AIToolOutput("已选中 \(range)")
    }

    private func exportView(_ path: String) -> AIToolOutput {
        let cols = gridVisibleColumns()
        let rows: [[CellValue]] = visible.map { r in cols.map { sheet.cell(r, $0) } }
        switch AIFiles.writeTable([(name: sheet.name, rows: rows)], to: path, near: file?.url) {
        case .success(let url): return AIToolOutput("已导出 \(Fmt.number(rows.count)) 行到 \(url.path)", createdFiles: [url])
        case .failure(let e): return .error(e.message)
        }
    }
}
