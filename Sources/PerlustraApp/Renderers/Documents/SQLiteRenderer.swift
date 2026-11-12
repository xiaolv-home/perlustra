import AppKit
import SwiftUI
import PerlustraCore

/// 左侧表列表：名称 / 行数 / 列数，选中即预览。视图、虚拟表在名字后面标出来，读不出结构的标 ⚠︎。
private final class SQLiteTableList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private let scroll = NSScrollView()
    private var tables: [SQLiteTable] = []
    /// 行数在后台数，数完之前显示「…」。
    private var counts: [String: Int64] = [:]
    private var counting = false
    var onSelect: ((Int) -> Void)?

    override init() {
        super.init()
        let specs: [(String, String, CGFloat, NSTextAlignment)] = [
            ("n", "名称", 150, .left), ("r", "行数", 76, .right), ("c", "列数", 44, .right),
        ]
        for (id, title, width, align) in specs {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            col.minWidth = id == "n" ? 80 : 36
            col.resizingMask = id == "n" ? .autoresizingMask : .userResizingMask
            col.headerCell.font = .systemFont(ofSize: 10.5, weight: .semibold)
            col.headerCell.alignment = align
            table.addTableColumn(col)
        }
        // 名称一栏吃掉剩下的宽度，行数、列数始终露在外面。
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .plain
        table.rowHeight = 24
        table.backgroundColor = Theme.sheet
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = Theme.sheet
        scroll.borderType = .noBorder
    }

    var view: NSView { scroll }

    func setTables(_ t: [SQLiteTable], counting: Bool) {
        tables = t
        self.counting = counting
        table.reloadData()
        table.sizeToFit()
        if !t.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func setCounts(_ c: [String: Int64]) {
        counts = c
        counting = false
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tables.count), columnIndexes: IndexSet(integer: 1))
    }

    func rowCount(of name: String) -> Int64? { counts[name] }

    func detach() { table.dataSource = nil; table.delegate = nil }

    func numberOfRows(in _: NSTableView) -> Int { tables.count }

    func tableViewSelectionDidChange(_: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < tables.count else { return }
        onSelect?(row)
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < tables.count, let id = col?.identifier.rawValue else { return nil }
        let t = tables[row]
        let field =
            (tv.makeView(withIdentifier: .init(id), owner: nil) as? NSTextField)
            ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = .init(id)
                f.lineBreakMode = .byTruncatingMiddle
                return f
            }()
        field.toolTip = nil
        switch id {
        case "n":
            // 中文没有斜体，视图 / 虚拟表在名字后面写一个小标签。
            let s = NSMutableAttributedString(
                string: (t.problem != nil ? "⚠︎ " : "") + t.name,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: t.problem != nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
                ])
            if let tag = t.isView ? "视图" : t.isVirtual ? "虚拟表" : nil {
                s.append(
                    NSAttributedString(
                        string: "  " + tag, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            field.attributedStringValue = s
            field.alignment = .left
            field.toolTip = t.problem.map { "\(t.name)：\($0)" } ?? t.name
        case "r":
            field.textColor = .secondaryLabelColor
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .right
            if let n = counts[t.name] {
                field.stringValue = Fmt.number(Int(n))
            } else {
                field.stringValue = t.isView || t.problem != nil || !counting ? "—" : "…"
                if t.isView { field.toolTip = "视图的行数要把它整个算一遍才知道，所以不统计" }
            }
        default:
            field.textColor = .secondaryLabelColor
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .right
            field.stringValue = t.problem == nil ? Fmt.number(t.columns.count) : "—"
        }
        return field
    }
}

/// 数据表格：⌘C 把选中的行按制表符分隔拷出去（第一行是列名），能直接贴进表格。
private final class SQLiteGrid: NSTableView {
    var copyText: (() -> String?)?

