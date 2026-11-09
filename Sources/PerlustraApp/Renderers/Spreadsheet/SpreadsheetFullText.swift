import AppKit
import PerlustraCore
import SwiftUI

/// Reading a cell whose text does not fit: a tooltip when the pointer rests on it, and a panel
/// with the whole text (double-click, Space, the context menu, or the value box above the grid).
extension SpreadsheetRenderer {
    /// What the cell holds, as shown. View row, sheet column.
    func fullText(row: Int, col: Int) -> String? {
        guard row >= 0, row < visible.count else { return nil }
        let text = sheet.cell(visible[row], col).display
        return text.isEmpty ? nil : text
    }

    /// The cell's text if it is cut off where it is drawn, for the tooltip.
    func gridHoverText(_ p: GridPoint) -> String? {
        let anchor = mergeArea(row: p.row, col: p.col)?.topLeft ?? p
        guard let text = fullText(row: anchor.row, col: anchor.col) else { return nil }
        let area = mergeArea(row: p.row, col: p.col).flatMap { layout.rect($0.area) } ?? layout.rect(row: anchor.row, col: anchor.col)
        guard let area else { return nil }
        let value = sheet.cell(visible[anchor.row], anchor.col)
        let look = look(visible[anchor.row], anchor.col, value: value, colorOverride: nil)
        if text.contains("\n") && !look.wraps { return text }
        if look.wraps { return nil }
        let needed = (text as NSString).size(withAttributes: [.font: look.font]).width + 2 * SheetMetrics.padX * zoom
        return needed > area.width ? String(text.prefix(4000)) : nil
    }

    /// Opens the whole text of a cell beside it.
    func gridShowFullText(_ p: GridPoint) {
        let anchor = mergeArea(row: p.row, col: p.col)?.topLeft ?? p
        guard let text = fullText(row: anchor.row, col: anchor.col) else { return }
        grid.scrollTo(row: anchor.row, col: anchor.col)
        guard let (host, rect) = grid.editorHost(row: anchor.row, col: anchor.col) else { return }
        let caption = query.headerRowIndex.flatMap { h in h == visible[anchor.row] ? nil : sheet.cell(h, anchor.col).display } ?? ""
        let address = Sheet.columnName(anchor.col) + "\(visible[anchor.row] + 1)"
        let title = caption.isEmpty ? address : "\(address) · \(caption)"
        let panel = NSPopover()
        panel.behavior = .transient
        panel.animates = false
        let width: CGFloat = 460
        // Measured the way the panel lays it out (its width less the scroller, same line spacing).
        let spacing = NSMutableParagraphStyle()
        spacing.lineSpacing = 3
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: width - 32 - 16, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: spacing]
        ).height
        let height = min(380, ceil(measured) + 12)
        panel.contentViewController = NSHostingController(
            rootView: CellTextPanel(title: title, text: text, textHeight: height) { [weak panel] in panel?.close() })
        panel.contentSize = NSSize(width: width, height: height + 64)
        cellTextPanel?.close()
        cellTextPanel = panel
        panel.show(relativeTo: rect, of: host, preferredEdge: .maxY)
    }

    /// The value box above the grid opens the active cell's text.
    func showActiveCellText() { gridShowFullText(active) }
}

private struct CellTextPanel: View {
    let title: String
    let text: String
    let textHeight: CGFloat
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(text.count) 字").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "已拷贝" : "拷贝") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: textHeight)
        }
        .padding(16)
        .onExitCommand(perform: close)
    }
}
