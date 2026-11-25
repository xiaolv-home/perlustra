import AppKit
import PerlustraCore

/// Host interface exposed to sidebar views and `ViewerModel` so they do not depend on
/// concrete window controller or application delegate types.
@MainActor
protocol SidebarHost: AnyObject {
    func openInTab(_ url: URL)
    func renameFromSidebar(_ url: URL)
    func duplicateFromSidebar(_ url: URL)
    func trashFromSidebar(_ url: URL, isFolder: Bool)
    func trashItemsFromSidebar(_ urls: [URL])
    func newFolderFromSidebar()
    func compressItemsFromSidebar(_ urls: [URL], format: ArchiveOutputFormat)
    func extractFromSidebar(_ url: URL)
}

/// The sidebar's folder: where you are, what is in it (folders first), and how you got there.
/// It follows the open file, but you can walk up and into other folders without opening anything.
@MainActor
final class FolderBrowser: ObservableObject {
    struct Item: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var dir: URL?
    @Published private(set) var items: [Item] = []
    private static let lastDirKey = "lastBrowseDir"

    init() {
        let last = UserDefaults.standard.string(forKey: Self.lastDirKey).map { URL(fileURLWithPath: $0) }
        let start =
            last.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if let start { show(start) }
    }

    /// Shows the folder holding a file that was just opened.
    func reveal(_ file: URL) {
        let d = file.deletingLastPathComponent().standardizedFileURL
        if d != dir { show(d) }
    }

    func show(_ folder: URL) {
        let d = folder.standardizedFileURL
        dir = d
        if !AppEnvironment.isScripted { UserDefaults.standard.set(d.path, forKey: Self.lastDirKey) }
        reload()
    }

    func reload() {
        guard let d = dir else { return }
        watch(d)
        let showHidden = AppSettings.shared.showHiddenSiblings
        // Listed off the main thread: macOS can hold a listing of 文稿 / 桌面 / 下载 until you
        // answer its permission prompt, and the window must not freeze meanwhile. The old list
        // stays until the new one is ready, so there is no blank moment.
        Task { [weak self] in
            let (list, writable) = await Task.detached(priority: .userInitiated) {
                (Self.list(d, showHidden: showHidden), FileManager.default.isWritableFile(atPath: d.path))
            }.value
            guard let self, self.dir == d else { return }
            self.items = list
            self.canCreateFiles = writable
        }
    }

    // MARK: Keeping up with the disk

    private var watcher: DispatchSourceFileSystemObject?
    private var watched: URL?
    private var pendingReload: DispatchWorkItem?

    deinit { watcher?.cancel() }