    @objc func copy(_ sender: Any?) {
        guard let s = copyText?(), !s.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

/// 右侧数据预览：列随表结构变化，只读，显示前 N 行。
private final class SQLiteDataView: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let grid = SQLiteGrid()
    private let scroll = NSScrollView()
    private var sample: SQLiteSample?

    var table: NSTableView { grid }

    override init() {
        super.init()
        grid.style = .plain
        grid.rowHeight = 22
        grid.backgroundColor = Theme.sheet
        grid.dataSource = self
        grid.delegate = self
        grid.allowsMultipleSelection = true
        grid.usesAlternatingRowBackgroundColors = false
        grid.gridStyleMask = [.solidVerticalGridLineMask]
        grid.gridColor = Theme.hairline
        grid.columnAutoresizingStyle = .noColumnAutoresizing
        grid.copyText = { [weak self] in self?.selectedText() }
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = Theme.sheet
        scroll.borderType = .noBorder
    }

    var view: NSView { scroll }

    /// `columns` 是表结构，用来在列头悬停时说明类型、主键、非空。
    func setSample(_ s: SQLiteSample?, columns: [SQLiteColumn] = []) {
        sample = s
        for c in grid.tableColumns { grid.removeTableColumn(c) }
        let info = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for (i, name) in (s?.columns ?? []).enumerated() {
            let col = NSTableColumn(identifier: .init("c\(i)"))
            col.title = name
            col.width = Self.width(for: name, rows: s?.rows ?? [], index: i)
            col.minWidth = 48
            col.headerCell.font = .systemFont(ofSize: 10.5, weight: .semibold)
            if let c = info[name] {
                var parts = [c.declaredType.isEmpty ? "无类型" : c.declaredType]
                if c.primaryKey { parts.append("主键") }
                if c.notNull { parts.append("非空") }
                col.headerToolTip = "\(name)：" + parts.joined(separator: " · ")
            }
            grid.addTableColumn(col)
        }
        grid.reloadData()
        grid.scrollRowToVisible(0)
    }

    /// 按列名和前几十行内容估一个宽度，上限 320。
    private static func width(for name: String, rows: [[SQLiteCell]], index: Int) -> CGFloat {
        func w(_ s: String) -> CGFloat { s.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 12 : 7) } }
        var widest = w(name) + 20
        for r in rows.prefix(50) where index < r.count {
            widest = max(widest, w(display(r[index])))
        }
        return min(320, max(64, widest + 20))
    }

    static func display(_ c: SQLiteCell) -> String {
        if case .blob(let n) = c { return "‹二进制 \(Fmt.bytes(Int64(n)))›" }
        return c.text
    }

    private func selectedText() -> String? {
        guard let s = sample, !grid.selectedRowIndexes.isEmpty else { return nil }
        func clean(_ t: String) -> String { t.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var lines = [s.columns.map(clean).joined(separator: "\t")]
        for r in grid.selectedRowIndexes where r < s.rows.count {
            lines.append(s.rows[r].map { $0.isNull ? "" : clean(Self.display($0)) }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    func detach() { grid.dataSource = nil; grid.delegate = nil; grid.copyText = nil }

    func numberOfRows(in _: NSTableView) -> Int { sample?.rows.count ?? 0 }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let s = sample, row < s.rows.count, let id = col?.identifier.rawValue,
            let idx = Int(id.dropFirst()), idx < s.rows[row].count
        else { return nil }
        let cell = s.rows[row][idx]
        let field =
            (tv.makeView(withIdentifier: .init(id), owner: nil) as? NSTextField)
            ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = .init(id)
                f.lineBreakMode = .byTruncatingTail
                return f
            }()
        let text = Self.display(cell)
        field.stringValue = text
        // 长内容悬停看全文。
        field.toolTip = text.count > 24 ? String(text.prefix(2000)) : nil
        switch cell {
        case .null:
            field.textColor = .tertiaryLabelColor
            field.font = .systemFont(ofSize: 11)
            field.alignment = .left
        case .text:
            field.textColor = .labelColor
            field.font = .systemFont(ofSize: 11)
            field.alignment = .left
        case .integer, .real:
            field.textColor = .labelColor
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .right
        case .blob:
            field.textColor = .secondaryLabelColor
            field.font = .systemFont(ofSize: 11)
            field.alignment = .left
        }
        return field
    }
}

private struct SQLiteHeader: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
    }
}

