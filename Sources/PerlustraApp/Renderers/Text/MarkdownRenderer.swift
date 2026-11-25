import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PerlustraCore

/// Markdown as one document you read and edit in place, as in Typora, plus its plain source. The
/// text moves with you between the two; edits are saved with ⌘S in the file's own encoding, and new
/// documents are drafts that save themselves until they get a place.
///
/// The editor slows down on very long documents, so those show as a typeset page instead and are
/// edited in the source view.
@MainActor
final class MarkdownRenderer: WebDocumentRenderer, Renderer, FormatCommandHandling {
    static let engineName = "WebKit"
    static func canHandle(_ file: FileContext) -> Bool { file.size < 32 * 1024 * 1024 }

    static let readMode = 0, writeMode = 1
    /// Longer than this, in bytes of Markdown, opens as a typeset page rather than in the editor.
    static let longestForEditor = 800_000
    override var sourceMode: Int { 2 }

    private(set) var writer: MarkdownWriter?
    /// The writer's outline (headings) on its left.
    @Published var outline = false
    private var url: URL?
    /// Encoding and line endings the file is saved back with.
    private var format = TextFileFormat.utf8LF
    /// The file's text exactly as on disk (last read or saved).
    private var diskText = ""
    /// The text the views show for the file on disk; there are unsaved edits while the text
    /// differs from it. The writer tidies Markdown its own way, so for it this is its tidied form.
    private var savedText = ""
    /// The text the reading page shows.
    private var renderedText: String?
    private var draftTimer: Timer?
    private var autosaveTimer: Timer?
    private var replaceTask: Task<Void, Never>?
    /// How many characters are selected in the writer.
    private var selectedChars = 0

    required override init() { super.init() }

