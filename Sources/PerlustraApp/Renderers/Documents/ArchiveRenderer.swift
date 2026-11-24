import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PerlustraCore

/// Node in an archive or folder tree. Folder nodes may load their children lazily.
final class FileNode {
    let name: String
    let isDirectory: Bool
    /// Normalized path inside an archive (e.g. `docs/readme.md`), `nil` for live filesystem trees.
    var entryPath: String?
    var size: Int64?
    var modified: Date?
    var encrypted = false
    var isSymlink = false
    private var _children: [FileNode]?
    private var loader: (() -> [FileNode])?
    var childMap: [String: FileNode] = [:]

    init(
        name: String,
        isDirectory: Bool,
        entryPath: String? = nil,
        size: Int64? = nil,
        modified: Date? = nil,
        loader: (() -> [FileNode])? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.entryPath = entryPath
        self.size = size
        self.modified = modified
        self.loader = loader
        if isDirectory && loader == nil { _children = [] }
    }

    var children: [FileNode] {
        if let c = _children { return c }
        let c = loader?() ?? []
        _children = c
        loader = nil
        return c
    }

    func add(_ n: FileNode) {
        _children = (_children ?? []) + [n]
        childMap[n.name] = n
    }

    func sortRecursively() {
        guard var c = _children else { return }
        c.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        _children = c
        c.forEach { $0.sortRecursively() }
    }

    @discardableResult
    func totalSize() -> Int64 {
        guard isDirectory, let c = _children else { return size ?? 0 }
        let s = c.reduce(Int64(0)) { $0 + $1.totalSize() }
        size = s
        return s
    }

    static func tree(from entries: [ArchiveEntry]) -> FileNode {
        let root = FileNode(name: "/", isDirectory: true)
        for e in entries {
            let parts = e.path.split(separator: "/").map(String.init).filter { $0 != "." }
            guard !parts.isEmpty else { continue }
            var cur = root
            var prefixParts: [String] = []
            for (i, p) in parts.enumerated() {
                prefixParts.append(p)
                let last = i == parts.count - 1
                let relPath = prefixParts.joined(separator: "/")
                if let existing = cur.childMap[p] {
                    cur = existing
                    if last && !e.isDirectory {
                        cur.size = e.size
                        cur.modified = e.modified
                        cur.entryPath = relPath
                    }
                    continue
                }
                let node = FileNode(
                    name: p,
                    isDirectory: !last || e.isDirectory,
                    entryPath: relPath,
                    size: last && !e.isDirectory ? e.size : nil,
                    modified: last ? e.modified : nil
                )
                if last {
                    node.encrypted = e.isEncrypted
                    node.isSymlink = e.isSymlink
                }
                cur.add(node)
                cur = node
            }
        }
        root.sortRecursively()
        root.totalSize()
        return root
    }
}

