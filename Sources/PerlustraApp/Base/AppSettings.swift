import Foundation
import SwiftUI
import AppKit

/// Centralised locations for Perlustra's support and cache folders.
enum AppPaths {
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perlustra", isDirectory: true)
    }

    /// Kept under `app.loupe.viewer` so cached iWork PDF exports survive the rename without re-exporting.
    static var exportsCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.loupe.viewer/exports", isDirectory: true)
    }
}

/// Set when the debug harness drives the app (tests, screenshots): it then leaves no trace in
/// the user's history — no recent files, remembered folder, window size or sidebar layout.
enum AppEnvironment {
    @MainActor static var isScripted = false
}

/// What the whole app looks like. 黑色 is the app's dark palette, whichever way it is chosen.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, black
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .black: return "黑色"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .black: return NSAppearance(named: .darkAqua)
        }
    }
}

/// User preferences backed by UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var singleWindow: Bool { didSet { d.set(singleWindow, forKey: "singleWindow") } }
    @Published var showSidebar: Bool { didSet { d.set(showSidebar, forKey: "showSidebar") } }
    @Published var iworkExport: Bool { didSet { d.set(iworkExport, forKey: "iworkExport") } }
    @Published var mpvPath: String { didSet { d.set(mpvPath, forKey: "mpvPath") } }
    @Published var preferMPV: Bool { didSet { d.set(preferMPV, forKey: "preferMPV") } }
    @Published var wrapText: Bool { didSet { d.set(wrapText, forKey: "wrapText") } }
    @Published var imageStartsActualSize: Bool { didSet { d.set(imageStartsActualSize, forKey: "imageStartsActualSize") } }
    @Published var highlightLimitMB: Double { didSet { d.set(highlightLimitMB, forKey: "highlightLimitMB") } }
    @Published var showHiddenSiblings: Bool { didSet { d.set(showHiddenSiblings, forKey: "showHiddenSiblings") } }
    @Published var spreadsheetOpensOriginal: Bool { didSet { d.set(spreadsheetOpensOriginal, forKey: "spreadsheetOpensOriginal") } }
    /// Tables are for looking and calculating; changing cells is opt-in.
    @Published var spreadsheetEditing: Bool { didSet { d.set(spreadsheetEditing, forKey: "spreadsheetEditing") } }
    /// Local web pages (offline readers, exported reports) run their own scripts — confined to
    /// their folder, with every network request blocked.
    @Published var webPagesRunScripts: Bool { didSet { d.set(webPagesRunScripts, forKey: "webPagesRunScripts") } }
    /// Markdown opens in the Typora-style writer (otherwise as a typeset page to read).
    @Published var appearance: AppAppearance {
        didSet {
            if !AppEnvironment.isScripted { d.set(appearance.rawValue, forKey: "appearance") }
            applyAppearance()
        }
    }
    /// Markdown files save themselves a moment after each change.
    @Published var markdownAutosave: Bool { didSet { d.set(markdownAutosave, forKey: "markdownAutosave") } }
    /// 专注模式: everything but the paragraph being written fades back.
    @Published var writerFocus: Bool { didSet { if !AppEnvironment.isScripted { d.set(writerFocus, forKey: "writerFocus") } } }
    /// 打字机模式: the line being written stays in the middle of the window.
    @Published var writerTypewriter: Bool { didSet { if !AppEnvironment.isScripted { d.set(writerTypewriter, forKey: "writerTypewriter") } } }

    private init() {
        d.register(defaults: [
            "singleWindow": true, "showSidebar": false, "iworkExport": true, "mpvPath": "",
            "preferMPV": false, "wrapText": true, "imageStartsActualSize": false,
            "highlightLimitMB": 2.0, "showHiddenSiblings": false, "spreadsheetOpensOriginal": false, "spreadsheetEditing": false, "webPagesRunScripts": true,
            "markdownAutosave": false, "writerFocus": false, "writerTypewriter": false,
        ])
        singleWindow = d.bool(forKey: "singleWindow")
        showSidebar = d.bool(forKey: "showSidebar")
        iworkExport = d.bool(forKey: "iworkExport")
        mpvPath = d.string(forKey: "mpvPath") ?? ""
        preferMPV = d.bool(forKey: "preferMPV")
        wrapText = d.bool(forKey: "wrapText")
        imageStartsActualSize = d.bool(forKey: "imageStartsActualSize")
        highlightLimitMB = d.double(forKey: "highlightLimitMB")
        showHiddenSiblings = d.bool(forKey: "showHiddenSiblings")
        spreadsheetOpensOriginal = d.bool(forKey: "spreadsheetOpensOriginal")
        spreadsheetEditing = d.bool(forKey: "spreadsheetEditing")
        webPagesRunScripts = d.bool(forKey: "webPagesRunScripts")
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        markdownAutosave = d.bool(forKey: "markdownAutosave")
        writerFocus = d.bool(forKey: "writerFocus")
        writerTypewriter = d.bool(forKey: "writerTypewriter")
    }

    func applyAppearance() { NSApp.appearance = appearance.nsAppearance }

    var highlightLimitBytes: Int { Int(highlightLimitMB * 1024 * 1024) }
}
