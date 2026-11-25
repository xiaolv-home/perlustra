import AppKit
import WebKit
import PerlustraCore

/// The Typora-style Markdown editor: Vditor in instant-render mode inside a web view, with a
/// bridge for text changes, pictures pasted into ./assets and the app's commands.
@MainActor
final class MarkdownWriter: NSObject {
    let webView: PerlustraWebView
    /// Latest text the editor reported (a moment behind typing; `value()` is exact).
    private(set) var text: String
    var onChange: ((String) -> Void)?
    var onToggleSource: (() -> Void)?
    var onLink: ((String) -> Void)?
    var onSelection: ((Int) -> Void)?
    var onToggleMode: ((String) -> Void)?
    /// Folder pasted pictures are saved under (as assets/…), normally the document's.
    var documentFolder: URL
    private var bridge: WriterBridge?
    private var ready: CheckedContinuation<Void, Never>?

    /// "ir" writes Typora-style; "sv" is plain Markdown source.
    enum Mode: String { case write = "ir", source = "sv" }

    private init(webView: PerlustraWebView, text: String, folder: URL) {
        self.webView = webView
        self.text = text
        self.documentFolder = folder
    }

    static func make(text: String, folder: URL, mode: Mode, outline: Bool, navigator: WebNavigator) async throws -> MarkdownWriter {
        let wv = try await WebFactory.make(javaScript: true, fileRoot: folder)
        wv.acceptsFileDrops = true
        let w = MarkdownWriter(webView: wv, text: text, folder: folder)
        let b = WriterBridge(writer: w)
        w.bridge = b
        wv.configuration.userContentController.addScriptMessageHandler(b, contentWorld: .page, name: "writer")
        wv.navigationDelegate = navigator
        wv.uiDelegate = navigator
        let template = AppResources.webRoot.appendingPathComponent("writer.html")
        guard let html = try? String(contentsOf: template, encoding: .utf8) else { throw RenderError.unsupported("缺少写作模板资源") }
        // Relative pictures (assets/…) resolve against the document's folder.
        let base = PerlustraSchemeHandler.url(forFile: folder).appendingPathComponent("/")
        try await navigator.load(wv) { wv.loadHTMLString(html, baseURL: base) }
        try await w.start(mode: mode, outline: outline)
        return w
    }

    private func start(mode: Mode, outline: Bool) async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ready = c
            call("perlustraWriter.load(\(Self.js(text)), '\(mode.rawValue)', \(outline))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.markReady() }
        }
    }

    fileprivate func markReady() {
        ready?.resume()
        ready = nil
    }

    // MARK: Commands

    /// The exact text now (waits for the editor).
    func value() async -> String {
        if let s = try? await webView.evaluateJavaScript("perlustraWriter.value()") as? String { text = s }
        return text
    }

    func setValue(_ markdown: String) {
        text = markdown
        call("perlustraWriter.setValue(\(Self.js(markdown)))")
    }

    func insert(_ markdown: String) { call("perlustraWriter.insert(\(Self.js(markdown)))") }
    func command(_ name: String) { call("perlustraWriter.command('\(name)')") }
    func setModes(focus: Bool, typewriter: Bool) { call("perlustraWriter.setModes(\(focus), \(typewriter))") }
    func focus() {
        webView.window?.makeFirstResponder(webView)
        call("perlustraWriter.focus()")
    }

    /// Rebuilds the editor in another mode, keeping the text.
    func setMode(_ mode: Mode, outline: Bool) async {
        _ = await value()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ready = c
            call("perlustraWriter.setMode('\(mode.rawValue)', \(outline))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.markReady() }
        }
    }

    func teardown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "writer", contentWorld: .page)
        bridge = nil
        markReady()
    }

    private func call(_ js: String) { webView.evaluateJavaScript(js, completionHandler: nil) }

    static func js(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self) + "[0]"
    }

    // MARK: Messages from the page

    fileprivate func received(_ body: [String: Any]) async -> Any? {
        switch body["type"] as? String {
        case "ready": markReady()
        case "change":
            if let s = body["markdown"] as? String, s != text {
                text = s
                onChange?(s)
            }
        case "toggleSource": onToggleSource?()
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
        case "link": if let h = body["href"] as? String { onLink?(h) }
        case "selection": onSelection?(body["chars"] as? Int ?? 0)
        case "toggleMode": if let name = body["name"] as? String { onToggleMode?(name) }
        case "pickImage": pickImages()
        case "image":
            guard let name = body["name"] as? String, let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else { return nil }
            return savePicture(data, name: name)
        default: break
        }
        return nil
    }

    /// ⌃⌘I: pictures from disk are copied into assets/ and linked, as pasted ones are.
    private func pickImages() {
        guard let window = webView.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url), let path = self.savePicture(data, name: url.lastPathComponent) else { continue }
                let link = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                self.insert("![\(url.deletingPathExtension().lastPathComponent)](\(link))")
            }
            self.focus()
        }
    }

    /// Saves a pasted picture as assets/<name> beside the document (a free name if taken) and
    /// returns the relative path to link.
    private func savePicture(_ data: Data, name: String) -> String? {
        let fm = FileManager.default
        let folder = documentFolder.appendingPathComponent("assets", isDirectory: true)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        var base = (name as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "-")
        var ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty { ext = "png" }
        // Screenshots arrive as "image.png": name them by time instead.
        if base.isEmpty || base == "image" {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            base = "图片-" + f.string(from: Date())
        }
        var url = folder.appendingPathComponent(base + "." + ext)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        guard (try? data.write(to: url)) != nil else { return nil }
        return "assets/" + url.lastPathComponent
    }
}

/// Find and replace inside the editor (the browser's own find can't replace).
extension MarkdownWriter: WebFindDriver {
    private func numbers(_ js: String) async -> (Int, Int) {
        let r = try? await webView.evaluateJavaScript(js) as? [Int]
        return (r?.first ?? 0, r?.last ?? 0)
    }
    func search(_ query: String, step: Int) async -> (current: Int, total: Int) {
        await numbers("perlustraWriter.find(\(Self.js(query)), \(step))")
    }
    func replaceCurrent(_ query: String, with replacement: String) async -> (current: Int, total: Int) {
        await numbers("perlustraWriter.replaceCurrent(\(Self.js(query)), \(Self.js(replacement)))")
    }
    func replaceAll(_ query: String, with replacement: String) async -> Int {
        (try? await webView.evaluateJavaScript("perlustraWriter.replaceAll(\(Self.js(query)), \(Self.js(replacement)))") as? Int) ?? 0
    }
    func endSearch() { webView.evaluateJavaScript("perlustraWriter.endSearch()", completionHandler: nil) }
}

/// Receives the page's messages (held weakly, so the editor can go away).
private final class WriterBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var writer: MarkdownWriter?
    init(writer: MarkdownWriter) { self.writer = writer }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any] else { replyHandler(nil, nil); return }
        _ = MainActor.assumeIsolated {
            Task { @MainActor [weak self] in
                let reply = await self?.writer?.received(body)
                replyHandler(reply, nil)
            }
        }
    }
}