/// Outline listing name / size / modified / kind for a FileNode tree.
final class FileTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outline = NSOutlineView()
    let root: FileNode
    var onOpen: ((FileNode) -> Void)?
    var onSelectionChange: (([FileNode]) -> Void)?
    var contextMenuBuilder: (([FileNode]) -> NSMenu?)?
    private let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    init(root: FileNode, allowsMultipleSelection: Bool = false) {
        self.root = root
        super.init(frame: .zero)
        for (id, title, w) in [("n", "名称", 360.0), ("s", "大小", 90.0), ("d", "修改日期", 140.0), ("k", "种类", 140.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            c.minWidth = 50
            c.headerCell.font = .systemFont(ofSize: 10.5, weight: .semibold)
            if id == "s" { c.headerCell.alignment = .right }
            outline.addTableColumn(c)
            if id == "n" { outline.outlineTableColumn = c }
        }
        outline.style = .plain
        outline.rowHeight = 22
        outline.backgroundColor = Theme.sheet
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = allowsMultipleSelection
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let s = NSScrollView()
        s.documentView = outline
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.backgroundColor = Theme.sheet
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        outline.reloadData()
        // A single top-level folder (typical "project.zip/project/") is opened right away.
        if root.children.count == 1, let only = root.children.first, only.isDirectory { outline.expandItem(only) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func detach() {
        outline.dataSource = nil
        outline.delegate = nil
        outline.menu?.delegate = nil
        onOpen = nil
        onSelectionChange = nil
        contextMenuBuilder = nil
    }

    var selectedNodes: [FileNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? FileNode) ?? root).children.count }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? FileNode) ?? root).children[index] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory ?? false }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(selectedNodes)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let builder = contextMenuBuilder else { return }
        let clicked = outline.clickedRow
        let targets: [FileNode]
        if clicked >= 0 {
            if outline.selectedRowIndexes.contains(clicked) {
                targets = selectedNodes
            } else if let node = outline.item(atRow: clicked) as? FileNode {
                outline.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
                targets = [node]
            } else {
                targets = []
            }
        } else {
            targets = selectedNodes
        }
        guard let built = builder(targets) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }

    @objc private func doubleClicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if n.isDirectory { outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n) } else { onOpen?(n) }
    }

    func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FileNode, let id = col?.identifier.rawValue else { return nil }
        if id == "n" {
            let cell =
                (o.makeView(withIdentifier: .init("name"), owner: nil) as? NSTableCellView)
                ?? {
                    let v = NSTableCellView()
                    v.identifier = .init("name")
                    let iv = NSImageView()
                    let t = NSTextField(labelWithString: "")
                    t.lineBreakMode = .byTruncatingMiddle
                    t.font = .systemFont(ofSize: 12)
                    for x in [iv, t] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
                    v.imageView = iv
                    v.textField = t
                    NSLayoutConstraint.activate([
                        iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                        t.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6), t.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                        t.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                    ])
                    return v
                }()
            cell.textField?.stringValue = n.name + (n.encrypted ? "  🔒" : "")
            let ext = (n.name as NSString).pathExtension
            cell.imageView?.image =
                n.isDirectory
                ? NSWorkspace.shared.icon(for: .folder)
                : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
            return cell
        }
        let t =
            (o.makeView(withIdentifier: .init(id), owner: nil) as? NSTextField)
            ?? {
                let t = NSTextField(labelWithString: "")
                t.identifier = .init(id)
                t.lineBreakMode = .byTruncatingTail
                return t
            }()
        t.textColor = .secondaryLabelColor
        switch id {
        case "s":
            t.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            t.alignment = .right
            t.stringValue = n.size.map { Fmt.bytes($0) } ?? "—"
        case "d":
            t.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            t.stringValue = n.modified.map { dateFmt.string(from: $0) } ?? "—"
        default:
            t.font = .systemFont(ofSize: 11)
            if n.isDirectory {
                t.stringValue = "文件夹"
            } else {
                let ext = (n.name as NSString).pathExtension
                t.stringValue = UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? "文件" : ext.uppercased())
            }
        }
        return t
    }
}

func stackTreeView(header: NSView, body: NSView) -> NSView {
    let v = NSView()
    for x in [header, body] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
    NSLayoutConstraint.activate([
        header.topAnchor.constraint(equalTo: v.topAnchor), header.leadingAnchor.constraint(equalTo: v.leadingAnchor),
        header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        body.topAnchor.constraint(equalTo: header.bottomAnchor), body.leadingAnchor.constraint(equalTo: v.leadingAnchor),
        body.trailingAnchor.constraint(equalTo: v.trailingAnchor), body.bottomAnchor.constraint(equalTo: v.bottomAnchor),
    ])
    return v
}

/// Lists archive contents through libarchive, with on-demand safe extraction and single-file preview.
@MainActor
final class ArchiveRenderer: Renderer {
    static let engineName = "libarchive"
    static func canHandle(_ file: FileContext) -> Bool { !file.isDirectory }

    private var tree: FileTreeView?
    private var headerModel: ArchiveHeaderModel?
    private weak var host: RenderHost?
    private var archiveURL: URL?
    private var listing: ArchiveListing?
    private var activeTask: Task<Void, Never>?
    private var fileCount = 0
    private var dirCount = 0

