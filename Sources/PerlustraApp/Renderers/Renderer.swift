import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PerlustraCore

/// Everything a renderer needs to know about the file being shown. Built off the main thread.
final class FileContext: @unchecked Sendable {
    let url: URL
    let format: DetectedFormat
    let size: Int64
    let created: Date?
    let modified: Date?
    let isDirectory: Bool
    let utType: UTType?
    let head: Data

    init(url: URL) {
        self.url = url
        let rv = try? url.resourceValues(forKeys: [
            .fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey,
            .contentModificationDateKey, .isDirectoryKey, .contentTypeKey,
        ])
        isDirectory = rv?.isDirectory ?? false
        size = Int64(isDirectory ? FileContext.directorySize(url) : (rv?.fileSize ?? 0))
        created = rv?.creationDate
        modified = rv?.contentModificationDate
        utType = rv?.contentType
        head = isDirectory ? Data() : FormatDetector.readHead(url, length: FormatDetector.headLength)
        format = FormatDetector.detect(url: url)
    }

    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var looksLikeText: Bool { !isDirectory && TextSniffer.isLikelyText(head) }

    /// Shallow size for packages (iWork bundles); bounded so huge folders do not stall.
    static func directorySize(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0, n = 0
        for case let f as URL in e {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            n += 1
            if n > 5000 { break }
        }
        return total
    }
}

struct InfoItem: Identifiable, Hashable {
    let id = UUID()
    var label: String
    var value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

struct InfoSection: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var items: [InfoItem]
    init(_ title: String, _ items: [InfoItem]) { self.title = title; self.items = items }

    /// Equal apart from the identities, which differ each time sections are built.
    static func sameContent(_ a: [InfoSection], _ b: [InfoSection]) -> Bool {
        a.count == b.count
            && zip(a, b).allSatisfy { x, y in
                x.title == y.title && x.items.count == y.items.count
                    && zip(x.items, y.items).allSatisfy { $0.label == $1.label && $0.value == $1.value }
            }
    }
}

enum ViewerCommand {
    case zoomIn, zoomOut, actualSize, zoomToFit
    case find, findNext, findPrevious
    case rotateLeft, rotateRight
    case toggleSource, toggleWrap
    case playPause, slideshow
    case copy
    case save, saveAs, exportCSV, exportXLSX
}

enum ControlsPlacement { case floating, strip, none }

/// How content sits on the stage: on a paper sheet with crop marks (documents),
/// or full-bleed (images, PDF pages, video — they are their own print).
enum StagePresentation { case sheet, bleed }

enum RenderError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .unreadable(let s): return s
        case .unsupported(let s): return s
        case .cancelled: return "已取消"
        }
    }
}

/// Services the window offers to renderers.
@MainActor
protocol RenderHost: AnyObject {
    var window: NSWindow? { get }
    /// Report progress for long loads. `nil` hides the indicator.
    func reportProgress(_ fraction: Double?, label: String?)
    /// Ask the window to try the next renderer in the chain (e.g. AVFoundation could not decode).
    func requestFallback(from renderer: Renderer, reason: String)
    /// Non-blocking banner.
    func showNotice(_ text: String, style: NoticeStyle, action: NoticeAction?)
    var notice: Notice? { get set }
    /// Re-read info/status/controls after the renderer changed them.
    func rendererDidUpdate()
    func open(_ url: URL)
}

struct Notice: Identifiable {
    let id = UUID()
    var text: String
    var style: NoticeStyle
    var action: NoticeAction?
}

enum NoticeStyle { case info, warning, success }

struct NoticeAction {
    var title: String
    var handler: () -> Void
}

