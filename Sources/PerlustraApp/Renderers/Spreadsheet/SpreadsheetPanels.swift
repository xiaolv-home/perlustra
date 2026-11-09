import SwiftUI
import AppKit
import PerlustraCore

/// Address box, formula field with live result, fill-down button and find.
struct FormulaBar: View {
    @ObservedObject var r: SpreadsheetRenderer
    @FocusState private var searchFocused: Bool
    @FocusState private var calcFocused: Bool
    @FocusState private var cellFocused: Bool
    @State private var showFunctions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            if r.viewMode == 0, calcFocused || r.calcText.hasPrefix("="),
                let ctx = FunctionCatalog.context(beforeCursor: r.normalizedCalc)
            {
                FunctionHint(doc: ctx.doc, argument: ctx.argument)
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            if r.viewMode == 1 {
                Text("原样（系统预览，含图表、条件格式；只能看）· ⌘+ / ⌘− 缩放")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button("返回表格") { r.viewMode = 0 }.controlSize(.small)
            } else {
                tools
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color(nsColor: Theme.sheet))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
        .onChange(of: r.focusSearch) { _, v in if v { searchFocused = true; r.focusSearch = false } }
    }

    @ViewBuilder private var tools: some View {
        // Where you are and what is in the cell.
        Text(r.address)
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .frame(minWidth: 52)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.15)))
        Group {
            if r.editingEnabled {
                TextField("单元格内容，回车写入", text: $r.formulaText)
                    .textFieldStyle(.plain)
                    .focused($cellFocused)
                    .onSubmit { r.commitFormulaBar() }
                if r.formulaText.count > 24 {
                    Button {
                        r.showActiveCellText()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("看完整内容")
                }
            } else {
                Button {
                    r.showActiveCellText()
                } label: {
                    Text(r.formulaText.isEmpty ? " " : r.formulaText)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(r.formulaText.isEmpty ? "" : "点一下看完整内容（也可以双击单元格或按空格）")
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(minWidth: 80, maxWidth: 240, alignment: .leading)
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16)

        // The calculator.
        HStack(spacing: 6) {
            Button {
                showFunctions.toggle()
            } label: {
                Text("ƒx").font(.system(size: 13, weight: .semibold, design: .serif)).italic().foregroundStyle(Theme.ember)
            }
            .buttonStyle(.plain)
            .help("函数说明（求和、VLOOKUP、SUMIF…）")
            .popover(isPresented: $showFunctions, arrowEdge: .bottom) {
                FunctionPanel { text, replace in
                    if replace { r.calcText = text } else if r.calcText.hasPrefix("=") { r.calcText += text } else { r.calcText = "=" + text }
                    showFunctions = false
                    calcFocused = true
                }
            }
            TextField("计算：输入公式按回车，如 =SUM(D2:D30)、=VLOOKUP(A2,[门店表.xlsx]Sheet1!A:C,2,0)", text: $r.calcText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($calcFocused)
                .onSubmit { r.calculate() }
            if !r.resultText.isEmpty {
                HStack(spacing: 5) {
                    Text("=").foregroundStyle(.secondary)
                    Text(r.resultText).lineLimit(1).textSelection(.enabled)
                        .foregroundStyle(r.resultIsError ? Theme.ember : Color.primary)
                    Button {
                        r.copyResult()
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("拷贝结果")
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.emberSoft))
                .frame(maxWidth: 280)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(calcFocused ? 0.07 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(calcFocused ? Theme.ember.opacity(0.6) : Color.primary.opacity(0.1)))
        .frame(minWidth: 220)
        BarTextButton(title: "填入选区", symbol: "rectangle.dashed", help: "把表格里选中的区域（如 D2:D30）填进计算框") {
            r.insertSelectionReference(); calcFocused = true
        }
        BarTextButton(title: "引用其他文件", symbol: "doc.badge.plus", help: "选一个表格文件，把它的工作表填进公式（跨表格 VLOOKUP 等）") {
            r.chooseExternalFile()
        }
        BarTextButton(title: "每行套用", symbol: "arrow.down.to.line", help: "以选中的行为准，把公式套用到每一行，结果作为新的一列显示在最右边（不改原文件，可导出）") {
            r.fillComputedColumn()
        }
        .disabled(r.normalizedCalc.isEmpty)
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16)

        // Find, and the original preview.
        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
        TextField("查找", text: $r.searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .frame(width: 110)
            .focused($searchFocused)
            .onSubmit { r.runSearch(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) }
            .help("回车：下一个 · ⇧回车：上一个")
        if !r.searchInfo.isEmpty {
            Text(r.searchInfo).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).fixedSize()
            LensButton(symbol: "chevron.up", help: "上一个") { r.findNext(-1) }
            LensButton(symbol: "chevron.down", help: "下一个") { r.findNext(1) }
        }
        LensButton(symbol: "eye", help: "原样：用系统预览看原文件（图表、条件格式等）；⌘U") { r.viewMode = 1 }
    }
}

/// Small icon-and-word button for the calculator bar.
struct BarTextButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .medium))
                Text(title).font(.system(size: 11.5))
            }
            .foregroundStyle(enabled ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.5))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .fixedSize()
    }
}

