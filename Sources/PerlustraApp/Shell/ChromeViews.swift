import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PerlustraCore

/// Folder browser: walk up and into folders; clicking a file opens it in a tab.
/// Keyboard: ↑↓ move, Return / → open, ← up a folder.
struct SidebarView: View {
    @ObservedObject var tabs: TabList
    @ObservedObject var browser: FolderBrowser
    var body: some View { SidebarContent(model: tabs.current, browser: browser) }
}

private struct SidebarContent: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var browser: FolderBrowser
    @State private var filter = ""
    @State private var selection: URL?
    @State private var cameFrom: URL?
    /// A folder just opened whose list has not arrived yet.
    @State private var arrived: URL?
    /// The + button's name field is showing.
    @State private var naming = false

    var filtered: [FolderBrowser.Item] {
        guard !filter.isEmpty else { return browser.items }
        return browser.items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TextField("筛选", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10).padding(.bottom, 6)
            keyedList
        }
        .background(Color(nsColor: Theme.sidebarFill).ignoresSafeArea())
        .onAppear { select(model.file?.url) }
        .onChange(of: model.file?.url) { _, u in select(u) }
        .onChange(of: browser.dir) { _, d in
            filter = ""
            arrived = d
        }
        .onChange(of: browser.items) { _, items in
            // The new folder's list comes a moment after the folder itself.
            guard arrived != nil, arrived == browser.dir else { return }
            arrived = nil
            // Going up selects the folder you came from, like Finder.
            if let c = cameFrom, items.contains(where: { $0.url == c }) { select(c) } else { select(model.file?.url) }
            cameFrom = nil
        }
    }

    private var fileList: some View {
        List(selection: $selection) {
            ForEach(filtered) { item in
                SidebarRow(item: item).tag(item.url)
            }
        }
        // Row or empty space: the menu is built for whatever was right-clicked.
        .contextMenu(forSelectionType: URL.self) { urls in contextMenu(for: urls) }
        .scrollContentBackground(.hidden)
        .listStyle(.sidebar)
        // Every click on a row opens it, anywhere in its highlight and whether or not it is
        // already selected. The list's own selection change cannot tell a click from the
        // arrow keys, misses clicks on the selected row and can arrive after the click.
        .background(
            ListRowClicks { row in
                guard filtered.indices.contains(row) else { return }
                let u = filtered[row].url
                select(u)
                activate(u)
            }
        )
    }

    private var keyedList: some View {
        fileList
            .onKeyPress(.return) {
                if let u = selection { activate(u) }; return .handled
            }
            .onKeyPress(.rightArrow) {
                guard let u = selection, isFolder(u) else { return .ignored }
                activate(u)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                goUp(); return .handled
            }
            // ⌘⌫, as in Finder.
            .onKeyPress(keys: [.delete], phases: .down) { press in
                guard press.modifiers.contains(.command), let u = selection else { return .ignored }
                model.windowController?.trashFromSidebar(u, isFolder: isFolder(u))
                return .handled
            }
            .overlay {
                if browser.items.isEmpty {
                    Text("这个文件夹是空的").font(.system(size: 12)).foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder private func contextMenu(for urls: Set<URL>) -> some View {
        if let url = urls.first, let item = browser.items.first(where: { $0.url == url }) {
            itemMenu(item)
            Divider()
        }
        folderMenu
    }

    @ViewBuilder private func itemMenu(_ item: FolderBrowser.Item) -> some View {
        if item.isFolder {
            Button("打开文件夹") { browser.show(item.url) }
        } else {
            Button("在新标签页中打开") { model.openInNewTab(item.url) }
            Button("在当前标签页中打开") { model.open(item.url) }
        }
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("拷贝路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.path, forType: .string)
        }
        Divider()
        if !item.isFolder && ArchivePathSafety.isArchiveFilename(item.name) {
            Button("解压到当前文件夹") { model.windowController?.extractFromSidebar(item.url) }
                .disabled(!browser.canCreateFiles)
        }
        Menu("压缩") {
            Button("压缩为 ZIP") { model.windowController?.compressFromSidebar(item.url, format: .zip) }
            Button("压缩为 tar.gz") { model.windowController?.compressFromSidebar(item.url, format: .tarGz) }
        }
        .disabled(!browser.canCreateFiles)
        Divider()
        Button("重命名…") { model.windowController?.renameFromSidebar(item.url) }
        Button("创建副本") { model.windowController?.duplicateFromSidebar(item.url) }
        Button("移到废纸篓（⌘⌫）", role: .destructive) { model.windowController?.trashFromSidebar(item.url, isFolder: item.isFolder) }
    }

    @ViewBuilder private var folderMenu: some View {
        Button("新建 Markdown…") { naming = true }.disabled(!browser.canCreateFiles)
        Button("新建文件夹…") { model.windowController?.newFolderFromSidebar() }.disabled(!browser.canCreateFiles)
        Divider()
        Button("刷新") { browser.reload() }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: goUp) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(browser.parent == nil)
            .help("上级文件夹（←）")
            Menu {
                Section("位置") {
                    ForEach(browser.ancestry, id: \.self) { u in
                        Button(u.path == "/" ? "磁盘" : u.lastPathComponent) { browser.show(u) }
                    }
                }
                Section("常用") {
                    ForEach(FolderBrowser.places, id: \.url) { p in Button(p.title) { browser.show(p.url) } }
                }
                let recent = FolderBrowser.recentFolders
                if !recent.isEmpty {
                    Section("最近用过的文件夹") {
                        ForEach(recent, id: \.self) { u in Button(u.lastPathComponent) { browser.show(u) } }
                    }
                }
                Divider()
                Button("选择文件夹…") { chooseFolder() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.ember).font(.system(size: 11))
                    Text(browser.dir?.lastPathComponent ?? "—").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help(browser.dir?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
            Spacer(minLength: 2)
            Text("\(browser.items.count)").font(Theme.mono(10)).foregroundStyle(.secondary)
            Button {
                browser.reload()
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("刷新（文件夹有变化时也会自动刷新）")
            Button {
                naming = true
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!browser.canCreateFiles)
            .help("在这个文件夹里新建 Markdown 文档")
            .popover(isPresented: $naming, arrowEdge: .bottom) {
                NewMarkdownForm(folder: browser.dir?.lastPathComponent ?? "") { name in
                    let url = try browser.createMarkdown(named: name)
                    naming = false
                    select(url)
                    model.openInNewTab(url)
                } cancel: {
                    naming = false
                }
            }
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.top, 10).padding(.bottom, 6)
    }

    private func select(_ u: URL?) {
        if selection != u { selection = u }
    }

    private func isFolder(_ u: URL) -> Bool { browser.items.first { $0.url == u }?.isFolder == true }

    private func goUp() {
        cameFrom = browser.dir
        browser.goUp()
    }

    /// Folders open in place; files open in a tab (⌥-click: in this tab, for quick browsing).
    private func activate(_ u: URL) {
        if isFolder(u) {
            browser.show(u)
        } else if u != model.file?.url {
            if NSEvent.modifierFlags.contains(.option) { model.open(u) } else { model.openInNewTab(u) }
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = browser.dir
        p.prompt = "前往"
        if p.runModal() == .OK, let u = p.url { browser.show(u) }
    }
}

/// Names a new Markdown document: Return makes it, Esc gives up.
private struct NewMarkdownForm: View {
    let folder: String
    let create: (String) throws -> Void
    let cancel: () -> Void
    @State private var name = "未命名"
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在「\(folder)」里新建 Markdown").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 4) {
                TextField("文件名", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                    .frame(width: 180)
                Text(".md").font(Theme.mono(11)).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("新建", action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func submit() {
        do { try create(name) } catch { self.error = "没能新建：\(error.localizedDescription)" }
    }
}

/// Reports which row of the enclosing list a click lands on, as the mouse goes down. It watches
/// the window's clicks instead of the rows, because a row's content does not reach the ends of
/// its highlight.
private struct ListRowClicks: NSViewRepresentable {
    let onClick: (Int) -> Void

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ v: Catcher, context: Context) { v.onClick = onClick }

    final class Catcher: NSView {
        var onClick: ((Int) -> Void)?
        private var monitor: Any?
        private weak var table: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
                self?.handle(e)
                return e
            }
        }

        override func removeFromSuperview() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            super.removeFromSuperview()
        }

        private func handle(_ e: NSEvent) {
            // One plain click: a double click's second press lands in the folder just opened,
            // and ⌃-click is the context menu.
            guard e.clickCount == 1, !e.modifierFlags.contains(.control), let table = findTable(), e.window === table.window else { return }
            let p = table.convert(e.locationInWindow, from: nil)
            guard table.visibleRect.contains(p) else { return }
            let row = table.row(at: p)
            guard row >= 0 else { return }
            // After the list has handled the press (and selected the row).
            DispatchQueue.main.async { [weak self] in self?.onClick?(row) }
        }

        /// The list beside this view: the nearest ancestor's table.
        private func findTable() -> NSTableView? {
            if let t = table, t.window === window { return t }
            func search(_ v: NSView) -> NSTableView? {
                if let t = v as? NSTableView { return t }
                for sub in v.subviews { if let t = search(sub) { return t } }
                return nil
            }
            var v: NSView? = superview
            while let cur = v {
                if let t = search(cur) { table = t; return t }
                v = cur.superview
            }
            return nil
        }
    }
}

private struct SidebarRow: View {
    let item: FolderBrowser.Item
    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: IconCache.icon(for: item)).resizable().frame(width: 16, height: 16)
            Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if item.isFolder {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }

    }
}

