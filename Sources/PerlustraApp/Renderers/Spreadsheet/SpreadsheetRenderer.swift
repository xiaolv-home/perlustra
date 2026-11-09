import AppKit
import SwiftUI
import PerlustraCore
import Quartz

/// Every table format (CSV/TSV, XLSX, ODS, and XLS/Numbers via Numbers) is converted into
/// Perlustra's own Workbook and shown in one grid with filtering, sorting, hiding, selection
/// statistics, formulas, editing and zoom.
@MainActor
final class SpreadsheetRenderer: NSObject, Renderer, ObservableObject, GridViewOwner {
    static let engineName = "表格"
    static let directExtensions: Set<String> = ["csv", "tsv", "tab", "xlsx", "xlsm", "xltx", "ods"]
    static let convertExtensions: Set<String> = ["xls", "xlt", "et", "numbers"]

    static func canHandle(_ file: FileContext) -> Bool {
        guard !file.isDirectory, file.size < 300 << 20 else { return false }
        if file.format.family == .csv { return true }
        let t = file.format.token.lowercased()
        return directExtensions.contains(file.ext) || convertExtensions.contains(file.ext)
            || ["xlsx", "xls", "ods"].contains(t) || file.format.iwork == .numbers
    }

    // Published UI state
    @Published var sheetIndex = 0
    /// Sheets the file hides get a tab only after the reader asks for them, as in Excel.
    @Published var showHiddenSheets = false
    @Published var formulaText = ""
    @Published var resultText = ""
    @Published var resultIsError = false
    @Published var address = "A1"
    @Published var searchText = ""
    /// The calculator bar's formula (never written into the file).
    @Published var calcText = ""
    /// Other workbooks referenced as [文件.xlsx]: picked by the user, and loaded ones.
    var externalURLs: [String: URL] = [:]
    var externalCache: [String: Workbook] = [:]
    @Published var searchInfo = ""
    @Published var headerRow = true
    /// One history per table, so ⌘Z never reaches into another tab sharing the window.
    let history = UndoManager()
    var documentUndoManager: UndoManager? { history }

    /// The workbook and its unsaved changes; the grid only shows and edits it.
    var doc = SpreadsheetDocument(workbook: Workbook(sheets: [], source: ""))
    var workbook: Workbook { doc.workbook }
    var resizeSnapshot: Snapshot?
    @Published var dirty = false
    var editor: CellEditor?
    /// The .xlsx we patch on save: the file itself, or Numbers' conversion of xls/numbers.
    var saveBase: URL?
    var queries: [SheetQuery] = []
    private(set) var visible: [Int] = []
    var rects: [GridRect] = []
    var active = GridPoint(row: 0, col: 0)
    var anchor = GridPoint(row: 0, col: 0)
    var matchKeys = Set<Int>()
    var matchList: [GridPoint] = []
    var matchCursor = -1
    var matchQuery = ""
    var computedCount = 0

    // Layout and drawing caches (see SpreadsheetPainter)
    var layout = GridLayout()
    @Published var zoom: CGFloat = 1
    var autoWidths: [Int: CGFloat] = [:]
    var autoWidthsFor = -1
    var fitHeights: [Int: CGFloat] = [:]
    var mergeTopLeft: [Int: MergeRange] = [:]
    var mergeCovered = Set<Int>()
    var mergeViews: [MergeView] = []
    var activeMerges: [Int: Int] = [:]
    var viewRowOf: [Int] = []
    var lookCache: [CellLookKey: CellLook] = [:]
    /// Data bars and colour-scale fills by cell key (worked out again when values change).
    var conditional: [Int: ConditionalCell] = [:]
    /// Charts, pictures and shapes over the cells (see SpreadsheetDrawings).
    let drawingPainter = DrawingPainter()

    let grid = GridView()
    let container = NSView()
    var popover: NSPopover?
    /// The panel showing a cell's whole text.
    var cellTextPanel: NSPopover?
    weak var host: RenderHost?
    var file: FileContext?
    var converted: String?

    required override init() { super.init() }

    var sheet: Sheet { workbook.sheets.indices.contains(sheetIndex) ? workbook.sheets[sheetIndex] : Sheet(name: "", rows: []) }
    var query: SheetQuery {
        get { queries.indices.contains(sheetIndex) ? queries[sheetIndex] : SheetQuery() }
        set { if queries.indices.contains(sheetIndex) { queries[sheetIndex] = newValue } }
    }

    var stats = SelectionStats([])