    /// The view that shows the document, as opposed to its source.
    private(set) var documentMode = MarkdownRenderer.writeMode
    private lazy var isDraftFile = url.map(MarkdownDrafts.contains) ?? false
    var isDraft: Bool { isDraftFile }
    var documentURL: URL? { url }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        let url = file.url
        self.url = url
        let (text, fmt) = try await Task.detached { try TextFileFormat.read(url) }.value
        format = fmt
        diskText = text
        savedText = text
        sourceText = text
        sourceLanguage = "markdown"
        editableSource = true
        navigator.host = host
        navigator.fileRoot = folder
        buildShell(nil)
        documentMode = file.size > Self.longestForEditor ? Self.readMode : Self.writeMode
        if documentMode == Self.writeMode {
            try await openWriter()
            mode = Self.writeMode
            applyMode()
        } else {
            try await openReader()
        }
        return container
    }

    private var folder: URL { (url ?? FileManager.default.homeDirectoryForCurrentUser).deletingLastPathComponent() }

    private func openReader() async throws {
        let wv = try await WebFactory.make(javaScript: true, fileRoot: folder)
        wv.navigationDelegate = navigator
        wv.uiDelegate = navigator
        let template = AppResources.webRoot.appendingPathComponent("markdown.html")
        guard let html = try? String(contentsOf: template, encoding: .utf8) else { throw RenderError.unsupported("缺少 Markdown 模板资源") }
        // Base URL is the document's folder so relative images resolve through perlustra://file/.
        let base = PerlustraSchemeHandler.url(forFile: folder).appendingPathComponent("/")
        try await navigator.load(wv) { wv.loadHTMLString(html, baseURL: base) }
        attachWeb(wv)
        guard await render(sourceText) else { throw RenderError.unreadable("Markdown 渲染脚本执行失败") }
    }

    private func openWriter() async throws {
        let w = try await MarkdownWriter.make(text: sourceText, folder: folder, mode: .write, outline: outline, navigator: navigator)
        w.onChange = { [weak self] text in
            guard let self else { return }
            self.sourceText = text
            self.edited()
        }
        w.onToggleSource = { [weak self] in self?.toggleWriteSource() }
        w.onLink = { [weak self] href in self?.follow(href) }
        w.onSelection = { [weak self] n in
            self?.selectedChars = n
            self?.host?.rendererDidUpdate()
        }
        w.onToggleMode = { [weak self] name in self?.toggleWriterMode(name) }
        writer = w
        addPane(w.webView, forMode: Self.writeMode)
        // The editor writes Markdown its own tidy way (table padding, [X]…): what it shows for an
        // untouched file is the baseline, so merely opening a file does not count as an edit.
        let shown = await w.value()
        if sourceText == savedText {
            savedText = shown
            sourceText = shown
        }
        applyWriterModes()
    }

    private func applyWriterModes() {
        writer?.setModes(focus: AppSettings.shared.writerFocus, typewriter: AppSettings.shared.writerTypewriter)
    }

    /// 专注模式 / 打字机模式 (F8 / F9), remembered for every document.
    func toggleWriterMode(_ name: String) {
        let s = AppSettings.shared
        if name == "focus" { s.writerFocus.toggle() } else { s.writerTypewriter.toggle() }
        if documentMode == Self.writeMode, mode != Self.writeMode { mode = Self.writeMode }
        applyWriterModes()
    }

    override var findDriver: WebFindDriver? { mode == Self.writeMode ? writer : nil }

    /// ⌥⌘F. A typeset page can't be changed, so this goes to the source first.
    func showReplace() {
        guard mode == Self.readMode else { showFind(replace: true); return }
        mode = sourceMode
        replaceTask?.cancel()
        replaceTask = Task { [weak self] in
            for _ in 0..<40 {
                guard let self, !Task.isCancelled else { return }
                if self.code != nil && self.mode == self.sourceMode { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, !Task.isCancelled, self.code != nil, self.mode == self.sourceMode else { return }
            self.showFind(replace: true)
        }
    }

    @discardableResult
    private func render(_ text: String) async -> Bool {
        guard let web else { return false }
        let result = try? await web.evaluateJavaScript("perlustraRender(\(MarkdownWriter.js(text)))")
        renderedText = text
        return result != nil
    }

    // MARK: Switching

    /// Brings the text along to the view being switched to.
    override func modeDidChange(from old: Int) {
        Task {
            await collectText(from: old)
            switch mode {
            case Self.readMode:
                if web == nil { try? await openReader() } else if renderedText != sourceText { await render(sourceText) }
            case Self.writeMode:
                if writer == nil { try? await openWriter() } else if writer?.text != sourceText { writer?.setValue(sourceText) }
            default:
                await reloadSource(sourceText)
            }
            differsFromSaved = sourceText != savedText
            applyMode()
            if mode == Self.writeMode { writer?.focus() }
        }
    }

    /// The text as the given view has it now.
    private func collectText(from m: Int) async {
        if m == Self.writeMode, let w = writer { sourceText = await w.value() }
        if m == sourceMode, let c = code { sourceText = c.textView.string }
    }

    /// ⌘/ (Typora): document ⇄ source.
    func toggleWriteSource() { mode = mode == sourceMode ? documentMode : sourceMode }

    func toggleOutline() {
        outline.toggle()
        writer?.command("outline")
    }

    /// A Typora menu command (heading, list, table…) applied in the writer.
    func format(_ command: String) {
        guard documentMode == Self.writeMode else {
            host?.showNotice("这份文档太长，请在源码里修改。", style: .info, action: nil)
            return
        }
        if mode != Self.writeMode { mode = Self.writeMode }
        writer?.command(command)
    }

    func performFormatCommand(_ command: String) {
        switch command {
        case "outline": toggleOutline()
        case "source": toggleWriteSource()
        case "focus", "typewriter": toggleWriterMode(command)
        default: format(command)
        }
    }

    func isFormatCommandOn(_ command: String) -> Bool {
        switch command {
        case "focus": return AppSettings.shared.writerFocus
        case "typewriter": return AppSettings.shared.writerTypewriter
        default: return false
        }
    }

    private func follow(_ href: String) {
        if let u = URL(string: href), let scheme = u.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            host?.showNotice(
                "链接不会自动打开：\(href)", style: .info,
                action: NoticeAction(title: "在浏览器中打开") { NSWorkspace.shared.open(u) })
            return
        }
        let path = (href.removingPercentEncoding ?? href).components(separatedBy: "#")[0]
        guard !path.isEmpty else { return }
        let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
        if let inside = FileAccessPolicy.fileInsideRoot(target, root: folder) {
            if FileManager.default.fileExists(atPath: inside.path) { host?.open(inside) }
        } else if FileManager.default.fileExists(atPath: target.path) {
            host?.showNotice(
                "链接指向当前文件夹外的文件：\(target.path)",
                style: .info,
                action: NoticeAction(title: "打开") { [weak self] in self?.host?.open(target) }
            )
        }
    }

    // MARK: Editing and saving

    /// The exact text now, from whichever view is showing.
    func documentText() async -> String {
        await collectText(from: mode)
        return currentSource
    }

    /// Puts new text in the view on screen (an undoable step in the writer and the source).
    func replaceDocument(_ text: String) {
        sourceText = text
        switch mode {
        case Self.writeMode: writer?.setValue(text)
        case sourceMode:
            if let c = code { c.replaceText(in: NSRange(location: 0, length: (c.textView.string as NSString).length), with: text) }
        default: Task { await render(text) }
        }
        edited()
    }

    override func sourceDidChange(_ text: String) { edited() }

    /// The text now (the source editor's while it is showing).
    override var currentSource: String { mode == sourceMode && sourceIsFilled ? (code?.textView.string ?? sourceText) : sourceText }

    private func edited() {
        differsFromSaved = sourceText != savedText
        if isDraft { scheduleDraftSave() } else if AppSettings.shared.markdownAutosave { scheduleAutosave() }
        host?.window?.isDocumentEdited = hasUnsavedChanges
        host?.rendererDidUpdate()
    }

    /// Drafts keep themselves: written a moment after each change.
    private func scheduleDraftSave() {
        draftTimer?.invalidate()
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let url = self.url else { return }
                let text = self.textForDisk()
                if (try? self.format.write(text, to: url)) != nil {
                    self.diskText = text
                    self.savedText = self.currentSource
                    self.differsFromSaved = false
                }
            }
        }
    }

    /// With 自动保存 on, files save themselves once typing pauses.
    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        guard hasUnsavedChanges else { return }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let url = self.url, self.hasUnsavedChanges else { return }
                self.write(to: url)
            }
        }
    }

    /// While writing, ←/→ move the caret. The editor is a web page, which the app's file
    /// switching shortcut does not recognise as a text field (源码 mode is one already).
    var wantsArrowKeys: Bool { mode == Self.writeMode }

    /// The tab strip asks on every redraw: comparing whole documents each time would be felt. In the
    /// source view the text can be ahead of the last report, so there it is always compared.
    var hasUnsavedChanges: Bool { !isDraft && (mode == sourceMode ? currentSource != savedText : differsFromSaved) }
    private var differsFromSaved = false

    func saveChanges(completion: @escaping (Bool) -> Void) {
        Task {
            await collectText(from: mode)
            if isDraft { saveDraftAs(completion: completion) } else if let url { write(to: url, completion: completion) } else { completion(false) }
        }
    }

    /// What goes to disk: the user's changes written into the file as it was, so lines they did
    /// not touch keep their exact form (not the editor's tidied one).
    private func textForDisk() -> String {
        savedText == diskText ? currentSource : LineMerge.merge(original: diskText, base: savedText, edited: currentSource)
    }

    private func write(to dest: URL, completion: ((Bool) -> Void)? = nil) {
        let shown = currentSource
        let text = textForDisk()
        do {
            let oldEncodingName = format.encoding.name
            let kept = try format.write(text, to: dest)
            if !kept {
                format = TextFileFormat(encoding: .utf8, lineEnding: format.lineEnding)
                host?.showNotice("已保存。部分字符无法用原编码（\(oldEncodingName)）表示，文件已改为 UTF-8。", style: .warning, action: nil)
            }
            if dest == url {
                diskText = text
                savedText = shown
            }
            edited()
            completion?(true)
        } catch {
            host?.showNotice("保存失败：\(error.localizedDescription)。原文件没有被改动。", style: .warning, action: nil)
            completion?(false)
        }
    }

    /// A draft's first save: choose a place; its pictures go along into assets/ beside it.
    private func saveDraftAs(completion: @escaping (Bool) -> Void) {
        guard let window = host?.window, let draft = url else { completion(false); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = MarkdownDrafts.suggestedName(for: currentSource) + ".md"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let dest = panel.url else { completion(false); return }
            self.write(to: dest) { ok in
                guard ok else { completion(false); return }
                MarkdownDrafts.moveAssets(of: self.currentSource, from: draft.deletingLastPathComponent(), to: dest.deletingLastPathComponent())
                MarkdownDrafts.discard(draft)
                completion(true)
                self.host?.open(dest)
            }
        }
    }

    private func saveAs() {
        guard let url, let window = host?.window else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.collectText(from: self.mode)
            if self.isDraft { self.saveDraftAs { _ in }; return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " 副本.md"
            panel.beginSheetModal(for: window) { [weak self] resp in
                guard let self, resp == .OK, let dest = panel.url else { return }
                self.write(to: dest) { ok in if ok { self.host?.open(dest) } }
            }
        }
    }

    /// 导出为 Word / PDF / 网页, beside the document unless chosen otherwise.
    func export(as ext: String) {
        guard let window = host?.window else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.collectText(from: self.mode)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
            panel.directoryURL = self.isDraft ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first : self.folder
            let stem = self.isDraft ? MarkdownDrafts.suggestedName(for: self.currentSource) : (self.url?.deletingPathExtension().lastPathComponent ?? "文档")
            panel.nameFieldStringValue = stem + "." + ext
            let text = self.currentSource
            panel.beginSheetModal(for: window) { [weak self] resp in
                guard resp == .OK, let dest = panel.url else { return }
                do {
                    try DocumentWriter.write(markdown: text, to: dest)
                    self?.host?.showNotice(
                        "已导出：\(dest.lastPathComponent)", style: .success,
                        action: NoticeAction(title: "在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([dest]) })
                } catch {
                    self?.host?.showNotice("导出失败：\(error.localizedDescription)", style: .warning, action: nil)
                }
            }
        }
    }

    func cleanup() {
        replaceTask?.cancel()
        replaceTask = nil
        draftTimer?.invalidate()
        autosaveTimer?.invalidate()
        // A draft nobody wrote anything in is not kept.
        if isDraft, let url, currentSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { MarkdownDrafts.discard(url) }
        writer?.teardown()
        writer = nil
        cleanupWeb()
    }

    // MARK: Presentation

    /// Counted once per version of the text; moving the selection redraws the status line too.
    private var counted: (text: String, lines: Int, chars: Int)?

    var statusText: String {
        let text = currentSource
        if counted?.text != text {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let chars = text.unicodeScalars.filter { !$0.properties.isWhitespace }.count
            counted = (text, lines, chars)
        }
        var s = "\(Fmt.number(counted?.lines ?? 0)) 行 · \(Fmt.number(counted?.chars ?? 0)) 字"
        if mode == Self.writeMode && selectedChars > 0 { s += " · 已选 \(Fmt.number(selectedChars)) 字" }
        if isDraft { s += " · 草稿（已自动保存，⌘S 选位置）" } else if hasUnsavedChanges { s += " · ● 已修改（⌘S 保存）" }
        return s
    }
    var infoSections: [InfoSection] {
        [
            InfoSection(
                "Markdown",
                [
                    InfoItem("编码", format.encoding.name + (format.lineEnding == "\r\n" ? " · CRLF" : format.lineEnding == "\r" ? " · CR" : " · LF")),
                    InfoItem("显示", documentMode == Self.writeMode ? "Vditor 即时渲染（本地）；粘贴的图片存到 assets/" : "文档较长，只显示排版页，可在源码里修改（本地）"),
                    InfoItem("安全", "已净化 HTML，远程资源已阻止，本地文件限于所在文件夹"),
                ])
        ]
    }
    var controls: AnyView? { AnyView(MarkdownControls(r: self)) }
    var initialFirstResponder: NSView? { mode == Self.writeMode ? writer?.webView : web }
    func supports(_ c: ViewerCommand) -> Bool {
        switch c {
        case .save: return hasUnsavedChanges || isDraft
        case .saveAs: return true
        default: return webSupports(c)
        }
    }
    func perform(_ c: ViewerCommand) {
        switch c {
        case .save: saveChanges { _ in }
        case .saveAs: saveAs()
        case .toggleSource: toggleWriteSource()
        default: webPerform(c)
        }
    }
}

struct MarkdownControls: View {
    @ObservedObject var r: MarkdownRenderer

    private var showsSource: Binding<Int> {
        Binding(get: { r.mode == r.sourceMode ? 1 : 0 }, set: { r.mode = $0 == 1 ? r.sourceMode : r.documentMode })
    }

    var body: some View {
        HStack(spacing: 4) {
            LensSegment(options: ["文档", "源码"], selection: showsSource)
            if r.mode == MarkdownRenderer.writeMode {
                LensButton(symbol: "list.bullet.indent", help: "大纲（⌃⌘1）", active: r.outline) { r.toggleOutline() }
            }
            LensButton(symbol: "magnifyingglass", help: "查找（⌘F）") { r.showFind() }
            Menu {
                Button("导出为 Word（.docx）…") { r.export(as: "docx") }
                Button("导出为 PDF…") { r.export(as: "pdf") }
                Button("导出为网页（.html）…") { r.export(as: "html") }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("导出")
        }
        .fixedSize()
    }
}