    /// Files added, removed or renamed in this folder, by anything, show up by themselves. Opened
    /// off the main thread for the same reason the listing is.
    private func watch(_ d: URL) {
        guard watched != d else { return }
        watched = d
        watcher?.cancel()
        watcher = nil
        Task { [weak self] in
            let descriptor = await Task.detached(priority: .utility) { open(d.path, O_EVTONLY) }.value
            guard descriptor >= 0 else { return }
            guard let self, self.watched == d else {
                close(descriptor)
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleReload() } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.watcher = source
        }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    var parent: URL? {
        guard let d = dir, d.path != "/" else { return nil }
        return d.deletingLastPathComponent()
    }

    func goUp() { if let p = parent { show(p) } }

    /// Whether new files can be made here (the sidebar's + button); found with the listing.
    @Published private(set) var canCreateFiles = false

    /// Makes an empty Markdown file in this folder ("名字.md", or "名字 2.md" when taken) and
    /// lists it.
    func createMarkdown(named raw: String) throws -> URL {
        guard let d = dir else { throw CocoaError(.fileNoSuchFile) }
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined()
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)).trimmingCharacters(in: .whitespaces) }
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "未命名" }
        let fm = FileManager.default
        var url = d.appendingPathComponent(name + ".md")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = d.appendingPathComponent("\(name) \(n).md")
            n += 1
        }
        try Data().write(to: url, options: .withoutOverwriting)
        reload()
        return url
    }

    /// Makes a folder here ("名字", or "名字 2" when taken).
    func createFolder(named raw: String) throws -> URL {
        guard let d = dir else { throw CocoaError(.fileNoSuchFile) }
        let url = try FileOperations.createFolder(named: raw, in: d)
        reload()
        return url
    }

    /// The folder and every folder above it, innermost first (for the path menu).
    var ancestry: [URL] {
        var out: [URL] = []
        var cur = dir
        while let c = cur {
            out.append(c)
            if c.path == "/" { break }
            cur = c.deletingLastPathComponent()
        }
        return out
    }

    /// Home, Desktop, Downloads, Documents and the folders of recently opened files.
    static var places: [(title: String, url: URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = [("个人", fm.homeDirectoryForCurrentUser)]
        for (t, d) in [("桌面", FileManager.SearchPathDirectory.desktopDirectory), ("下载", .downloadsDirectory), ("文稿", .documentDirectory)] {
            if let u = fm.urls(for: d, in: .userDomainMask).first { out.append((t, u)) }
        }
        return out
    }

    /// Asked for whenever the sidebar redraws, and working it out checks files on disk, so the
    /// answer is kept for a moment. It only fills a menu, where a few seconds' lag can't be seen.
    static var recentFolders: [URL] {
        if let kept = recentFoldersKept, Date().timeIntervalSince(kept.at) < 10 { return kept.folders }
        var seen = Set<String>()
        let folders = RecentFiles.all().map { $0.deletingLastPathComponent() }.filter { seen.insert($0.path).inserted }.prefix(6).map { $0 }
        recentFoldersKept = (Date(), folders)
        return folders
    }
    private static var recentFoldersKept: (at: Date, folders: [URL])?

    /// Folders first, then files and packages (iWork documents open as files), by name.
    nonisolated static func list(_ dir: URL, showHidden: Bool) -> [Item] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys,
                options: showHidden ? [] : [.skipsHiddenFiles])
        else { return [] }
        let items = urls.map { u -> Item in
            let rv = try? u.resourceValues(forKeys: Set(keys))
            return Item(url: u.standardizedFileURL, isFolder: rv?.isDirectory == true && rv?.isPackage != true)
        }
        return items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// What the sidebar does to files. Nothing is ever deleted outright: removing goes to the Trash.
enum FileOperations {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// A name a file can have, or why it can't.
    static func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw Failure("名字不能为空") }
        if name == "." || name == ".." || name.contains("/") || name.contains(":") { throw Failure("名字里不能有 / 或 :") }
        return name
    }

    static func rename(_ url: URL, to raw: String) throws -> URL {
        let name = try validName(raw)
        if name == url.lastPathComponent { return url }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        // Changing only the case of a name finds the file itself on a case-insensitive disk.
        let sameFile = name.lowercased() == url.lastPathComponent.lowercased()
        if !sameFile && FileManager.default.fileExists(atPath: target.path) { throw Failure("这里已经有叫「\(name)」的了") }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    static func createFolder(named raw: String, in folder: URL) throws -> URL {
        let name = try validName(raw)
        let url = freeURL(in: folder, stem: name, ext: "", separator: " ")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// "报表.xlsx" → "报表 副本.xlsx", then "报表 副本 2.xlsx".
    static func duplicate(_ url: URL) throws -> URL {
        let copy = freeURL(
            in: url.deletingLastPathComponent(), stem: url.deletingPathExtension().lastPathComponent + " 副本", ext: url.pathExtension, separator: " ")
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// Returns where the item went, so it can be put back.
    static func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result = result as URL? else { throw Failure("没能移到废纸篓") }
        return result
    }

    private static func freeURL(in folder: URL, stem: String, ext: String, separator: String) -> URL {
        func url(_ name: String) -> URL { folder.appendingPathComponent(ext.isEmpty ? name : name + "." + ext) }
        var candidate = url(stem), n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url("\(stem)\(separator)\(n)")
            n += 1
        }
        return candidate
    }
}
