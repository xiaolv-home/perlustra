import AppKit
import SwiftUI
import PerlustraCore

/// Last-resort renderer: file summary plus a virtualised hex dump (memory-mapped, any size).
@MainActor
final class HexRenderer: NSObject, Renderer, NSTableViewDataSource, NSTableViewDelegate {
    func fallbackNote(for file: FileContext?, reason: String) -> FallbackNote {
        if file?.format.family == .parquet, !reason.isEmpty {
            return FallbackNote(message: reason + "；现在显示的是文件的原始数据", showsRawContent: true)
        }
        return FallbackNote(message: "这个\(file?.format.label ?? "文件")打不开（文件可能已损坏或不完整），现在显示的是它的原始数据", showsRawContent: true)
    }

    static let engineName = "Hex"
    static func canHandle(_ file: FileContext) -> Bool { !file.isDirectory }

    private var data = Data()
    private var table: NSTableView?
    private var file: FileContext?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.file = file
        let url = file.url
        let d: Data
        do {
            d = try await Task.detached { try Data(contentsOf: url, options: [.alwaysMapped]) }.value
        } catch {
            throw RenderError.unreadable("无法读取文件（\(error.localizedDescription)）")
        }
        data = d

        let container = NSView()
        let header = NSHostingView(rootView: HexHeader(file: file))
        header.sizingOptions = [.intrinsicContentSize]
        header.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 14, height: 0)
        table.gridStyleMask = []
        table.backgroundColor = Theme.codeBackground
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.style = .plain
        for (id, title, width) in [("off", "偏移", 76.0), ("hex", "十六进制", 420.0), ("asc", "ASCII", 150.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = width * 0.6
            c.headerCell.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.codeBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func cleanup() {
        table?.dataSource = nil
        table?.delegate = nil
        table = nil
        data = Data()
    }

    var statusText: String { "\(Fmt.number((data.count + 15) / 16)) 行 · 十六进制" }
    var infoSections: [InfoSection] {
        let magic = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        return [
            InfoSection(
                "内容",
                [
                    InfoItem("文件头", magic.isEmpty ? "（空）" : magic),
                    InfoItem("字节数", Fmt.exactBytes(Int64(data.count))),
                ])
        ]
    }
    var initialFirstResponder: NSView? { table }
    func supports(_ command: ViewerCommand) -> Bool { command == .copy }

    func numberOfRows(in tableView: NSTableView) -> Int { (data.count + 15) / 16 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("hex")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField)
            ?? {
                let t = NSTextField(labelWithString: "")
                t.identifier = id
                t.font = font
                t.lineBreakMode = .byClipping
                return t
            }()
        let r = HexDump.row(data, offset: row * 16)
        switch id.rawValue {
        case "off": cell.stringValue = r.offset; cell.textColor = Theme.gutterText
        case "asc": cell.stringValue = r.ascii; cell.textColor = Theme.syntax(.string)
        default: cell.stringValue = r.hex; cell.textColor = .labelColor
        }
        return cell
    }

    @objc func copy(_ sender: Any?) {
        guard let t = table else { return }
        let lines = t.selectedRowIndexes.map { i -> String in
            let r = HexDump.row(data, offset: i * 16)
            return "\(r.offset)  \(r.hex) |\(r.ascii)|"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private struct HexHeader: View {
    let file: FileContext
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(file.format.label).font(.system(size: 13, weight: .semibold))
                    if let t = file.utType, t.localizedDescription != nil, file.format.family == .binary {
                        Text(t.localizedDescription ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text("没有可用的专用预览，以十六进制显示原始内容。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("用默认应用打开") { NSWorkspace.shared.open(file.url) }
                .controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(nsColor: Theme.surface))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
    }
}