/// Worksheet tabs along the bottom edge, like the tabs of a ledger.
struct SheetTabs: View {
    @ObservedObject var r: SpreadsheetRenderer
    var body: some View {
        let tabs = r.tabSheets, hidden = r.hiddenSheetCount
        if tabs.count > 1 || hidden > 0 {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(tabs, id: \.self) { i in tab(i, r.workbook.sheets[i]) }
                    }
                    .padding(.horizontal, 8)
                }
                if hidden > 0 {
                    Button {
                        r.setShowHiddenSheets(!r.showHiddenSheets)
                    } label: {
                        Label(r.showHiddenSheets ? "收起隐藏的工作表" : "显示隐藏的 \(hidden) 张", systemImage: r.showHiddenSheets ? "eye.slash" : "eye")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).frame(height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ember)
                    .help(r.showHiddenSheets ? "隐藏原文件里隐藏的工作表" : "原文件隐藏了 \(hidden) 张工作表，点一下把它们也列出来")
                }
            }
            .frame(height: 30)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
        }
    }

    private func tab(_ i: Int, _ s: Sheet) -> some View {
        let current = i == r.sheetIndex
        return Button {
            r.switchSheet(i)
        } label: {
            HStack(spacing: 5) {
                if s.isHidden { Image(systemName: "eye.slash").font(.system(size: 9.5)) }
                Text(s.name).font(.system(size: 11.5, weight: current ? .semibold : .regular)).italic(s.isHidden)
                Text("\(s.rows.count)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).frame(height: 26)
            .foregroundStyle(current ? Color.primary : Color.secondary)
            .opacity(s.isHidden && !current ? 0.7 : 1)
            .background(current ? Color(nsColor: Theme.sheet) : Color.primary.opacity(0.04))
            .overlay(alignment: .top) {
                if current { Rectangle().fill(Theme.ember).frame(height: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(s.isHidden ? "「\(s.name)」在原文件里是隐藏的" : s.name)
    }
}

/// Status-strip tools: header toggle, filter / hidden indicators.
struct SheetStripControls: View {
    @ObservedObject var r: SpreadsheetRenderer
    var body: some View {
        if r.viewMode == 0 { tools }
    }

    private var tools: some View {
        HStack(spacing: 8) {
            if r.isFiltered {
                Button("清除筛选") { r.clearFilters() }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ember)
            }
            let h = r.hiddenCount
            if h.rows + h.cols > 0 {
                Button("显示隐藏的 \(h.rows > 0 ? "\(h.rows) 行" : "")\(h.rows > 0 && h.cols > 0 ? "、" : "")\(h.cols > 0 ? "\(h.cols) 列" : "")") { r.unhideAll() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ember)
            }
        }
    }
}

/// Column panel: sort, condition filter, value checklist, hide.
struct ColumnPanel: View {
    @ObservedObject var r: SpreadsheetRenderer
    let column: Int
    let close: () -> Void

    enum Cond: String, CaseIterable, Identifiable {
        case none = "不按条件", contains = "包含", notContains = "不包含", equals = "等于", greater = "大于", less = "小于",
            between = "介于", blank = "为空", notBlank = "非空"
        var id: String { rawValue }
    }

    @State private var cond: Cond = .none
    @State private var a = ""
    @State private var b = ""
    @State private var search = ""
    @State private var values: [(String, Int)] = []
    @State private var checked = Set<String>()

    var title: String {
        let h = r.query.headerRowIndex.map { r.sheet.cell($0, column).display } ?? ""
        return "列 \(Sheet.columnName(column))" + (h.isEmpty ? "" : " · \(h)")
    }

    var filtered: [(String, Int)] {
        search.isEmpty ? values : values.filter { $0.0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Button {
                    r.sort(column: column, ascending: true); close()
                } label: {
                    Label("升序", systemImage: "arrow.up")
                }
                Button {
                    r.sort(column: column, ascending: false); close()
                } label: {
                    Label("降序", systemImage: "arrow.down")
                }
                if r.query.sortColumn == column {
                    Button("取消排序") {
                        r.sort(column: column, ascending: nil); close()
                    }
                }
            }
            .controlSize(.small)

            Divider()
            SectionLabel(text: "按条件筛选")
            Picker("", selection: $cond) { ForEach(Cond.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().controlSize(.small)
            if ![.none, .blank, .notBlank].contains(cond) {
                HStack {
                    TextField(cond == .between ? "最小值" : "值", text: $a).textFieldStyle(.roundedBorder).controlSize(.small)
                    if cond == .between { TextField("最大值", text: $b).textFieldStyle(.roundedBorder).controlSize(.small) }
                }
            }
            if cond != .none {
                Button("应用条件") { applyCondition() }.controlSize(.small).keyboardShortcut(.defaultAction)
            }

            Divider()
            HStack {
                SectionLabel(text: "按值筛选")
                Spacer()
                Button("全选") { checked = Set(values.map(\.0)) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.ember)
                Button("全不选") { checked = [] }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.ember)
            }
            TextField("搜索值", text: $search).textFieldStyle(.roundedBorder).controlSize(.small)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(filtered.prefix(2000), id: \.0) { v, n in
                        Toggle(isOn: Binding(get: { checked.contains(v) }, set: { on in if on { checked.insert(v) } else { checked.remove(v) } })) {
                            HStack {
                                Text(v.isEmpty ? "（空白）" : v).lineLimit(1).font(.system(size: 12))
                                    .foregroundStyle(v.isEmpty ? .secondary : .primary)
                                Spacer()
                                Text("\(n)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(height: 180)
            HStack {
                Button("按值应用") {
                    r.setFilter(checked.count == values.count ? nil : .values(checked), column: column)
                    close()
                }
                .controlSize(.small)
                .disabled(checked.isEmpty)
                Spacer()
                if r.query.filters[column] != nil {
                    Button("清除此列筛选") {
                        r.setFilter(nil, column: column); close()
                    }.controlSize(.small)
                }
            }

            Divider()
            HStack {
                Button {
                    r.gridHeaderClicked(column: column, extend: false); close()
                } label: {
                    Label("选中整列", systemImage: "rectangle.portrait")
                }
                Spacer()
                Button {
                    r.hideColumns([column]); close()
                } label: {
                    Label("隐藏此列", systemImage: "eye.slash")
                }
            }
            .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            values = r.query.distinctValues(in: r.sheet, column: column)
            if case .values(let set) = r.query.filters[column] { checked = set } else { checked = Set(values.map(\.0)) }
            switch r.query.filters[column] {
            case .contains(let t): cond = .contains; a = t
            case .notContains(let t): cond = .notContains; a = t
            case .equals(let t): cond = .equals; a = t
            case .greater(let x): cond = .greater; a = CellValue.format(x)
            case .less(let x): cond = .less; a = CellValue.format(x)
            case .between(let x, let y): cond = .between; a = CellValue.format(x); b = CellValue.format(y)
            case .blank: cond = .blank
            case .notBlank: cond = .notBlank
            default: break
            }
        }
    }

    private func applyCondition() {
        let x = CellValue.parseNumber(a), y = CellValue.parseNumber(b)
        let rule: FilterRule?
        switch cond {
        case .none: rule = nil
        case .contains: rule = .contains(a)
        case .notContains: rule = .notContains(a)
        case .equals: rule = .equals(a)
        case .greater: rule = x.map { .greater($0) }
        case .less: rule = x.map { .less($0) }
        case .between: rule = (x != nil && y != nil) ? .between(min(x!, y!), max(x!, y!)) : nil
        case .blank: rule = .blank
        case .notBlank: rule = .notBlank
        }
        r.setFilter(rule, column: column)
        close()
    }
}
