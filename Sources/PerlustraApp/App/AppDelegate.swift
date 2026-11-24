import AppKit
import SwiftUI
import PerlustraCore

@MainActor
final class AppDelegate: NSObject, AppActions, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    private(set) var windows: [ViewerWindowController] = []
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false
    private var keyMonitor: Any?
    private var settingsWindow: NSWindow?
    private var shortcutsWindow: NSWindow?
    let automation = AppAutomation()

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Perlustra restores its window frame itself; AppKit's state restoration would only add a
        // "reopen windows?" modal after a crash or forced quit.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        NSApp.mainMenu = MainMenu.build(delegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        AppSettings.shared.applyAppearance()
        if ProcessInfo.processInfo.environment["PERLUSTRA_TIMING"] != nil {
            // Time from process start to the first window on screen.
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            sysctl(&mib, 4, &info, &size, nil, 0)
            let start = Double(info.kp_proc.p_starttime.tv_sec) + Double(info.kp_proc.p_starttime.tv_usec) / 1e6
            DispatchQueue.main.async {
                print(String(format: "launch-to-window: %.0f ms", (Date().timeIntervalSince1970 - start) * 1000))
                exit(0)
            }
        }
        installKeyMonitor()
        // Maintenance: `--purge-recents <folder>` drops recent files under a folder (e.g. test
        // fixtures opened by mistake) from both recent lists, then quits.
        if let i = CommandLine.arguments.firstIndex(of: "--purge-recents"), i + 1 < CommandLine.arguments.count {
            RecentFiles.purge(under: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        let cli = automation.parse(CommandLine.arguments)
        let urls = pendingURLs + cli
        pendingURLs = []
        if automation.isActive {
            AppEnvironment.isScripted = true
            automation.run(urls: urls, app: self)
            return
        }
        if urls.isEmpty {
            _ = newWindow()?.showWindow(nil)
        } else {
            openURLs(urls, preferredWindow: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !didFinishLaunching { pendingURLs += urls; return }
        openURLs(urls, preferredWindow: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow()?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Walks windows with unsaved edits one by one before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pending = windows.flatMap { wc in wc.allDocuments.filter { $0.renderer?.hasUnsavedChanges == true }.map { (wc, $0) } }
        guard !pending.isEmpty else { return .terminateNow }
        func next(_ i: Int) {
            guard i < pending.count else { NSApp.reply(toApplicationShouldTerminate: true); return }
            let (wc, doc) = pending[i]
            wc.window?.makeKeyAndOrderFront(nil)
            wc.select(doc)
            doc.confirmLeaving { ok in
                if ok { next(i + 1) } else { NSApp.reply(toApplicationShouldTerminate: false) }
            }
        }
        next(0)
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        ArchivePreviewCache.shared.cleanupAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }

    // MARK: Windows

    @discardableResult
    func newWindow() -> ViewerWindowController? {
        let wc = ViewerWindowController(autosave: windows.isEmpty)
        if let last = windows.last?.window, let w = wc.window {
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        wc.onClose = { [weak self] c in self?.windows.removeAll { $0 === c } }
        windows.append(wc)
        return wc
    }

    /// An empty tab in `host` (or a new window when there is none).
    @discardableResult
    func newTab(from host: ViewerWindowController?) -> ViewerWindowController? {
        guard let host else { return newWindow() }
        host.addTab(nil)
        return host
    }

    /// Opens a file in a tab: switches to it if it is open already, uses the current tab when
    /// that is the home page, otherwise adds a tab beside it.
    func openInTab(_ url: URL, from host: ViewerWindowController?) {
        let url = url.standardizedFileURL
        for wc in windows {
            if let doc = wc.document(for: url) {
                wc.window?.makeKeyAndOrderFront(nil)
                wc.select(doc)
                return
            }
        }
        guard let host = host ?? (NSApp.keyWindow?.windowController as? ViewerWindowController) ?? windows.first ?? newWindow() else { return }
        if host.model.file == nil, host.model.renderer == nil {
            host.open(url)
        } else {
            host.addTab(url)
            host.showWindow(nil)
        }
    }

    /// Opens files as tabs (default) or as separate windows.
    func openURLs(_ urls: [URL], preferredWindow: ViewerWindowController?) {
        guard !urls.isEmpty else { return }
        if AppSettings.shared.singleWindow {
            for u in urls { openInTab(u, from: preferredWindow) }
        } else {
            for (i, u) in urls.enumerated() {
                // Reuse an empty window (e.g. the launch window) for the first file.
                if i == 0, let empty = windows.first(where: { $0.model.file == nil }) {
                    empty.open(u)
                } else if i == 0, let pw = preferredWindow, preferredWindow?.model.file == nil {
                    pw.open(u)
                } else {
                    newWindow()?.open(u)
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu actions

    @objc func showOpenPanel(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.treatsFilePackagesAsDirectories = false
        p.message = "选择要查看的文件"
        p.prompt = "打开"
        let target = NSApp.keyWindow?.windowController as? ViewerWindowController
        if p.runModal() == .OK { openURLs(p.urls, preferredWindow: target) }
    }

    /// ⌘N: a new Markdown document (a draft until its first save), in a new tab.
    @objc func newMarkdownDocument(_ sender: Any?) {
        guard let url = try? MarkdownDrafts.create() else { return }
        openDraft(url)
    }

    /// 模版库: choosing a template starts a new document from it.
    @objc func showTemplates(_ sender: Any?) {
        TemplatesWindow.show { [weak self] template in
            guard let url = try? MarkdownDrafts.create(named: template.title.replacingOccurrences(of: "/", with: "-"), content: template.document()) else {
                return
            }
            self?.openDraft(url)
        }
    }

    private func openDraft(_ url: URL) {
        if let wc = NSApp.keyWindow?.windowController as? ViewerWindowController ?? windows.first {
            wc.showWindow(nil)
            if wc.tabs.docs.count == 1 && wc.model.file == nil { wc.open(url) } else { wc.addTab(url) }
        } else {
            newWindow()?.open(url)
        }
    }

    @objc func newViewerWindow(_ sender: Any?) {
        newWindow()?.showWindow(nil)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        openURLs([u], preferredWindow: NSApp.keyWindow?.windowController as? ViewerWindowController)
    }

    @objc func clearRecent(_ sender: Any?) { RecentFiles.clear() }

    /// Opens 设置 on its AI tab.
    static func showAISettings() {
        UserDefaults.standard.set("ai", forKey: SettingsRoot.tabKey)
        (NSApp.delegate as? AppDelegate)?.showSettings(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsRoot()))
            w.title = "设置"
            w.backgroundColor = Theme.surface
            w.titlebarAppearsTransparent = true
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
            w.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showShortcuts(_ sender: Any?) {
        if shortcutsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ShortcutsView()))
            w.title = "键盘快捷键"
            w.backgroundColor = Theme.surface
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            shortcutsWindow = w
            w.center()
        }
        shortcutsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Perlustra",
            .credits: NSAttributedString(
                string: "轻量、离线、原生的万能文件查看器。\n不联网、不执行文档脚本。",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let a = AppAppearance(rawValue: raw) { AppSettings.shared.appearance = a }
    }

    // Open Recent and 外观 submenus are rebuilt each time they open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier?.rawValue == "appearance" {
            menu.removeAllItems()
            for a in AppAppearance.allCases {
                let item = NSMenuItem(title: a.title, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
                item.representedObject = a.rawValue
                item.target = self
                item.state = AppSettings.shared.appearance == a ? .on : .off
                menu.addItem(item)
            }
            return
        }
        guard menu.identifier?.rawValue == "recent" else { return }
        menu.removeAllItems()
        let urls = RecentFiles.all().prefix(15)
        for u in urls {
            let item = NSMenuItem(title: u.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = u
            item.target = self
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.toolTip = u.path
            menu.addItem(item)
        }
        if urls.isEmpty {
            let none = NSMenuItem(title: "无最近项目", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "清除菜单", action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    // MARK: Keyboard

    /// ←/→ switch files and space toggles playback, unless a text field has focus
    /// or the renderer wants those keys itself.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let wc = e.window?.windowController as? ViewerWindowController else { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            // ⌃Tab / ⌃⇧Tab switch tabs, like a browser.
            if e.keyCode == 48 && mods.contains(.control) {
                wc.cycleTab(mods.contains(.shift) ? -1 : 1)
                return nil
            }
            guard mods.isEmpty else { return e }
            // The sidebar list handles its own arrows (← up a folder, → into one).
            if e.window?.firstResponder is NSTableView { return e }
            if let fr = e.window?.firstResponder as? NSTextView, fr.isEditable || fr.isFieldEditor { return e }
            if e.window?.firstResponder is NSTextField { return e }
            let r = wc.model.renderer
            switch e.keyCode {
            case 123, 124:  // ← →
                if r?.wantsArrowKeys == true { return e }
                wc.model.navigate(e.keyCode == 123 ? -1 : 1)
                return nil
            case 49:  // space
                if r?.wantsSpaceKey == true { wc.model.perform(.playPause); return nil }
                return e
            default:
                _ = self
                return e
            }
        }
    }
}
