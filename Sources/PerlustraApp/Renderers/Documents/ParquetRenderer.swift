import AppKit
import SwiftUI
import PerlustraCore

private struct ParquetHeader: View {
    let title: String
    let detail: String
    let note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
    }
}

private final class ParquetGrid: NSTableView {
    var copyText: (() -> String?)?

    @objc func copy(_ sender: Any?) {
        guard let text = copyText?(), !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

/// Native, read-only table. Schema and a bounded sample are loaded away from the main thread.
@MainActor
final class ParquetRenderer: NSObject, Renderer, NSTableViewDataSource, NSTableViewDelegate {
    static let engineName = "Parquet"
    static func canHandle(_ file: FileContext) -> Bool { file.format.family == .parquet && !file.isDirectory }

    private var preview: ParquetPreview?
    private var grid: ParquetGrid?
    private let cancellation = ParquetCancellation()

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        host.reportProgress(nil, label: "正在读取 Parquet…")
        let url = file.url
        let token = cancellation
        let loaded: ParquetPreview
        do {
            loaded = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ParquetReader.read(url: url, cancel: token)
                }.value
            } onCancel: {
                token.cancel()
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw RenderError.cancelled
        } catch ParquetError.cancelled {
            throw RenderError.cancelled
        } catch {
            throw RenderError.unreadable(error.localizedDescription)
        }
        preview = loaded
        host.reportProgress(nil, label: nil)

        let table = ParquetGrid()
        table.style = .plain
        table.rowHeight = 24
        table.backgroundColor = Theme.sheet
        table.gridColor = Theme.hairline
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        for (i, column) in loaded.columns.enumerated() {
            let c = NSTableColumn(identifier: .init("c\(i)"))
            c.title = column.name
            c.headerToolTip = "\(column.name)：\(column.type)"
            c.headerCell.font = .systemFont(ofSize: 10.5, weight: .semibold)
            c.headerCell.alignment = column.isNumeric ? .right : .left
            c.minWidth = 60
            c.width = Self.width(for: column.name, values: loaded.rows.prefix(40).map { $0[i] ?? "NULL" })
            table.addTableColumn(c)
        }
        table.copyText = { [weak self, weak table] in
            guard let self, let table, !table.selectedRowIndexes.isEmpty else { return nil }
            return self.preview?.copyRows(table.selectedRowIndexes)
        }
        grid = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = Theme.sheet
        scroll.borderType = .noBorder

        var note = loaded.rows.isEmpty ? "这是一个空数据表；字段结构保留在列头" : "显示前 \(Fmt.number(loaded.rows.count)) 行 · 选中行按 ⌘C 拷贝 · 列头悬停看类型"
        if loaded.columns.count < loaded.columnCount { note += " · 仅预览前 \(loaded.columns.count) 列" }
        if loaded.truncatedCells { note += " · 超长内容已截断（复制也取截断后的内容）" }
        let header = NSHostingView(rootView: ParquetHeader(title: file.name, detail: statusText, note: note))
        header.sizingOptions = [.intrinsicContentSize]
        let view = NSView()
        for child in [header, scroll] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    private static func width(for name: String, values: [String]) -> CGFloat {
        func length(_ s: String) -> CGFloat {
            s.unicodeScalars.prefix(60).reduce(CGFloat(0)) { $0 + ($1.value > 0x2E80 ? 12 : 7) }
        }
        return min(320, max(80, ([name] + values).map(length).max()! + 24))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { preview?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let p = preview, p.rows.indices.contains(row), let id = tableColumn?.identifier,
            let index = Int(id.rawValue.dropFirst()), p.columns.indices.contains(index)
        else { return nil }
        let label = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? NSTextField(labelWithString: "")
        label.identifier = id
        label.lineBreakMode = .byTruncatingTail
        let value = p.rows[row][index]
        label.stringValue = value ?? "NULL"
        label.toolTip = value
        label.textColor = value == nil ? .tertiaryLabelColor : .labelColor
        label.font = p.columns[index].isNumeric ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        label.alignment = p.columns[index].isNumeric ? .right : .left
        return label
    }

    func cleanup() {
        cancellation.cancel()
        grid?.dataSource = nil
        grid?.delegate = nil
        grid?.copyText = nil
        grid = nil
        preview = nil
    }

    var wantsArrowKeys: Bool { true }
    var initialFirstResponder: NSView? { grid }
    var statusText: String {
        guard let p = preview else { return "" }
        return "\(Fmt.number(Int(p.rowCount))) 行 · \(Fmt.number(p.columnCount)) 列 · Parquet · 只读"
    }
    var infoSections: [InfoSection] {
        guard let p = preview else { return [] }
        return [
            InfoSection(
                "数据表",
                [
                    InfoItem("总行数", Fmt.number(Int(p.rowCount))),
                    InfoItem("字段数", Fmt.number(p.columnCount)),
                    InfoItem("行组数", Fmt.number(Int(p.rowGroups))),
                    InfoItem("预览", "前 \(p.rows.count) 行、\(p.columns.count) 列"),
                    InfoItem("说明", "只读；不修改文件，不访问网络"),
                ])
        ]
    }
}
