import AppKit
import SwiftUI

private struct TreeHeader: View {
    let title: String
    let detail: String
    let note: String?
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.ember) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
    }
}

/// Folders (and non-document packages) are shown as a browsable tree; double-click opens a file.
@MainActor
final class DirectoryRenderer: Renderer {
    static let engineName = "Folder"
    static func canHandle(_ file: FileContext) -> Bool { file.isDirectory }

    private var tree: FileTreeView?
    private var count = 0

    required init() {}

    nonisolated static func children(of url: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.map { u in
            let rv = try? u.resourceValues(forKeys: Set(keys))
            let dir = (rv?.isDirectory ?? false) && !(rv?.isPackage ?? false)
            return FileNode(
                name: u.lastPathComponent, isDirectory: dir, size: rv?.fileSize.map(Int64.init), modified: rv?.contentModificationDate,
                loader: dir ? { DirectoryRenderer.children(of: u) } : nil)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        let url = file.url
        let kids = await Task.detached { DirectoryRenderer.children(of: url) }.value
        count = kids.count
        let root = FileNode(name: url.lastPathComponent, isDirectory: true, loader: { kids })
        let t = FileTreeView(root: root)
        t.onOpen = { [weak host] n in
            var parts = [n.name]
            var item: Any? = t.outline.parent(forItem: n)
            while let p = item as? FileNode { parts.insert(p.name, at: 0); item = t.outline.parent(forItem: p) }
            host?.open(parts.reduce(url) { $0.appendingPathComponent($1) })
        }
        tree = t
        let header = NSHostingView(rootView: TreeHeader(title: url.lastPathComponent, detail: "\(count) 项 · 双击文件即可查看", note: nil))
        header.sizingOptions = [.intrinsicContentSize]
        return stackTreeView(header: header, body: t)
    }

    func cleanup() { tree?.detach(); tree = nil }
    var statusText: String { "\(count) 项" }
    var initialFirstResponder: NSView? { tree?.outline }
}