    // MARK: Loading

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.file = file
        self.host = host
        buildView()
        // Perlustra is a viewer first: formatted workbooks open as they look in Excel, and are only
        // parsed (or converted by Numbers) once the table tools are asked for. Text tables (CSV)
        // have no formatting, so they open in the table tools.
        if file.format.family != .csv && AppSettings.shared.spreadsheetOpensOriginal {
            let url = file.url
            let saved = await Task.detached(priority: .userInitiated) { SpreadsheetReader.savedZoom(xlsx: url) }.value
            originalSheetZoom = saved.map { CGFloat($0) / 100 } ?? 1
            viewMode = 1
            return container
        }
        try await loadWorkbook()
        return container
    }

    /// True once the file has been read into Perlustra's own table.
    private(set) var workbookLoaded = false
    var workbookTask: Task<Void, Never>?
    private var originalSheetZoom: CGFloat = 1

    /// Reads (and for xls/Numbers, converts) the workbook into the table tools.
    private func loadWorkbook() async throws {
        guard let file, let host else { return }
        let url = file.url
        let ext = file.ext
        let token = file.format.token.lowercased()
        let delimiter = file.format.delimiter
        let isCSV = file.format.family == .csv
        let needsConversion = Self.convertExtensions.contains(ext) || file.format.iwork == .numbers || (token == "xls" && ext != "xlsx")

        var source = url
        if needsConversion {
            guard DocumentExporter.appURL(.numbers) != nil else {
                throw RenderError.unsupported("此格式需要 Numbers 转换后才能用表格工具打开")
            }
            host.reportProgress(nil, label: "正在通过 Numbers 转换表格…")
            do {
                source = try await DocumentExporter.export(url, with: .numbers, as: .xlsx)
                converted = "由 Numbers 转换"
                saveBase = source
            } catch ExportError.notAuthorized {
                host.showNotice(
                    "需要允许 Perlustra 控制 Numbers 才能用表格工具打开此文件（系统设置 › 隐私与安全性 › 自动化）。", style: .warning,
                    action: NoticeAction(title: "打开设置") { DocumentExporter.openAutomationSettings() })
                throw RenderError.unsupported("没有「自动化」权限")
            }
        } else if file.size > 4 << 20 {
            host.reportProgress(nil, label: "正在读取表格…")
        }
        let isODS = ext == "ods" || token == "ods"
        if !needsConversion && !isCSV && !isODS { saveBase = url }
        var wb: Workbook = try await Task.detached(priority: .userInitiated) {
            if isCSV { return try SpreadsheetReader.readDelimited(url: source, delimiter: delimiter) }
            if isODS { return try SpreadsheetReader.readODS(url: source) }
            return try SpreadsheetReader.readXLSX(url: source)
        }.value
        try Task.checkCancellation()
        host.reportProgress(nil, label: nil)
        // An empty workbook is shown as the empty table it is.
        if wb.sheets.isEmpty { wb.sheets = [Sheet(name: "Sheet1", rows: [])] }
        doc = SpreadsheetDocument(workbook: wb)
        queries = wb.sheets.map { s in
            var q = SheetQuery()
            q.headerRowIndex = SheetQuery.guessedHeaderRow(in: s)
            q.hiddenRows = s.hiddenRows
            q.hiddenColumns = s.hiddenColumns
            return q
        }
        // Open where the file opens (its active tab), unless that one is hidden or blank.
        let shown = wb.sheets.indices.filter { !wb.sheets[$0].isHidden }
        sheetIndex =
            ([wb.activeSheet] + shown).first { i in
                shown.contains(i) && (!wb.sheets[i].rows.isEmpty || wb.sheets[i].isChartSheet)
            } ?? shown.first ?? 0
        workbookLoaded = true
        originalSheetZoom = CGFloat(wb.sheets[sheetIndex].zoomScale) / 100
        reloadSheet(resetSelection: true)
        adoptSavedZoom()
    }

    /// Switching to the table tools the first time reads the workbook in the background.
    func loadWorkbookForTools() {
        guard !workbookLoaded, workbookTask == nil else { return }
        workbookTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.loadWorkbook()
                if self.viewMode == 0 { self.container.window?.makeFirstResponder(self.grid) }
            } catch {
                self.host?.reportProgress(nil, label: nil)
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.host?.showNotice("无法用表格工具打开：\(msg)", style: .warning, action: nil)
                self.viewMode = 1
            }
            self.workbookTask = nil
            self.host?.rendererDidUpdate()
        }
    }

    private func buildView() {
        grid.owner = self
        let bar = RendererHostingView(FormulaBar(r: self))
        bar.sizingOptions = [.intrinsicContentSize]
        let tabs = RendererHostingView(SheetTabs(r: self))
        tabs.sizingOptions = [.intrinsicContentSize]
        for v in [bar, body] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        for v in [grid, tabs] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            grid.topAnchor.constraint(equalTo: body.topAnchor),
            grid.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: grid.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            tabs.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    // MARK: Original view

    /// 0 = Perlustra's table tools, 1 = the original file through Quick Look (full fidelity, read-only).
    @Published var viewMode = 0 { didSet { if viewMode != oldValue { applyViewMode() } } }
    private let body = NSView()
    private var original: OriginalPreview?
    var originalView: NSView? { original }
    /// Zoom of the original preview relative to the file's own saved zoom (pinches included).
    var originalZoom: CGFloat {
        get { original?.zoom ?? 1 }
        set { objectWillChange.send(); original?.zoom = newValue }
    }

    private func applyViewMode() {
        if viewMode == 1 {
            endEditing(commit: true)
            // Quick Look shows the sheet the workbook opens on, at the zoom Excel saved.
            if original == nil, let url = file?.url, let o = OriginalPreview(url: url, sheetZoom: originalSheetZoom) {
                o.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(o)
                NSLayoutConstraint.activate([
                    o.topAnchor.constraint(equalTo: body.topAnchor), o.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                    o.leadingAnchor.constraint(equalTo: body.leadingAnchor), o.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                ])
                original = o
            }
            original?.isHidden = false
            body.isHidden = true
            container.window?.makeFirstResponder(original?.focusView)
        } else {
            original?.isHidden = true
            body.isHidden = false
            container.window?.makeFirstResponder(grid)
            loadWorkbookForTools()
        }
        host?.rendererDidUpdate()
    }

    // MARK: Sheet / query

    func reloadSheet(resetSelection: Bool = false) {
        headerRow = query.headerRow
        visible = query.visibleRows(in: sheet)
        rebuildMerges()
        if autoWidthsFor != sheetIndex { rebuildAutoWidths(); autoWidthsFor = sheetIndex }
        rebuildFitHeights()
        lookCache = [:]
        conditional = ConditionalFormatting.evaluate(sheet)
        // Cell values may have changed: charts read them again.
        drawingPainter.reset()
        rebuildLayout()
        if resetSelection || active.row >= visible.count || active.col >= sheet.columnCount {
            let start = GridPoint(row: 0, col: layout.cols.first ?? 0)
            rects = [GridRect(start, start)]
            active = start
            anchor = start
        }
        recomputeMatches()
        grid.reload()
        selectionChanged()
    }

    /// Shows a sheet at the zoom it was saved at in Excel.
    func adoptSavedZoom() {
        let z = CGFloat(sheet.zoomScale / 100)
        if abs(z - zoom) > 0.001 { setZoom(z) }
    }

    /// Re-measures after sizes changed but rows did not (resize, zoom).
    func relayout() {
        rebuildLayout()
        grid.reload()
    }

    /// Sheets with a tab right now.
    var tabSheets: [Int] { workbook.sheets.indices.filter { showHiddenSheets || !workbook.sheets[$0].isHidden } }
    var hiddenSheetCount: Int { workbook.sheets.filter(\.isHidden).count }

    func setShowHiddenSheets(_ on: Bool) {
        showHiddenSheets = on
        if !on, sheet.isHidden, let first = tabSheets.first { switchSheet(first) }
    }

    func switchSheet(_ i: Int) {
        guard workbook.sheets.indices.contains(i), i != sheetIndex else { return }
        if workbook.sheets[i].isHidden { showHiddenSheets = true }
        endEditing(commit: true)
        sheetIndex = i
        reloadSheet(resetSelection: true)
        adoptSavedZoom()
        grid.scrollOrigin(to: .zero)
    }

    var hiddenCount: (rows: Int, cols: Int) { (query.hiddenRows.count, query.hiddenColumns.count) }
    var isFiltered: Bool { !query.filters.isEmpty || query.sortColumn != nil }

    static func color(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    var isDark: Bool { grid.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    static func isNeutralLight(_ c: RGBA) -> Bool {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        return luminance(c) > 0.8 && Int(mx) - Int(mn) < 24
    }

    static func luminance(_ c: RGBA) -> Double {
        (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
    }

    // MARK: Renderer

    func cleanup() {
        workbookTask?.cancel()
        history.removeAllActions()
        editor?.removeFromSuperview()
        editor = nil
        host?.window?.isDocumentEdited = false
        popover?.close()
        cellTextPanel?.close()
        original?.close()
        original = nil
        grid.owner = nil
        doc = SpreadsheetDocument(workbook: Workbook(sheets: [], source: ""))
    }

    var hasUnsavedChanges: Bool { dirty }
    func saveChanges(completion: @escaping (Bool) -> Void) { save(completion: completion) }

    var presentation: StagePresentation { .sheet }
    var wantsArrowKeys: Bool { true }
    var initialFirstResponder: NSView? { viewMode == 1 ? original?.focusView : grid }
    var controls: AnyView? { AnyView(SheetStripControls(r: self)) }
    var controlsPlacement: ControlsPlacement { .strip }

    func supports(_ c: ViewerCommand) -> Bool {
        switch c {
        case .find, .findNext, .findPrevious, .copy, .toggleSource: return true
        case .saveAs, .exportCSV, .exportXLSX: return workbookLoaded
        case .zoomIn, .zoomOut, .actualSize: return true
        case .save: return dirty
        default: return false
        }
    }

    func perform(_ c: ViewerCommand) {
        switch c {
        case .toggleSource: viewMode = viewMode == 0 ? 1 : 0
        case .save: save()
        case .saveAs: saveAs()
        case .exportCSV: export(asCSV: true)
        case .exportXLSX: export(asCSV: false)
        case .find: viewMode = 0; focusSearch = true
        case .findNext: if matchList.isEmpty { runSearch() } else { findNext(1) }
        case .findPrevious: findNext(-1)
        case .zoomIn: stepZoom(1)
        case .zoomOut: stepZoom(-1)
        case .actualSize: if viewMode == 1 { originalZoom = 1; host?.rendererDidUpdate() } else { setZoom(sheet.zoomScale / 100) }
        default: break
        }
    }

    @Published var focusSearch = false

    var statusText: String {
        if viewMode == 1 {
            return "原样（只读）" + (abs(originalZoom - 1) > 0.001 ? " · 缩放 \(Int((originalZoom * 100).rounded()))%" : "") + (dirty ? " · ● 已修改（⌘S 保存）" : "")
        }
        guard workbookLoaded else { return workbookTask != nil ? "正在读取表格…" : "" }
        let total = max(0, sheet.rows.count - query.firstDataRow)
        let shownData = visible.count - query.pinnedRows.filter { !query.hiddenRows.contains($0) }.count
        var parts: [String] = []
        parts.append(shownData == total ? "\(Fmt.number(total)) 行 × \(sheet.columnCount) 列" : "显示 \(Fmt.number(shownData)) / \(Fmt.number(total)) 行")
        if abs(zoom - 1) > 0.001 { parts.append("缩放 \(Int((zoom * 100).rounded()))%") }
        if dirty { parts.append("● 已修改（⌘S 保存）") }
        if stats.cells > 1 {
            parts.append("已选 \(Fmt.number(stats.cells)) 格")
            if stats.numeric > 0 {
                parts.append("求和 \(fmt(stats.sum))")
                parts.append("平均 \(fmt(stats.average ?? 0))")
                parts.append("计数 \(Fmt.number(stats.numeric))")
                parts.append("最小 \(fmt(stats.min ?? 0)) · 最大 \(fmt(stats.max ?? 0))")
            } else {
                parts.append("非空 \(Fmt.number(stats.nonEmpty))")
            }
        }
        return parts.joined(separator: " · ")
    }

    var infoSections: [InfoSection] {
        guard workbookLoaded else {
            return [
                InfoSection(
                    "表格",
                    [
                        InfoItem("显示方式", "原样（系统快速查看）"),
                        InfoItem("说明", "切换到「表格工具」后读取工作表，可筛选、计算和编辑"),
                    ])
            ]
        }
        var items = [
            InfoItem("来源", workbook.source + (converted.map { " · \($0)" } ?? "")),
            InfoItem("工作表", workbook.sheets.map(\.name).joined(separator: "、")),
            InfoItem("当前表", "\(sheet.name) · \(Fmt.number(sheet.rows.count)) 行 × \(sheet.columnCount) 列"),
        ]
        if !sheet.formulas.isEmpty { items.append(InfoItem("公式单元格", Fmt.number(sheet.formulas.count))) }
        if !sheet.merges.isEmpty { items.append(InfoItem("合并单元格", Fmt.number(sheet.merges.count))) }
        if !sheet.conditionalFormats.isEmpty { items.append(InfoItem("条件格式", "\(Fmt.number(sheet.conditionalFormats.count)) 条（数据条 / 色阶）")) }
        items.append(InfoItem("说明", "筛选、排序、隐藏只影响显示；编辑后 ⌘S 才会写回原文件"))
        return [InfoSection("表格", items)]
    }
}

/// Bridges closures to NSMenuItem target/action.
final class MenuAction: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}

extension FValue {
    var isErrorValue: Bool { if case .error = self { return true }; return false }
}