/// File icons by type (asking the system per row on every redraw makes scrolling stutter).
/// Folders with their own icon (Desktop, Downloads…) and packages keep it.
@MainActor
enum IconCache {
    private static var byKey: [String: NSImage] = [:]

    static func icon(for item: FolderBrowser.Item) -> NSImage {
        let ext = item.url.pathExtension.lowercased()
        let special = item.isFolder ? item.url.path : (ext.isEmpty || ["app", "pages", "numbers", "key"].contains(ext) ? item.url.path : nil)
        let key = special ?? "ext:" + ext
        if let i = byKey[key] { return i }
        let i =
            special != nil
            ? FileIcons.icon(for: item.url)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        if byKey.count > 2000 { byKey.removeAll() }
        byKey[key] = i
        return i
    }
}

/// The inspector for whichever tab is showing.
struct CurrentInspector: View {
    @ObservedObject var tabs: TabList
    var body: some View { InspectorView(model: tabs.current) }
}

/// Right-hand inspector with file and content metadata.
struct InspectorView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        ScrollView {
            if let f = model.file {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 10) {
                        Image(nsImage: FileIcons.icon(for: f.url))
                            .resizable().interpolation(.high).frame(width: 64, height: 64)
                        Text(f.name).font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.center).lineLimit(3)
                        FormatBadge(token: f.format.token, category: f.format.family.category)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)

                    InfoBlock(section: InfoSection("文件", fileItems(f)))
                    ForEach(model.infoSections) { s in InfoBlock(section: s) }
                }
                .padding(16)
            } else {
                Text("没有打开的文件").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
    }

    func fileItems(_ f: FileContext) -> [InfoItem] {
        var items = [
            InfoItem("类型", f.format.label),
            InfoItem("大小", Fmt.bytes(f.size) + (f.size >= 1024 ? "（\(Fmt.exactBytes(f.size))）" : "")),
            InfoItem("修改时间", Fmt.date(f.modified)),
            InfoItem("创建时间", Fmt.date(f.created)),
            InfoItem("位置", f.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")),
        ]
        if let t = f.utType { items.append(InfoItem("UTI", t.identifier)) }
        let src: String
        switch f.format.source {
        case .magic: src = "文件头签名"
        case .extension: src = "扩展名"
        case .sniff: src = "内容分析"
        case .directory: src = "文件包结构"
        }
        items.append(InfoItem("识别依据", src + (f.format.extensionMismatch ? "（扩展名不符）" : "")))
        items.append(InfoItem("渲染引擎", model.engine))
        return items
    }
}

struct InfoBlock: View {
    let section: InfoSection
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: section.title)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(section.items) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text(item.value).font(Theme.mono(11.5)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: Theme.hairline)))
        }
    }
}