/// A renderer turns one file into one view. Instances are single-use: created per file,
/// then `cleanup()` releases players, web views and caches before being dropped.
@MainActor
protocol Renderer: AnyObject {
    /// The history ⌘Z works through while this document shows, if it keeps one of its own.
    var documentUndoManager: UndoManager? { get }
    /// Short engine name shown in the status strip ("PDFKit", "ImageIO" …).
    static var engineName: String { get }
    static func canHandle(_ file: FileContext) -> Bool
    init()
    func makeView(for file: FileContext, host: RenderHost) async throws -> NSView
    func cleanup()

    var infoSections: [InfoSection] { get }
    /// One-line summary for the status strip ("1920 × 1080 · Display P3").
    var statusText: String { get }
    var controls: AnyView? { get }
    var controlsPlacement: ControlsPlacement { get }
    var presentation: StagePresentation { get }
    func supports(_ command: ViewerCommand) -> Bool
    func perform(_ command: ViewerCommand)
    /// When true, plain ←/→ go to the renderer instead of switching files.
    var wantsArrowKeys: Bool { get }
    /// When true, the space bar goes to the renderer (media play/pause).
    var wantsSpaceKey: Bool { get }
    /// Preferred first responder after installation.
    var initialFirstResponder: NSView? { get }
    /// True when the renderer holds edits that are not on disk yet.
    var hasUnsavedChanges: Bool { get }
    /// Saves; calls back with success (false also when the user cancelled a save panel).
    func saveChanges(completion: @escaping (Bool) -> Void)
    /// Another file is loading in its place; it stays on screen until that one is ready, so
    /// anything audible should stop now.
    func willBeReplaced()
    /// What to tell the user when this renderer took over because the usual one failed.
    func fallbackNote(for file: FileContext?, reason: String) -> FallbackNote
    /// What the AI panel offers to do with this document, when it knows better than the format does.
    var aiSuggestions: [String]? { get }
}

/// How a renderer explains having taken over, in plain words and without engine names.
struct FallbackNote {
    var message: String
    /// What is on screen is the raw content of a damaged file, so it needs explaining right away.
    var showsRawContent = false
}

/// A renderer whose document takes the 格式 menu's editing commands.
@MainActor
protocol FormatCommandHandling: AnyObject {
    func performFormatCommand(_ command: String)
    /// Whether a toggle in the menu shows as on.
    func isFormatCommandOn(_ command: String) -> Bool
    func showReplace()
}

/// App-wide actions, sent along the responder chain so that views need not know the app delegate.
@objc protocol AppActions {
    func showSettings(_ sender: Any?)
    func showOpenPanel(_ sender: Any?)
}

extension Renderer {
    var infoSections: [InfoSection] { [] }
    var statusText: String { "" }
    var controls: AnyView? { nil }
    var controlsPlacement: ControlsPlacement { .strip }
    var presentation: StagePresentation { .sheet }
    func supports(_ command: ViewerCommand) -> Bool { false }
    func perform(_ command: ViewerCommand) {}
    var wantsArrowKeys: Bool { false }
    var wantsSpaceKey: Bool { false }
    var initialFirstResponder: NSView? { nil }
    var engineName: String { Self.engineName }
    var documentUndoManager: UndoManager? { nil }
    var hasUnsavedChanges: Bool { false }
    func saveChanges(completion: @escaping (Bool) -> Void) { completion(true) }
    func willBeReplaced() {}
    func fallbackNote(for file: FileContext?, reason: String) -> FallbackNote {
        FallbackNote(message: "这个\(file?.format.label ?? "文件")用常规方式打不开，已换一种方式显示" + (reason.isEmpty ? "" : "（\(reason)）"))
    }
    var aiSuggestions: [String]? { nil }
}

#if DEBUG
    /// Renderers that the test automation can drive with `--cmd sheet:<verb>:<args>` and `--cmd dump`.
    @MainActor
    protocol DebugScriptable: AnyObject {
        func debugRun(verb: String, arg: String, window: NSWindow) async
        func debugDump() -> String
    }
#endif

