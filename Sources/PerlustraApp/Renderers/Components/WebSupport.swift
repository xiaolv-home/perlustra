import AppKit
import CryptoKit
import WebKit
import UniformTypeIdentifiers
import PerlustraCore

enum AppResources {
    /// Bundled web assets: Contents/Resources/web in the app, or the source tree during development.
    static let webRoot: URL = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web"),
            FileManager.default.fileExists(atPath: r.appendingPathComponent("markdown.html").path)
        {
            return r
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/web")
    }()
}

/// Serves `perlustra://app/<path>` from the bundled web assets and `perlustra://file/<abs path>`
/// from disk, so pages never need file:// access and nothing ever touches the network.
final class PerlustraSchemeHandler: NSObject, WKURLSchemeHandler {
    static let maxResourceBytes = 128 << 20
    private var active = Set<ObjectIdentifier>()
    /// `perlustra://file/` only serves files inside this folder, after resolving symlinks.
    /// `nil` serves nothing (fail closed). Markdown and HTML always pass the document's folder.
    let fileRoot: URL?

    init(fileRoot: URL? = nil) {
        self.fileRoot = fileRoot?.standardizedFileURL
        super.init()
    }

    func allows(_ fileURL: URL) -> Bool {
        guard let root = fileRoot else { return false }
        return FileAccessPolicy.fileInsideRoot(fileURL, root: root) != nil
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let located = Self.resolve(url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let fileURL: URL
        if url.host == "file" {
            guard let root = fileRoot, let limited = FileAccessPolicy.fileInsideRoot(located, root: root) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            fileURL = limited
        } else {
            fileURL = located
        }
        let id = ObjectIdentifier(task)
        active.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let tooLarge = (rv?.fileSize ?? 0) > Self.maxResourceBytes
            let isReg = rv?.isRegularFile == true
            let data: Data? = (isReg && !tooLarge) ? (try? Data(contentsOf: fileURL, options: [.mappedIfSafe])) : nil
            DispatchQueue.main.async {
                guard self.active.remove(id) != nil else { return }
                if tooLarge {
                    task.didFailWithError(URLError(.dataLengthExceedsMaximum))
                    return
                }
                guard let data else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let ext = fileURL.pathExtension.lowercased()
                var mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                if ext == "js" { mime = "text/javascript" }
                if ext == "md" || ext == "markdown" { mime = "text/plain" }
                var encoding: String?
                if mime.hasPrefix("text/") || mime.contains("xml") || mime.contains("javascript") {
                    let enc = TextEncodingDetector.detect(data.prefix(64 * 1024))
                    encoding = CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(enc.encoding.rawValue)) as String?
                }
                let resp = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: encoding)
                task.didReceive(resp)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    static func resolve(_ url: URL) -> URL? {
        let path = url.path.removingPercentEncoding ?? url.path
        switch url.host {
        case "app":
            return FileAccessPolicy.bundledFile(root: AppResources.webRoot, relativePath: sharedVendorPath(path))
        case "file":
            return URL(fileURLWithPath: path)
        default:
            return nil
        }
    }

    /// The Markdown writer (Vditor) asks for KaTeX, Mermaid and highlight.js under its own
    /// folder; the copies Perlustra already ships (newer, same APIs) serve those requests.
    static func sharedVendorPath(_ path: String) -> String {
        let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let prefix = "vditor/dist/js/"
        guard p.hasPrefix(prefix) else { return path }
        let rest = String(p.dropFirst(prefix.count))
        switch rest {
        case "mermaid/mermaid.min.js": return "vendor/mermaid.min.js"
        case "highlight.js/highlight.min.js": return "vendor/highlight.min.js"
        case "katex/katex.min.js", "katex/katex.min.css": return "vendor/" + rest
        default: return rest.hasPrefix("katex/fonts/") ? "vendor/" + rest : path
        }
    }

    static func url(forFile file: URL) -> URL {
        var c = URLComponents()
        c.scheme = "perlustra"
        c.host = "file"
        c.path = file.path
        return c.url!
    }
}

/// Web view that never accepts drops (the window handles them) and never opens new windows.
final class PerlustraWebView: WKWebView {
    /// The Markdown writer takes pictures dropped into the text; every other page leaves drops
    /// to the window (which opens the file).
    var acceptsFileDrops = false {
        didSet { if acceptsFileDrops { registerForDraggedTypes([.fileURL, .png, .tiff, .string, .html]) } }
    }
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        if acceptsFileDrops { super.registerForDraggedTypes(newTypes) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFileDrops ? super.draggingEntered(sender) : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsFileDrops ? super.performDragOperation(sender) : false
    }
}

@MainActor
enum WebFactory {
    private static var ruleList: WKContentRuleList?

    /// Blocks every remote load. Compiled once and cached by WebKit.
    /// A failed compile is not cached: the page must not load without the rules.
    static func blockRemoteRules() async throws -> WKContentRuleList {
        if let r = ruleList { return r }
        let json =
            #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
        let list: WKContentRuleList? = await withCheckedContinuation { cont in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "perlustra-block-remote-v2", encodedContentRuleList: json) { list, error in
                if error != nil { cont.resume(returning: nil) } else { cont.resume(returning: list) }
            }
        }
        guard let list else { throw RenderError.unreadable("无法启用网页断网规则，已停止显示此页面") }
        ruleList = list
        return list
    }

