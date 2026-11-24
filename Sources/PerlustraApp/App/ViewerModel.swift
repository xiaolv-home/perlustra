import AppKit
import SwiftUI
import PerlustraCore
import PerlustraObjC

struct LoadingState {
    var label: String
    var fraction: Double?
}

/// Per-window state: current file, active renderer, siblings and transient UI.
@MainActor
final class ViewerModel: ObservableObject, RenderHost, Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    @Published private(set) var file: FileContext?
    @Published private(set) var engine: String = ""
    @Published private(set) var loading: LoadingState?
    @Published var notice: Notice?
    @Published private(set) var siblings: [URL] = []
    @Published private(set) var siblingIndex: Int?
    @Published private(set) var infoSections: [InfoSection] = []
    @Published private(set) var statusText: String = ""
    @Published private(set) var controls: AnyView?
    private var controlsOwner: ObjectIdentifier?
    @Published private(set) var controlsPlacement: ControlsPlacement = .none
    @Published private(set) var failures: [String] = []
    @Published var isDropTargeted = false
    /// The window's sidebar folder (shared by its tabs; follows the file that opens).
    weak var browser: FolderBrowser?

    private(set) var renderer: Renderer?
    weak var stage: StageViewController?
    weak var windowController: ViewerWindowController?
    var window: NSWindow? { windowController?.window }
    /// True for the tab that is showing (only it may set the window's title).
    var isCurrent: Bool { windowController?.model === self }

    private var loadTask: Task<Void, Never>?
    private var chain: [Renderer.Type] = []
    private var chainPosition = 0
    private var loadGeneration = 0
    /// Last successful load per renderer, for diagnostics (`--probe`).
    var onLoadFinished: ((String, [String]) -> Void)?

    // MARK: Opening

    /// Asks to save pending edits; `done(true)` when it is fine to leave the file
    /// (saved or discarded), `done(false)` when the user cancelled or saving failed.
    func confirmLeaving(_ done: @escaping (Bool) -> Void) {
        guard let r = renderer, r.hasUnsavedChanges, let name = file?.name else { done(true); return }
        let alert = NSAlert()
        alert.messageText = "要保存对「\(name)」的修改吗？"
        alert.informativeText = "如果不保存，你的修改将会丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
        alert.buttons[2].hasDestructiveAction = true
        let handle: (NSApplication.ModalResponse) -> Void = { resp in
            switch resp {
            case .alertFirstButtonReturn: r.saveChanges { ok in done(ok) }
            case .alertThirdButtonReturn: done(true)
            default: done(false)
            }
        }
        if let w = window { alert.beginSheetModal(for: w, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    func open(_ url: URL) {
        if renderer?.hasUnsavedChanges == true {
            confirmLeaving { [weak self] ok in if ok { self?.openNow(url) } }
            return
        }
        openNow(url)
    }

    private func openNow(_ url: URL) {
        let url = url.standardizedFileURL
        loadGeneration += 1
        let gen = loadGeneration
        loadTask?.cancel()
        // Keep the current file on screen until the new one is ready (no blank flash).
        if let r = renderer {
            retireOutgoing()
            r.willBeReplaced()
            outgoing = (r, installedView)
            renderer = nil
            installedView = nil
        }
        notice = nil
        failures = []
        loading = LoadingState(label: "正在识别格式…", fraction: nil)
        if isCurrent {
            window?.title = url.lastPathComponent
            window?.representedURL = url
        }
        let isArchivePreview = ArchivePreviewCache.shared.isPreviewFile(url)
        if !isArchivePreview {
            browser?.reveal(url)
            if !AppEnvironment.isScripted {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                RecentFiles.add(url)
            }
        }

        loadTask = Task { [weak self] in
            let ctx = await Task.detached(priority: .userInitiated) { FileContext(url: url) }.value
            guard let self, gen == self.loadGeneration, !Task.isCancelled else { return }
            self.file = ctx
            self.chain = RendererRegistry.chain(for: ctx)
            self.chainPosition = 0
            self.refreshSiblings(for: url)
            await self.runChain(gen: gen)
        }
    }

    private func runChain(gen: Int) async {
        guard let file else { return }
        while chainPosition < chain.count {
            guard gen == loadGeneration, !Task.isCancelled else { return }
            let type = chain[chainPosition]
            let r = type.init()
            renderer = r
            engine = type.engineName
            loading = LoadingState(label: "正在载入…", fraction: loading?.fraction)
            do {
                debugLog("try \(type.engineName)")
                let view = try await r.makeView(for: file, host: self)
                debugLog("made \(type.engineName)")
                guard gen == loadGeneration, !Task.isCancelled else { retire(r, view: view); return }
                install(view, renderer: r)
                return
            } catch {
                r.cleanup()
                if renderer === r { renderer = nil }
                guard gen == loadGeneration else { return }
                if case RenderError.cancelled = error { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append("\(type.engineName)：\(msg)")
                Log.write("\(type.engineName) failed on \(file.name): \(msg)")
                chainPosition += 1
            }
        }
        // Nothing could render it (HexRenderer only fails on unreadable files).
        retireOutgoing()
        loading = nil
        renderer = nil
        engine = "—"
        stage?.showFailure(file: file, reasons: failures)
        onLoadFinished?("none", failures)
    }

    /// The view the current renderer installed (taken apart when the renderer goes away).
    private var installedView: NSView?
    /// The previous file's renderer, still on screen until the next one is ready.
    private var outgoing: (renderer: Renderer, view: NSView?)?

    private func retireOutgoing() {
        guard let o = outgoing else { return }
        outgoing = nil
        retire(o.renderer, view: o.view)
    }

    /// Ends a renderer: its own cleanup, then its view tree is taken apart. Renderers own views
    /// that embed SwiftUI views observing the renderer (formula bar, sidebars…); those are
    /// reference cycles, and without this a closed file — with all its data — stays in memory.
    private func retire(_ r: Renderer, view: NSView?) {
        r.cleanup()
        if let view {
            var reason: NSString?
            if !LPTry({ view.dismantleTree() }, &reason) { Log.write("dismantle failed: \(reason ?? "?")") }
        }
        if installedView === view { installedView = nil }
    }

    private func install(_ view: NSView, renderer r: Renderer) {
        loading = nil
        installedView = view
        var reason: NSString?
        let ok = LPTry({ self.stage?.install(view, presentation: r.presentation, replaced: { [weak self] in self?.retireOutgoing() }) }, &reason)
        if !ok {
            // AppKit raised while laying out the renderer: treat it as a renderer failure.
            requestFallback(from: r, reason: "界面异常：\(reason ?? "未知")")
            return
        }
        if let fr = r.initialFirstResponder { window?.makeFirstResponder(fr) } else { window?.makeFirstResponder(view) }
        rendererDidUpdate()
        // Showing a file another way is routine and says so in 简介; a banner only when what is
        // on screen is raw content of a damaged file, so the gibberish has an explanation.
        if !failures.isEmpty, notice == nil, fallbackNote(shownBy: r).showsRawContent {
            showNotice(fallbackNote(shownBy: r).message, style: .info, action: nil)
        }
        onLoadFinished?(type(of: r).engineName, failures)
    }

    /// How the file came to be shown this way (in 简介 rather than as a banner).
    private func openingNotes(_ r: Renderer) -> [InfoSection] {
        var items: [InfoItem] = []
        if let f = file, let src = ArchivePreviewCache.shared.previewSource(for: f.url) {
            items.append(InfoItem("压缩包预览", "来自「\(src.archiveName)」中的 \(src.entryPath)，关闭标签后自动清理"))
        }
        if !failures.isEmpty { items.append(InfoItem("显示方式", fallbackNote(shownBy: r).message)) }
        if let f = file, f.format.extensionMismatch {
            items.append(InfoItem("扩展名", ".\(f.ext.isEmpty ? "（无）" : f.ext) 与实际内容不符，按「\(f.format.label)」打开"))
        }
        return items.isEmpty ? [] : [InfoSection("打开方式", items)]
    }

    /// How the file came to be shown this way.
    private func fallbackNote(shownBy r: Renderer) -> FallbackNote {
        // "PDFKit：PDF 无法解析（…）" → "PDF 无法解析（…）"
        let reason = (failures.last ?? "").split(separator: "：", maxSplits: 1).last.map(String.init) ?? ""
        return r.fallbackNote(for: file, reason: reason)
    }

    private func teardownRenderer() {
        retireOutgoing()
        if let r = renderer { retire(r, view: installedView) }
        renderer = nil
        stage?.clear()
        controls = nil
        controlsPlacement = .none
        infoSections = []
        statusText = ""
        engine = ""
    }

    func close() {
        let closingURL = file?.url
        loadGeneration += 1
        loadTask?.cancel()
        teardownRenderer()
        file = nil
        loading = nil
        notice = nil
        if let closingURL, ArchivePreviewCache.shared.isPreviewFile(closingURL) {
            ArchivePreviewCache.shared.release(closingURL)
        }
    }

    func cancelLoading() {
        retireOutgoing()
        loadGeneration += 1
        loadTask?.cancel()
        teardownRenderer()
        loading = nil
        if let f = file {
            stage?.showFailure(file: f, reasons: ["已取消载入"])
        }
    }

    // MARK: RenderHost

    func reportProgress(_ fraction: Double?, label: String?) {
        if let label { loading = LoadingState(label: label, fraction: fraction) } else { loading = nil }
    }

    func requestFallback(from r: Renderer, reason: String) {
        guard r === renderer else { return }
        failures.append("\(type(of: r).engineName)：\(reason)")
        retire(r, view: installedView)
        renderer = nil
        stage?.clear()
        chainPosition += 1
        let gen = loadGeneration
        loadTask = Task { [weak self] in await self?.runChain(gen: gen) }
    }

    func showNotice(_ text: String, style: NoticeStyle, action: NoticeAction?) {
        notice = Notice(text: text, style: style, action: action)
    }

    func rendererDidUpdate() {
        guard let r = renderer else { return }
        // Everything showing a model redraws at each assignment, so only real changes are made.
        let sections = r.infoSections + openingNotes(r)
        if !InfoSection.sameContent(infoSections, sections) { infoSections = sections }
        let status = r.statusText
        if statusText != status { statusText = status }
        // A renderer's controls watch it themselves; the view only needs replacing when they come
        // or go, or belong to another renderer.
        let owner = ObjectIdentifier(r)
        let newControls = r.controls
        if controlsOwner != owner || (controls == nil) != (newControls == nil) {
            controls = newControls
            controlsOwner = owner
        }
        let placement = controls == nil ? ControlsPlacement.none : r.controlsPlacement
        if controlsPlacement != placement { controlsPlacement = placement }
        let name = type(of: r).engineName
        if engine != name { engine = name }
    }

    // MARK: Siblings

    func refreshSiblings(for url: URL) {
        let dir = url.deletingLastPathComponent()
        let showHidden = AppSettings.shared.showHiddenSiblings
        Task { [weak self] in
            let list = await Task.detached(priority: .utility) { () -> [URL] in
                ViewerModel.listSiblings(in: dir, showHidden: showHidden)
            }.value
            guard let self, self.file?.url == url else { return }
            self.siblings = list
            self.siblingIndex = list.firstIndex(of: url)
        }
    }

    nonisolated static func listSiblings(in dir: URL, showHidden: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys,
                options: showHidden ? [] : [.skipsHiddenFiles])
        else { return [] }
        return items.filter { u in
            let rv = try? u.resourceValues(forKeys: Set(keys))
            if rv?.isDirectory == true { return rv?.isPackage == true }
            return true
        }
        .map { $0.standardizedFileURL }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Opens a file in a tab of its own (or switches to it when already open).
    func openInNewTab(_ url: URL) {
        AppDelegate.shared?.openInTab(url, from: windowController)
    }

    func navigate(_ delta: Int) {
        guard !siblings.isEmpty else { return }
        let cur = siblingIndex ?? -1
        let next = cur + delta
        guard next >= 0, next < siblings.count else { NSSound.beep(); return }
        open(siblings[next])
    }

    var canGoBack: Bool { (siblingIndex ?? 0) > 0 }
    var canGoForward: Bool { (siblingIndex ?? Int.max) < siblings.count - 1 }

    // MARK: Commands

    func perform(_ c: ViewerCommand) { renderer?.perform(c) }
    func supports(_ c: ViewerCommand) -> Bool { renderer?.supports(c) ?? false }
}

func debugLog(_ s: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["PERLUSTRA_DEBUG"] != nil {
        FileHandle.standardError.write(Data(("[perlustra] " + s() + "\n").utf8))
    }
}
