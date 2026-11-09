import AppKit
import PerlustraCore

/// Context menus for cells, column headers and row numbers.
extension SpreadsheetRenderer {
    // MARK: Menus

    private func menu(_ build: (_ item: (String, @escaping () -> Void) -> Void, _ sep: () -> Void) -> Void) -> NSMenu {
        let m = NSMenu()
        build(
            { t, f in
                let i = NSMenuItem(title: t, action: #selector(MenuAction.fire), keyEquivalent: "")
                let a = MenuAction(f)
                i.target = a
                i.representedObject = a
                m.addItem(i)
            }, { m.addItem(.separator()) })
        return m
    }

    /// Rows / columns the selection spans (view rows, sheet columns on screen).
    var selectedRowCount: Int { rects.last.map { min($0.r1, visible.count - 1) - $0.r0 + 1 } ?? 1 }
    var selectedColumnCount: Int { rects.last.map { r in layout.cols.filter { $0 >= r.c0 && $0 <= r.c1 }.count } ?? 1 }

    private func addStructureItems(_ item: (String, @escaping () -> Void) -> Void, rows: Bool, cols: Bool) {
        let n = max(1, selectedRowCount), k = max(1, selectedColumnCount)
        if rows {
            item("在上方插入 \(n) 行") { [weak self] in self?.insertRows(below: false) }
            item("在下方插入 \(n) 行") { [weak self] in self?.insertRows(below: true) }
        }
        if cols {
            item("在左侧插入 \(k) 列") { [weak self] in self?.insertColumns(right: false) }
            item("在右侧插入 \(k) 列") { [weak self] in self?.insertColumns(right: true) }
        }
        if rows { item("删除所选的 \(n) 行") { [weak self] in self?.deleteSelectedRows() } }
        if cols { item("删除所选的 \(k) 列") { [weak self] in self?.deleteSelectedColumns() } }
    }

    func gridMenu(at point: GridPoint?) -> NSMenu? {
        menu { item, sep in
            if let p = point, fullText(row: p.row, col: p.col) != nil {
                item("查看完整内容") { [weak self] in self?.gridShowFullText(p) }
            }
            item("拷贝") { [weak self] in self?.gridCopy() }
            item("拷贝统计结果") { [weak self] in self?.copyStats() }
            item("把选区填进计算框") { [weak self] in self?.insertSelectionReference() }
            if editingEnabled {
                item("粘贴") { [weak self] in if let t = NSPasteboard.general.string(forType: .string) { self?.gridPaste(t) } }
                item("清除内容") { [weak self] in self?.gridClearSelection() }
                sep()
                if canMergeSelection { item("合并单元格") { [weak self] in self?.mergeSelection() } }
                if canUnmergeSelection { item("取消合并") { [weak self] in self?.unmergeSelection() } }
                if canMergeSelection || canUnmergeSelection { sep() }
                addStructureItems(item, rows: true, cols: true)
            }
            if let p = point, p.col >= 0, p.row < visible.count {
                let value = sheet.cell(visible[p.row], p.col).display
                let short = value.count > 16 ? String(value.prefix(16)) + "…" : value
                sep()
                item("只显示「\(short)」") { [weak self] in self?.setFilter(.values([value]), column: p.col) }
                item("排除「\(short)」") { [weak self] in
                    guard let self else { return }
                    let all = Set(self.query.distinctValues(in: self.sheet, column: p.col, limit: 100_000).map(\.0))
                    self.setFilter(.values(all.subtracting([value])), column: p.col)
                }
                item("升序排序") { [weak self] in self?.sort(column: p.col, ascending: true) }
                item("降序排序") { [weak self] in self?.sort(column: p.col, ascending: false) }
                item("筛选此列…") { [weak self] in self?.openColumnPanel(p.col) }
                let row = visible[p.row]
                if row != query.firstDataRow || query.sortColumn == nil {
                    sep()
                    item("从第 \(row + 1) 行往下升序排序") { [weak self] in self?.sort(fromSheetRow: row, column: p.col, ascending: true) }
                    item("从第 \(row + 1) 行往下降序排序") { [weak self] in self?.sort(fromSheetRow: row, column: p.col, ascending: false) }
                    item("从第 \(row + 1) 行往下筛选此列…") { [weak self] in self?.openFilter(fromSheetRow: row, column: p.col) }
                }
            }
            sep()
            item("隐藏所选行") { [weak self] in self?.hideSelectedRows() }
            item("隐藏所选列") { [weak self] in
                guard let self else { return }
                self.hideColumns(Array(Set(self.rects.flatMap { Array($0.c0...$0.c1) })))
            }
            if hiddenCount.rows + hiddenCount.cols > 0 { item("显示全部隐藏的行和列") { [weak self] in self?.unhideAll() } }
            if isFiltered { item("清除筛选和排序") { [weak self] in self?.clearFilters() } }
        }
    }

    func gridColumnMenu(column c: Int) -> NSMenu? {
        menu { item, sep in
            item("排序与筛选…") { [weak self] in self?.openColumnPanel(c) }
            item("升序排序") { [weak self] in self?.sort(column: c, ascending: true) }
            item("降序排序") { [weak self] in self?.sort(column: c, ascending: false) }
            if editingEnabled {
                sep()
                addStructureItems(item, rows: false, cols: true)
            }
            sep()
            item(headerRow ? "取消表头" : "自动识别表头") { [weak self] in
                guard let self else { return }
                self.setHeaderRow(!self.headerRow)
            }
            item("自动调整列宽") { [weak self] in self?.gridAutoFitColumn(c) }
            item("隐藏所选列") { [weak self] in
                guard let self else { return }
                self.hideColumns(Array(Set(self.rects.flatMap { Array($0.c0...$0.c1) })))
            }
            if hiddenCount.cols > 0 { item("显示全部隐藏的列") { [weak self] in self?.unhideAll() } }
        }
    }

    func gridRowMenu(row: Int) -> NSMenu? {
        menu { item, sep in
            if editingEnabled {
                addStructureItems(item, rows: true, cols: false)
                sep()
            }
            if visible.indices.contains(row) {
                let sheetRow = visible[row]
                item("从第 \(sheetRow + 1) 行开始排序和筛选") { [weak self] in self?.startData(atSheetRow: sheetRow) }
                if sheetRow + 1 < sheet.rows.count {
                    item("把第 \(sheetRow + 1) 行当表头") { [weak self] in self?.startData(atSheetRow: sheetRow + 1) }
                }
                sep()
            }
            item("隐藏所选行") { [weak self] in self?.hideSelectedRows() }
            if hiddenCount.rows > 0 { item("显示全部隐藏的行") { [weak self] in self?.unhideAll() } }
        }
    }

    func gridCopy() {
        guard let rect = rects.last else { return }
        var lines: [String] = []
        let cols = layout.cols.filter { $0 >= rect.c0 && $0 <= rect.c1 }
        for r in rect.r0...min(rect.r1, visible.count - 1) {
            lines.append(cols.map { sheet.cell(visible[r], $0).display.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