/// Picks the ordered list of renderers to try for a file:
/// specialised → Quick Look → text (if it looks like text) → hex.
@MainActor
enum RendererRegistry {
    static func chain(for f: FileContext) -> [Renderer.Type] {
        var out: [Renderer.Type] = []
        let fam = f.format.family
        switch fam {
        case .pdf: out = [PDFRenderer.self]
        case .image: out = [ImageRenderer.self]
        case .svg: out = [ImageRenderer.self, HTMLRenderer.self]
        case .video, .audio:
            let preferMPV =
                MPVLibrary.isAvailable
                && (ExtensionTable.mpvPreferred.contains(f.ext)
                    || AppSettings.shared.preferMPV || f.format.token == "MKV" || f.format.token == "WEBM")
            out = preferMPV ? [MPVRenderer.self, MediaRenderer.self] : [MediaRenderer.self, MPVRenderer.self]
        case .text, .code: out = [TextRenderer.self]
        case .markdown: out = [MarkdownRenderer.self, TextRenderer.self]
        case .json: out = [JSONRenderer.self, TextRenderer.self]
        case .plist: out = [PlistRenderer.self, TextRenderer.self]
        case .csv: out = [SpreadsheetRenderer.self, CSVRenderer.self, TextRenderer.self]
        case .html: out = [HTMLRenderer.self, TextRenderer.self]
        case .font: out = [FontRenderer.self]
        case .archive: out = [ArchiveRenderer.self]
        case .sqlite: out = [SQLiteRenderer.self]
        case .parquet: out = [ParquetRenderer.self]
        case .iwork: out = f.format.iwork == .numbers ? [SpreadsheetRenderer.self, IWorkRenderer.self] : [IWorkRenderer.self]
        case .office: out = [SpreadsheetRenderer.self, OfficeRenderer.self]
        case .quicklook: out = [QuickLookRenderer.self]
        case .directory: out = [DirectoryRenderer.self]
        case .binary: out = []
        }
        out = out.filter { $0.canHandle(f) }
        let previewableBinary =
            fam == .binary && (f.utType.map { !$0.isDynamic && $0 != .data && $0.conforms(to: .content) && !$0.conforms(to: .text) } ?? false)
        if [.office, .iwork, .quicklook, .svg, .font].contains(fam) || previewableBinary {
            out.append(QuickLookRenderer.self)
        }
        if !f.isDirectory && f.looksLikeText && !out.contains(where: { $0 == TextRenderer.self }) {
            out.append(TextRenderer.self)
        }
        // Media that no player can decode gets the failure page, not a hex dump.
        if !f.isDirectory && fam != .video && fam != .audio { out.append(HexRenderer.self) }
        // De-duplicate while keeping order.
        var seen = Set<ObjectIdentifier>()
        return out.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

extension NSView {
    /// Breaks a retired renderer's view tree apart: every embedded panel drops its content
    /// (and with it the renderer), then the top-level children are removed. System views'
    /// internals are left alone — taking those apart can raise.
    func dismantleTree() {
        detachPanels()
        // A scroll view's clip view and scrollers must stay (AppKit raises otherwise).
        guard !(self is NSScrollView) else { return }
        for v in subviews { v.removeFromSuperview() }
    }

    private func detachPanels() {
        for v in subviews {
            (v as? RendererHostingView)?.detach()
            v.detachPanels()
        }
    }
}

/// Hosting view for SwiftUI panels that observe their renderer. SwiftUI keeps some hosting
/// views registered globally (tooltips from `.help`) even after they leave the window, which
/// would keep the renderer — and the whole file it shows — in memory; `detach()` drops the
/// content, and with it the renderer.
final class RendererHostingView: NSHostingView<AnyView> {
    convenience init<V: View>(_ content: V) {
        self.init(rootView: AnyView(content))
    }

    func detach() {
        rootView = AnyView(EmptyView())
        // Out of the window SwiftUI would keep the old view values until its next update,
        // and they still reference the renderer: run that update now.
        layoutSubtreeIfNeeded()
        displayIfNeeded()
    }
}