    /// Deterministic per-folder store identifier so each local web folder keeps its own
    /// reading progress without exposing `localStorage` across unrelated folders (such as Downloads).
    static func storeIdentifier(forFolder folder: URL) -> UUID {
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var bytes = Array(SHA256.hash(data: Data(("perlustra-web-store:" + canonical).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    /// `fileRoot` limits which local files the page may load; `keepsData` keeps that folder's
    /// localStorage / IndexedDB between launches, isolated per folder.
    static func make(javaScript: Bool, fileRoot: URL? = nil, keepsData: Bool = false) async throws -> PerlustraWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(PerlustraSchemeHandler(fileRoot: fileRoot), forURLScheme: "perlustra")
        if keepsData, let root = fileRoot {
            cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeIdentifier(forFolder: root))
        } else {
            cfg.websiteDataStore = .nonPersistent()
        }
        cfg.defaultWebpagePreferences.allowsContentJavaScript = javaScript
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.preferences.isFraudulentWebsiteWarningEnabled = false
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        let rules = try await blockRemoteRules()
        cfg.userContentController.add(rules)
        let wv = PerlustraWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        wv.allowsMagnification = true
        wv.allowsBackForwardNavigationGestures = false
        keepPainting(wv)
        return wv
    }

    /// A covered window stops painting web pages, which would leave automated screenshots blank.
    static func keepPainting(_ view: WKWebView) {
        #if DEBUG
            let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if AppEnvironment.isScripted, view.responds(to: selector) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(view.method(for: selector), to: Setter.self)(view, selector, false)
            }
        #endif
    }
}

/// Navigation policy shared by Markdown and HTML: only the initial page loads; links are
/// confined to `fileRoot` unless the user explicitly confirms opening an external target.
@MainActor
final class WebNavigator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var host: RenderHost?
    var onFinish: (() -> Void)?
    var onFail: ((Error) -> Void)?
    /// Confines local file links to the document's own folder (symlinks resolved).
    var fileRoot: URL?
    /// A local web app's folder: its own HTML pages open in place instead of as separate tabs.
    var siteRoot: URL?

    private func isSitePage(_ url: URL) -> Bool {
        guard let root = siteRoot, url.scheme == "perlustra", url.host == "file",
            let f = PerlustraSchemeHandler.resolve(url),
            let resolved = FileAccessPolicy.fileInsideRoot(f, root: root)
        else { return false }
        return ["html", "htm", "xhtml"].contains(resolved.pathExtension.lowercased())
            && resolved.path != root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func openLocalLink(_ target: URL) {
        if let root = fileRoot, let inside = FileAccessPolicy.fileInsideRoot(target, root: root) {
            host?.open(inside)
            return
        }
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        host?.showNotice(
            "链接指向所在文件夹外的文件：\(target.path)",
            style: .info,
            action: NoticeAction(title: "打开") { [weak host] in host?.open(target) }
        )
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        guard action.navigationType == .linkActivated else {
            let scheme = url.scheme?.lowercased() ?? ""
            decisionHandler(["perlustra", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
            return
        }
        if isSitePage(url) {
            decisionHandler(.allow)
            return
        }
        // In-page anchors.
        if let cur = webView.url, url.fragment != nil, url.absoluteString.hasPrefix(cur.absoluteString.components(separatedBy: "#")[0]) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if url.scheme == "perlustra", url.host == "file", let f = PerlustraSchemeHandler.resolve(url) {
            openLocalLink(f)
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            host?.showNotice(
                "链接不会自动打开：\(url.absoluteString)", style: .info,
                action: NoticeAction(title: "在浏览器中打开") { NSWorkspace.shared.open(url) })
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?(); onFinish = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFail?(error); onFail = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFail?(error); onFail = nil }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if isSitePage(url), navigationAction.navigationType == .linkActivated || navigationAction.sourceFrame.isMainFrame {
            webView.load(URLRequest(url: url))
            return nil
        }
        // Opening files or offering external URLs always requires an explicit user click.
        guard navigationAction.navigationType == .linkActivated else { return nil }
        if url.scheme == "perlustra", url.host == "file", let f = PerlustraSchemeHandler.resolve(url) {
            openLocalLink(f)
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            host?.showNotice(
                "链接不会自动打开：\(url.absoluteString)", style: .info,
                action: NoticeAction(title: "在浏览器中打开") { NSWorkspace.shared.open(url) })
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        host?.showNotice("网页内容进程意外退出，已停止显示。", style: .warning, action: nil)
    }

    /// Loads and waits until the page finished (or failed / timed out).
    func load(_ wv: WKWebView, _ start: () -> Void, timeout: Double = 15) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            onFinish = { if !done { done = true; cont.resume() } }
            onFail = { e in if !done { done = true; cont.resume(throwing: e) } }
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !done { done = true; cont.resume(throwing: RenderError.unreadable("网页载入超时")) }
            }
        }
    }
}