/// 只读浏览 SQLite 数据库：左侧列出所有表和视图，选中后在右侧看前 200 行。
/// 打开时只读表结构；行数在后台数，切走或关掉标签页时，正在跑的查询会被中断。
@MainActor
final class SQLiteRenderer: NSObject, Renderer {
    static let engineName = "SQLite"
    static let sampleLimit = 200
    static func canHandle(_ file: FileContext) -> Bool { !file.isDirectory }

    private var database: SQLiteDatabase?
    private var fileURL: URL?
    private let list = SQLiteTableList()
    private let data = SQLiteDataView()
    private var dataHeader: NSTextField?
    private weak var host: RenderHost?
    private var sampleTask: Task<Void, Never>?
    private var sampleCancel: SQLiteCancellation?
    private var countTask: Task<Void, Never>?
    private let countCancel = SQLiteCancellation()
    private var selectedIndex: Int?

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        fileURL = file.url
        let url = file.url
        let name = file.name
        host.reportProgress(nil, label: "正在读取数据库…")
        let cancel = SQLiteCancellation()
        let db: SQLiteDatabase
        do {
            db = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try SQLiteReader.readDatabase(url: url, cancel: cancel)
                }.value
            } onCancel: {
                cancel.cancel()
            }
        } catch is CancellationError {
            throw RenderError.cancelled
        } catch SQLiteError.cancelled {
            throw RenderError.cancelled
        } catch {
            throw RenderError.unreadable((error as? LocalizedError)?.errorDescription ?? "无法读取数据库")
        }
        try Task.checkCancellation()
        host.reportProgress(nil, label: nil)
        database = db
        if db.snapshot {
            host.showNotice("这个数据库缺少 -shm 文件，已按快照只读打开；还留在 -wal 里没合并的改动不会显示。", style: .info, action: nil)
        }
        let view = buildView(db: db, name: name)
        countRows(db)
        return view
    }

    private func buildView(db: SQLiteDatabase, name: String) -> NSView {
        let tableCount = db.tables.filter { !$0.isView }.count
        let viewCount = db.tables.count - tableCount
        var detail = "\(Fmt.number(tableCount)) 张表"
        if viewCount > 0 { detail += " · \(Fmt.number(viewCount)) 个视图" }
        detail += " · SQLite \(db.version) · 只读"

        let header = NSHostingView(rootView: SQLiteHeader(title: name, detail: detail))
        header.sizingOptions = [.intrinsicContentSize]

        let label = NSTextField(labelWithString: db.tables.isEmpty ? "这个数据库里没有表" : "选中一张表查看数据")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        dataHeader = label

        let rightBox = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        let dataView = data.view
        dataView.translatesAutoresizingMaskIntoConstraints = false
        rightBox.addSubview(label)
        rightBox.addSubview(dataView)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: rightBox.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: rightBox.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: rightBox.topAnchor, constant: 15),
            dataView.leadingAnchor.constraint(equalTo: rightBox.leadingAnchor),
            dataView.trailingAnchor.constraint(equalTo: rightBox.trailingAnchor),
            dataView.topAnchor.constraint(equalTo: rightBox.topAnchor, constant: 30),
            dataView.bottomAnchor.constraint(equalTo: rightBox.bottomAnchor),
        ])

        let listView = list.view
        let divider = NSBox()
        divider.boxType = .separator

        let container = NSView()
        for v in [header, listView, divider, rightBox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            listView.topAnchor.constraint(equalTo: header.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            listView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            listView.widthAnchor.constraint(equalToConstant: 300),
            divider.leadingAnchor.constraint(equalTo: listView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: listView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: listView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            rightBox.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightBox.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightBox.topAnchor.constraint(equalTo: header.bottomAnchor),
            rightBox.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        list.onSelect = { [weak self] i in self?.selectTable(at: i) }
        list.setTables(db.tables, counting: db.tables.contains { !$0.isView && $0.problem == nil })
        return container
    }

    /// 普通表在后台逐个数行数，数完一次刷新；视图不数。
    private func countRows(_ db: SQLiteDatabase) {
        guard let url = fileURL else { return }
        let names = db.tables.filter { !$0.isView && $0.problem == nil }.map(\.name)
        guard !names.isEmpty else { return }
        let cancel = countCancel
        countTask = Task { [weak self] in
            let counts = try? await Task.detached(priority: .utility) {
                try SQLiteReader.countRows(url: url, tables: names, cancel: cancel)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.list.setCounts(counts ?? [:])
            if let i = self.selectedIndex { self.updateHeader(at: i, shown: nil) }
            self.host?.rendererDidUpdate()
        }
    }

    private func selectTable(at index: Int) {
        guard let db = database, db.tables.indices.contains(index) else { return }
        selectedIndex = index
        let t = db.tables[index]
        if let problem = t.problem {
            sampleCancel?.cancel()
            sampleTask?.cancel()
            data.setSample(nil)
            dataHeader?.stringValue = "\(t.name) 读不出来：\(problem)"
            return
        }
        loadSample(t, index: index)
    }

    /// 表头一行：共几行、显示了几行。视图没有总行数。
    private func updateHeader(at index: Int, shown: Int?) {
        guard let db = database, db.tables.indices.contains(index), db.tables[index].problem == nil else { return }
        let t = db.tables[index]
        let n = shown ?? data.table.numberOfRows
        var text = t.name
        if let total = list.rowCount(of: t.name) {
            text += " · 共 \(Fmt.number(Int(total))) 行"
            if Int64(n) < total { text += " · 显示前 \(Fmt.number(n)) 行" }
        } else {
            if t.isView { text += " · 视图" }
            text += " · 显示前 \(Fmt.number(n)) 行"
        }
        if n > 0 { text += " · 选中行按 ⌘C 拷贝" }
        dataHeader?.stringValue = text
    }

    private func loadSample(_ t: SQLiteTable, index: Int) {
        sampleCancel?.cancel()
        sampleTask?.cancel()
        guard let url = fileURL else { return }
        let limit = Self.sampleLimit
        let name = t.name
        let cancel = SQLiteCancellation()
        sampleCancel = cancel
        dataHeader?.stringValue = "正在读取 \(name) …"
        sampleTask = Task { [weak self] in
            do {
                let s = try await Task.detached(priority: .userInitiated) {
                    try SQLiteReader.sample(url: url, table: name, limit: limit, cancel: cancel)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.data.setSample(s, columns: t.columns)
                self.updateHeader(at: index, shown: s.rows.count)
                self.host?.rendererDidUpdate()
            } catch {
                guard let self, !Task.isCancelled, !cancel.isCancelled else { return }
                self.data.setSample(nil)
                let why = (error as? LocalizedError)?.errorDescription ?? "读取失败"
                self.dataHeader?.stringValue = "\(name) · \(why)"
            }
        }
    }

    func cleanup() {
        sampleCancel?.cancel()
        sampleTask?.cancel()
        sampleTask = nil
        countCancel.cancel()
        countTask?.cancel()
        countTask = nil
        list.detach()
        data.detach()
        database = nil
        fileURL = nil
    }

    var statusText: String {
        guard let db = database else { return "" }
        let tables = db.tables.filter { !$0.isView }.count
        let views = db.tables.count - tables
        return "\(Fmt.number(tables)) 张表" + (views > 0 ? " · \(Fmt.number(views)) 个视图" : "")
    }

    var infoSections: [InfoSection] {
        guard let db = database else { return [] }
        let tables = db.tables.filter { !$0.isView }
        let views = db.tables.count - tables.count
        var items = [InfoItem("表", Fmt.number(tables.count))]
        if views > 0 { items.append(InfoItem("视图", Fmt.number(views))) }
        let broken = db.tables.filter { $0.problem != nil }.count
        if broken > 0 { items.append(InfoItem("读不出结构", Fmt.number(broken))) }
        items.append(InfoItem("SQLite 版本", db.version))
        if db.snapshot { items.append(InfoItem("打开方式", "快照（缺少 -shm 文件，-wal 里未合并的改动不显示）")) }
        items.append(InfoItem("说明", "只读，不会修改文件；数据预览显示每张表前 \(Fmt.number(Self.sampleLimit)) 行"))
        return [InfoSection("数据库", items)]
    }

    var initialFirstResponder: NSView? { list.table }
}
