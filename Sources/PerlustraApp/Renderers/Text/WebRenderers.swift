import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import PerlustraCore

/// Common shell for web-rendered documents: the page (mode 0), its source (`sourceMode`), and any
/// panes a subclass adds (Markdown's writer); a find bar and zoom for whichever is showing.
@MainActor
class WebDocumentRenderer: NSObject, ObservableObject {
    @Published var mode = 0 { didSet { if mode != oldValue { modeDidChange(from: oldValue) } } }
    /// The mode that shows the source (HTML: 1; Markdown: 2).
    var sourceMode: Int { 1 }
    /// Markdown: the source can be edited.
    var editableSource = false
    private(set) var web: PerlustraWebView?
    let navigator = WebNavigator()
    let container = NSView()
    private let body = NSView()
    let findBar = WebFindBar()
    private var findHeight: NSLayoutConstraint!
    private(set) var code: CodeView?
    /// Views for other modes (keyed by mode).
    private var panes: [Int: NSView] = [:]
    var sourceText = ""
    var sourceLanguage = "markdown"
    weak var host: RenderHost?

    /// Lays out the find bar and the content area; the page can be attached later.
    func buildShell(_ wv: PerlustraWebView?) {
        findBar.onClose = { [weak self] in self?.hideFind() }
        for v in [findBar, body] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        findHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBar.isHidden = true
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: container.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findHeight,
            body.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if let wv { attachWeb(wv) }
    }

    func attachWeb(_ wv: PerlustraWebView) {
        web = wv
        pin(wv)
        wv.isHidden = mode != 0
        findBar.webView = activeWebView
    }

    func addPane(_ v: NSView, forMode m: Int) {
        panes[m] = v
        pin(v)
        v.isHidden = mode != m
    }

    /// The source view has its text. It fills in a moment after appearing, and until then the empty
    /// view must not be taken for the document, which would look like an unsaved edit.
    var sourceIsFilled = true

    /// Text as it is now (the source editor's, if it is showing).
    var currentSource: String { sourceIsFilled ? code?.textView.string ?? sourceText : sourceText }

    /// Called after source edits settle.
    func sourceDidChange(_ text: String) {}

    func modeDidChange(from old: Int) { applyMode() }

    /// What searches the view on screen, if not the browser's own find.
    var findDriver: WebFindDriver? { nil }

    /// The web view on screen (page or a pane that is one), for find and zoom.
    var activeWebView: WKWebView? { mode == 0 ? web : panes[mode] as? WKWebView }

    private func makeSourceView() -> CodeView {
        let c = CodeView()
        c.wrap = editableSource || AppSettings.shared.wrapText
        if editableSource {
            c.makeEditable(language: sourceLanguage)
            c.onEdit = { [weak self] text in
                guard let self else { return }
                self.sourceText = text
                self.sourceDidChange(text)
            }
        }
        let t = sourceText, l = sourceLanguage
        sourceIsFilled = false
        Task { [weak self] in
            await c.setText(t, language: l, highlight: t.utf8.count <= AppSettings.shared.highlightLimitBytes)
            self?.sourceIsFilled = true
            self?.host?.rendererDidUpdate()
        }
        return c
    }

    /// Replaces the source view's text (after it changed elsewhere).
    func reloadSource(_ text: String) async {
        guard let c = code, c.textView.string != text else { return }
        await c.setText(text, language: sourceLanguage, highlight: text.utf8.count <= AppSettings.shared.highlightLimitBytes)
    }

    private func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: body.leadingAnchor), v.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            v.topAnchor.constraint(equalTo: body.topAnchor), v.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    func applyMode() {
        if mode == sourceMode && code == nil {
            let c = makeSourceView()
            code = c
            pin(c)
        }
        web?.isHidden = mode != 0
        code?.isHidden = mode != sourceMode
        for (m, v) in panes { v.isHidden = m != mode }
        findBar.webView = activeWebView
        if !findBar.isHidden && mode == sourceMode { hideFind() }
        if findBar.driver !== findDriver {
            findBar.driver?.endSearch()
            findBar.driver = findDriver
        }
        if !findBar.isHidden && findDriver == nil && findBar.showsReplace { showFind() }
        let first: NSView? = mode == sourceMode ? code?.textView : mode == 0 ? web : panes[mode]
        container.window?.makeFirstResponder(first)
        host?.rendererDidUpdate()
    }

    func showFind(replace: Bool = false) {
        if mode == sourceMode { code?.showFind(); return }
        findBar.webView = activeWebView
        findBar.driver = findDriver
        findBar.isHidden = false
        findBar.showsReplace = replace && findDriver != nil
        findHeight.constant = findBar.showsReplace ? WebFindBar.heightWithReplace : WebFindBar.height
        container.window?.makeFirstResponder(findBar.field)
    }

    func hideFind() {
        findBar.driver?.endSearch()
        findBar.isHidden = true
        findHeight.constant = 0
        container.window?.makeFirstResponder(activeWebView)
    }

    func cleanupWeb() {
        NotificationCenter.default.removeObserver(self)
        code?.cancel()
        for wv in [web] + panes.values.map({ $0 as? PerlustraWebView }) {
            wv?.stopLoading()
            wv?.navigationDelegate = nil
            wv?.uiDelegate = nil
            wv?.loadHTMLString("", baseURL: nil)
            wv?.removeFromSuperview()
        }
        panes = [:]
        web = nil
    }

    func webSupports(_ c: ViewerCommand) -> Bool {
        switch c {
        case .toggleSource, .find, .findNext, .findPrevious, .zoomIn, .zoomOut, .actualSize: return true
        case .toggleWrap: return mode == sourceMode
        default: return false
        }
    }

    func webPerform(_ c: ViewerCommand) {
        let source = mode == sourceMode
        switch c {
        case .toggleSource: mode = mode == 0 ? sourceMode : 0
        case .find: showFind()
        case .findNext: source ? code?.findNext(true) : findBar.next()
        case .findPrevious: source ? code?.findNext(false) : findBar.previous()
        case .zoomIn: if source { code?.zoom(by: 1) } else if let w = activeWebView { w.pageZoom = min(3, w.pageZoom * 1.1) }
        case .zoomOut: if source { code?.zoom(by: -1) } else if let w = activeWebView { w.pageZoom = max(0.4, w.pageZoom / 1.1) }
        case .actualSize: activeWebView?.pageZoom = 1; code?.setFontSize(12.5)
        case .toggleWrap: code?.wrap.toggle()
        default: break
        }
    }
}

