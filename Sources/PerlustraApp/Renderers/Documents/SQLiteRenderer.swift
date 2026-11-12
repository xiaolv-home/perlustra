import AppKit
import SwiftUI
import PerlustraCore

/// 左侧表列表：名称 / 行数 / 列数，选中即预览。视图用斜体区分。
private final class SQLiteTableList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private let scroll = NSScrollView()
    private var tables: [SQLiteTable] = []
    var onSelect: ((Int) -> Void)?

    override init() {
        super.init()
        let specs: [(String, String, CGFloat, NSTextAlignment)] = [
            ("n", "名称", 200, .left), ("r", "行数", 80, .right), ("c", "列数", 60, .right),
        ]
        for (id, title, width, align) in specs {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            col.minWidth = 40
            col.headerCell.font = .systemFont(ofSize: 10.5, weight: .semibold)
            col.headerCell.alignment = align
            table.addTableColumn(col)
        }
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

    func setTables(_ t: [SQLiteTable]) {
        tables = t
        table.reloadData()
        if !t.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

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
                f.isSelectable = true
                return f
            }()
        switch id {
        case "n":
            field.textColor = t.isView ? .secondaryLabelColor : .labelColor
            field.font =
                t.isView
                ? NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
                : .systemFont(ofSize: 12)
            field.alignment = .left
            field.stringValue = t.name
        case "r":
            field.textColor = .secondaryLabelColor
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .right
            field.stringValue = Fmt.number(Int(t.rowCount))
        default:
            field.textColor = .secondaryLabelColor
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .right
            field.stringValue = Fmt.number(t.columns.count)
        }
        return field
    }
}

/// 右侧数据预览：列随表结构变化，只读，显示前 N 行。
private final class SQLiteDataView: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private let scroll = NSScrollView()
    private var sample: SQLiteSample?

    override init() {
        super.init()
        table.style = .plain
        table.rowHeight = 22
        table.backgroundColor = Theme.sheet
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = Theme.sheet
        scroll.borderType = .noBorder
    }

    var view: NSView { scroll }

    func setSample(_ s: SQLiteSample?) {
        sample = s
        for c in table.tableColumns { table.removeTableColumn(c) }
        for (i, name) in (s?.columns ?? []).enumerated() {
            let col = NSTableColumn(identifier: .init("c\(i)"))
            col.title = name
            col.width = min(280, max(90, CGFloat(name.count) * 11 + 48))
            col.minWidth = 60
            col.headerCell.font = .systemFont(ofSize: 10.5, weight: .semibold)
            table.addTableColumn(col)
        }
        table.reloadData()
    }

    func detach() { table.dataSource = nil; table.delegate = nil }

    func numberOfRows(in _: NSTableView) -> Int { sample?.rows.count ?? 0 }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let s = sample, row < s.rows.count, let id = col?.identifier.rawValue,
            let idx = Int(id.dropFirst()), idx < s.columns.count
        else { return nil }
        let cell = s.rows[row][idx]
        let field =
            (tv.makeView(withIdentifier: .init(id), owner: nil) as? NSTextField)
            ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = .init(id)
                f.lineBreakMode = .byTruncatingTail
                f.isSelectable = true
                return f
            }()
        switch cell {
        case .null:
            field.stringValue = "NULL"
            field.textColor = .tertiaryLabelColor
            field.font = .systemFont(ofSize: 11)
            field.alignment = .left
        case .text(let t):
            field.stringValue = t
            field.textColor = .labelColor
            field.font = .systemFont(ofSize: 11)
            field.alignment = .left
        case .integer(let i):
            field.stringValue = String(i)
            field.textColor = .labelColor
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .right
        case .real(let d):
            field.stringValue = String(d)
            field.textColor = .labelColor
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .right
        case .blob(let n):
            field.stringValue = "‹二进制 \(Fmt.bytes(Int64(n)))›"
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

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        fileURL = file.url
        let url = file.url
        let name = file.name
        host.reportProgress(nil, label: "正在读取数据库…")
        let db: SQLiteDatabase
        do {
            db = try await Task.detached(priority: .userInitiated) {
                try SQLiteReader.readDatabase(url: url)
            }.value
        } catch is CancellationError {
            throw RenderError.cancelled
        } catch {
            throw RenderError.unreadable((error as? LocalizedError)?.errorDescription ?? "无法读取数据库")
        }
        try Task.checkCancellation()
        host.reportProgress(nil, label: nil)
        database = db
        return buildView(db: db, name: name)
    }

    private func buildView(db: SQLiteDatabase, name: String) -> NSView {
        let tableCount = db.tables.filter { !$0.isView }.count
        let viewCount = db.tables.count - tableCount
        var detail = "\(Fmt.number(tableCount)) 张表"
        if viewCount > 0 { detail += " · \(Fmt.number(viewCount)) 个视图" }
        detail += " · SQLite \(db.version)"

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
            label.topAnchor.constraint(equalTo: rightBox.topAnchor),
            label.heightAnchor.constraint(equalToConstant: 28),
            dataView.leadingAnchor.constraint(equalTo: rightBox.leadingAnchor),
            dataView.trailingAnchor.constraint(equalTo: rightBox.trailingAnchor),
            dataView.topAnchor.constraint(equalTo: label.bottomAnchor),
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
            listView.widthAnchor.constraint(equalToConstant: 320),
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
        list.setTables(db.tables)
        return container
    }

    private func selectTable(at index: Int) {
        guard let db = database, db.tables.indices.contains(index) else { return }
        loadSample(table: db.tables[index].name)
    }

    private func loadSample(table name: String) {
        sampleTask?.cancel()
        guard let url = fileURL else { return }
        let limit = Self.sampleLimit
        dataHeader?.stringValue = "正在读取 \(name) …"
        sampleTask = Task { [weak self] in
            guard let self else { return }
            do {
                let s = try await Task.detached(priority: .userInitiated) {
                    try SQLiteReader.sample(url: url, table: name, limit: limit)
                }.value
                guard !Task.isCancelled else { return }
                self.data.setSample(s)
                self.dataHeader?.stringValue =
                    "\(name) · 共 \(Fmt.number(Int(s.totalRows))) 行 · 显示前 \(Fmt.number(s.rows.count)) 行"
                self.host?.rendererDidUpdate()
            } catch {
                guard !Task.isCancelled else { return }
                self.data.setSample(nil)
                self.dataHeader?.stringValue = "\(name) · 读取失败"
            }
        }
    }

    func cleanup() {
        sampleTask?.cancel()
        sampleTask = nil
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
        items.append(InfoItem("SQLite 版本", db.version))
        items.append(InfoItem("说明", "只读，不会修改文件；数据预览显示每张表前 \(Fmt.number(Self.sampleLimit)) 行"))
        return [InfoSection("数据库", items)]
    }

    var initialFirstResponder: NSView? { list.table }
}