    required init() {}

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        let url = file.url
        self.archiveURL = url
        host.reportProgress(nil, label: "正在读取目录…")
        let l: ArchiveListing
        do {
            l = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ArchiveReader.list(
                        url: url,
                        progress: { n in
                            Task { @MainActor in host.reportProgress(nil, label: "正在读取目录… \(n) 项") }
                        }, isCancelled: { Task.isCancelled })
                }.value
            } onCancel: {
            }
        } catch ArchiveError.cancelled {
            throw RenderError.cancelled
        } catch {
            throw RenderError.unreadable((error as? LocalizedError)?.errorDescription ?? "无法读取压缩包")
        }
        try Task.checkCancellation()
        listing = l
        fileCount = l.entries.filter { !$0.isDirectory }.count
        dirCount = l.entries.count - fileCount

        let root = FileNode.tree(from: l.entries)
        let t = FileTreeView(root: root, allowsMultipleSelection: true)
        tree = t

        var note: String?
        if l.truncated {
            note = "条目过多，仅列出前 \(Fmt.number(ArchiveReader.maxEntries)) 项"
        } else if l.errorMessage != nil {
            note = "部分内容无法读取（可能已损坏或加密）"
        } else if l.entries.contains(where: { $0.isEncrypted }) {
            note = "包含加密条目"
        }

        let hm = ArchiveHeaderModel(
            title: l.formatName.uppercased() + (l.filterName.isEmpty ? "" : " · \(l.filterName)"),
            detail: "\(Fmt.number(fileCount)) 个文件 · 解压后约 \(Fmt.bytes(root.size ?? 0))",
            note: note
        )
        hm.onExtractHere = { [weak self] in self?.extractHere(selectedPaths: nil) }
        hm.onExtractTo = { [weak self] in self?.chooseDestinationAndExtract(selectedPaths: nil) }
        hm.onExtractSelected = { [weak self] in self?.extractSelectedHere() }
        hm.onPreviewSelected = { [weak self] in
            guard let self, let node = self.tree?.selectedNodes.first, !node.isDirectory else { return }
            self.preview(node: node)
        }
        hm.onCancel = { [weak self] in self?.activeTask?.cancel() }
        headerModel = hm

        t.onSelectionChange = { [weak self] nodes in
            guard let self, let hm = self.headerModel else { return }
            hm.selectedCount = nodes.count
            hm.canPreviewSelected = nodes.count == 1 && !nodes[0].isDirectory && !nodes[0].encrypted && !nodes[0].isSymlink
        }
        t.onOpen = { [weak self] node in self?.preview(node: node) }
        t.contextMenuBuilder = { [weak self] nodes in self?.buildContextMenu(for: nodes) }

        let header = RendererHostingView(ArchiveHeaderView(model: hm))
        header.sizingOptions = [.intrinsicContentSize]
        return stackTreeView(header: header, body: t)
    }

    func cleanup() {
        activeTask?.cancel()
        activeTask = nil
        headerModel?.detach()
        headerModel = nil
        tree?.detach()
        tree = nil
    }

    var statusText: String { "\(Fmt.number(fileCount)) 个文件 · \(Fmt.number(dirCount)) 个文件夹 · 双击文件可临时预览" }
    var infoSections: [InfoSection] {
        guard let l = listing else { return [] }
        var items = [
            InfoItem("格式", l.formatName), InfoItem("文件", Fmt.number(fileCount)), InfoItem("文件夹", Fmt.number(dirCount)),
            InfoItem("解压后大小", Fmt.bytes(tree?.root.size ?? 0)),
        ]
        if !l.filterName.isEmpty { items.insert(InfoItem("压缩", l.filterName), at: 1) }
        if let e = l.errorMessage { items.append(InfoItem("警告", e)) }
        return [InfoSection("压缩包", items)]
    }
    var initialFirstResponder: NSView? { tree?.outline }

    // MARK: Actions

    private func buildContextMenu(for nodes: [FileNode]) -> NSMenu? {
        guard !nodes.isEmpty else { return nil }
        let menu = NSMenu()
        if nodes.count == 1, let single = nodes.first, !single.isDirectory {
            let previewItem = NSMenuItem(title: "在新标签页中预览", action: #selector(contextPreview), keyEquivalent: "")
            previewItem.target = self
            previewItem.isEnabled = !single.encrypted && !single.isSymlink
            menu.addItem(previewItem)
            menu.addItem(.separator())
        }
        let hereItem = NSMenuItem(title: "解压选中项到当前文件夹", action: #selector(contextExtractSelectedHere), keyEquivalent: "")
        hereItem.target = self
        menu.addItem(hereItem)

        let pickItem = NSMenuItem(title: "解压选中项到…", action: #selector(contextExtractSelectedTo), keyEquivalent: "")
        pickItem.target = self
        menu.addItem(pickItem)
        return menu
    }

    @objc private func contextPreview() {
        guard let node = tree?.selectedNodes.first, !node.isDirectory else { return }
        preview(node: node)
    }

    @objc private func contextExtractSelectedHere() { extractSelectedHere() }

    @objc private func contextExtractSelectedTo() {
        let paths = selectedEntryPaths()
        guard !paths.isEmpty else { return }
        chooseDestinationAndExtract(selectedPaths: paths)
    }

    private func selectedEntryPaths() -> Set<String> {
        Set((tree?.selectedNodes ?? []).compactMap(\.entryPath))
    }

    private func extractSelectedHere() {
        let paths = selectedEntryPaths()
        guard !paths.isEmpty else { return }
        extractHere(selectedPaths: paths)
    }

    private func extractHere(selectedPaths: Set<String>?) {
        guard let archiveURL else { return }
        let dest = archiveURL.deletingLastPathComponent()
        runExtraction(to: dest, selectedPaths: selectedPaths)
    }

    private func chooseDestinationAndExtract(selectedPaths: Set<String>?) {
        guard let archiveURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = archiveURL.deletingLastPathComponent()
        panel.prompt = "解压到这里"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let folder = panel.url else { return }
            self?.runExtraction(to: folder, selectedPaths: selectedPaths)
        }
        if let win = host?.window {
            panel.beginSheetModal(for: win, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func runExtraction(to folder: URL, selectedPaths: Set<String>?) {
        guard let archiveURL, activeTask == nil else { return }
        headerModel?.busyLabel = "正在解压…"
        let options = ArchiveExtractOptions(
            selectedPaths: selectedPaths,
            smartWrap: selectedPaths == nil
        )
        activeTask = Task { [weak self] in
            defer {
                self?.activeTask = nil
                self?.headerModel?.busyLabel = nil
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ArchiveExtractor.extract(
                        archiveURL: archiveURL,
                        to: folder,
                        options: options,
                        progress: { p in
                            Task { @MainActor [weak self] in
                                self?.headerModel?.busyLabel = "已解压 \(p.completedFiles) 个文件…"
                            }
                        },
                        isCancelled: { Task.isCancelled }
                    )
                }.value
                guard let self else { return }
                var summary = "已解压 \(Fmt.number(result.extractedFiles)) 个文件（\(Fmt.bytes(result.totalBytes))）"
                if result.skippedEncrypted > 0 {
                    summary += "，跳过 \(result.skippedEncrypted) 个加密项"
                }
                if result.skippedUnsafe > 0 {
                    summary += "，拦截 \(result.skippedUnsafe) 个不安全路径"
                }
                self.host?.showNotice(
                    summary,
                    style: result.skippedEncrypted > 0 || result.skippedUnsafe > 0 ? .warning : .success,
                    action: NoticeAction(title: "在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                    }
                )
            } catch ArchiveOperationError.cancelled {
                self?.host?.showNotice("已取消解压", style: .info, action: nil)
            } catch {
                self?.host?.showNotice(
                    (error as? LocalizedError)?.errorDescription ?? "解压失败：\(error.localizedDescription)",
                    style: .warning,
                    action: nil
                )
            }
        }
    }

    private func preview(node: FileNode) {
        guard let archiveURL, let entryPath = node.entryPath, activeTask == nil else { return }
        if node.encrypted {
            host?.showNotice("「\(node.name)」已加密，无法直接预览", style: .warning, action: nil)
            return
        }
        if node.isSymlink {
            host?.showNotice("出于安全，不直接预览压缩包里的符号链接", style: .warning, action: nil)
            return
        }
        headerModel?.busyLabel = "正在提取预览…"
        activeTask = Task { [weak self] in
            defer {
                self?.activeTask = nil
                self?.headerModel?.busyLabel = nil
            }
            do {
                let previewURL = try await Task.detached(priority: .userInitiated) {
                    try ArchivePreviewCache.shared.extractForPreview(
                        archiveURL: archiveURL,
                        entryPath: entryPath,
                        isCancelled: { Task.isCancelled }
                    )
                }.value
                self?.host?.openInNewTab(previewURL)
            } catch ArchiveOperationError.cancelled {
                // User cancelled; no banner needed.
            } catch {
                self?.host?.showNotice(
                    (error as? LocalizedError)?.errorDescription ?? "无法预览：\(error.localizedDescription)",
                    style: .warning,
                    action: nil
                )
            }
        }
    }
}