struct WebControls: View {
    @ObservedObject var r: WebDocumentRenderer
    var labels = ["渲染", "源码"]
    var body: some View {
        HStack(spacing: 4) {
            LensSegment(options: labels, selection: $r.mode)
            LensButton(symbol: "magnifyingglass", help: "查找（⌘F）") { r.showFind() }
        }
    }
}

/// HTML (and SVG fallback) in a web view with JavaScript disabled and remote loads blocked.
@MainActor
final class HTMLRenderer: WebDocumentRenderer, Renderer {
    static let engineName = "WebKit"
    static func canHandle(_ file: FileContext) -> Bool { file.size < 64 * 1024 * 1024 }
    private var isSVG = false
    private var title = ""
    /// Local pages run their scripts (offline, confined to their folder) unless turned off.
    private var scripts = false

    required override init() { super.init() }

    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView {
        self.host = host
        isSVG = file.format.family == .svg
        scripts = !isSVG && AppSettings.shared.webPagesRunScripts
        let url = file.url
        sourceText = (try? await Task.detached { TextEncodingDetector.decode(try Data(contentsOf: url)).0 }.value) ?? ""
        sourceLanguage = isSVG ? "xml" : "html"
        let folder = url.deletingLastPathComponent()
        let wv = try await WebFactory.make(javaScript: scripts, fileRoot: folder, keepsData: scripts && !AppEnvironment.isScripted)
        navigator.host = host
        navigator.fileRoot = folder
        if scripts { navigator.siteRoot = folder }
        wv.navigationDelegate = navigator
        wv.uiDelegate = navigator
        buildShell(wv)
        let target = PerlustraSchemeHandler.url(forFile: url)
        if isSVG {
            // <img> never runs SVG scripts and scales cleanly.
            let html = """
                <!doctype html><meta charset="utf-8"><style>html,body{margin:0;height:100%;background:transparent}
                body{display:flex;align-items:center;justify-content:center}
                img{max-width:calc(100% - 64px);max-height:calc(100% - 64px);min-width:64px}</style>
                <img src="\(target.absoluteString)">
                """
            try await navigator.load(wv) { wv.loadHTMLString(html, baseURL: URL(string: "perlustra://app/")) }
        } else {
            wv.setValue(true, forKey: "drawsBackground")
            try await navigator.load(wv) { wv.load(URLRequest(url: target)) }
            title = wv.title ?? ""
        }
        return container
    }

    func cleanup() { cleanupWeb() }
    var presentation: StagePresentation { isSVG ? .bleed : .sheet }
    var controlsPlacement: ControlsPlacement { isSVG ? .floating : .strip }
    var statusText: String {
        if isSVG { return "矢量图 · 脚本已禁用" }
        return (title.isEmpty ? "" : "「\(title)」 · ") + (scripts ? "脚本已运行 · 已断网" : "JavaScript 已禁用")
    }
    var infoSections: [InfoSection] {
        [
            InfoSection(
                isSVG ? "SVG" : "网页",
                [
                    InfoItem("标题", title.isEmpty ? "—" : title),
                    InfoItem(
                        "安全",
                        scripts
                            ? "脚本只能读取本网页所在文件夹，不能联网、不能弹窗；本地存储（如阅读进度）会保留"
                            : "JavaScript 已禁用，远程资源已阻止"),
                ])
        ]
    }
    var controls: AnyView? { AnyView(WebControls(r: self, labels: isSVG ? ["图像", "源码"] : ["网页", "源码"])) }
    var initialFirstResponder: NSView? { web }
    func supports(_ c: ViewerCommand) -> Bool { webSupports(c) }
    func perform(_ c: ViewerCommand) { webPerform(c) }
}
