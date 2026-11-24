import SwiftUI

/// Observable header state for `ArchiveRenderer`, decoupled from the renderer view tree so
/// `RendererHostingView.detach()` cleanly drops references when the tab closes.
@MainActor
final class ArchiveHeaderModel: ObservableObject {
    let title: String
    let detail: String
    let note: String?
    @Published var selectedCount = 0
    @Published var canPreviewSelected = false
    @Published var busyLabel: String?

    var onExtractHere: (() -> Void)?
    var onExtractTo: (() -> Void)?
    var onExtractSelected: (() -> Void)?
    var onPreviewSelected: (() -> Void)?
    var onCancel: (() -> Void)?

    init(title: String, detail: String, note: String?) {
        self.title = title
        self.detail = detail
        self.note = note
    }

    func detach() {
        onExtractHere = nil
        onExtractTo = nil
        onExtractSelected = nil
        onPreviewSelected = nil
        onCancel = nil
    }
}

struct ArchiveHeaderView: View {
    @ObservedObject var model: ArchiveHeaderModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(model.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if let note = model.note {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.ember).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let busy = model.busyLabel {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Button("取消") { model.onCancel?() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    if model.canPreviewSelected {
                        Button("预览") { model.onPreviewSelected?() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("在新标签页中临时预览选中文件（不修改原文件夹）")
                    }
                    if model.selectedCount > 0 {
                        Button("解压选中（\(model.selectedCount)）") { model.onExtractSelected?() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button("解压到当前") { model.onExtractHere?() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("解压到压缩包所在文件夹（零散文件会自动建目录）")
                    Button("解压到…") { model.onExtractTo?() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5)
        }
    }
}
