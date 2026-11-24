import AppKit
import PerlustraCore

/// The sidebar's file actions: they keep the open tabs in step with what happens on disk.
extension ViewerWindowController {
    /// Tabs showing this file, or files inside this folder.
    private func tabs(under url: URL) -> [ViewerModel] {
        let path = url.standardizedFileURL.path
        return tabs.docs.filter { doc in
            guard let open = doc.file?.url.standardizedFileURL.path else { return false }
            return open == path || open.hasPrefix(path + "/")
        }
    }

    private func refuseIfUnsaved(_ url: URL) -> Bool {
        guard let dirty = tabs(under: url).first(where: { $0.renderer?.hasUnsavedChanges == true }) else { return false }
        select(dirty)
        present(message: "「\(dirty.file?.name ?? url.lastPathComponent)」有没保存的改动", detail: "先保存或放弃改动，再做这个操作。")
        return true
    }

    private func present(message: String, detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    func trashFromSidebar(_ url: URL, isFolder: Bool) {
        guard !refuseIfUnsaved(url), let window else { return }
        guard isFolder else {
            performTrash(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "把文件夹「\(url.lastPathComponent)」移到废纸篓？"
        alert.informativeText = "里面的所有内容都会一起移走，可以从废纸篓放回来。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.performTrash(url) }
        }
    }

    func performTrash(_ url: URL) {
        // Found before the move: a path can't be resolved the same way once nothing is there.
        let affected = tabs(under: url)
        let reopen = affected.compactMap { $0.file?.url }
        do {
            let inTrash = try FileOperations.moveToTrash(url)
            for doc in affected { closeTab(doc) }
            browser.reload()
            model.showNotice(
                "「\(url.lastPathComponent)」已移到废纸篓", style: .info,
                action: NoticeAction(title: "撤销") { [weak self] in self?.restore(from: inTrash, to: url, reopening: reopen) })
        } catch {
            present(message: "没能移到废纸篓", detail: error.localizedDescription)
        }
    }

    private func restore(from inTrash: URL, to url: URL, reopening: [URL]) {
        do {
            try FileManager.default.moveItem(at: inTrash, to: url)
            browser.reload()
            model.notice = nil
            for file in reopening { _ = addTab(file) }
        } catch {
            present(message: "没能放回去", detail: error.localizedDescription)
        }
    }

    func renameFromSidebar(_ url: URL) {
        guard !refuseIfUnsaved(url), let window else { return }
        let alert = NSAlert()
        alert.messageText = "重命名"
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performRename(url, to: field.stringValue)
        }
        alert.window.initialFirstResponder = field
        // The name without its extension is selected, as in Finder.
        DispatchQueue.main.async {
            let stem = (url.lastPathComponent as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        }
    }

    func performRename(_ url: URL, to name: String) {
        do {
            let affected = tabs(under: url)
            let target = try FileOperations.rename(url, to: name)
            let oldPath = url.standardizedFileURL.path
            for doc in affected {
                guard let open = doc.file?.url.standardizedFileURL.path else { continue }
                doc.open(URL(fileURLWithPath: target.path + open.dropFirst(oldPath.count)))
            }
            browser.reload()
        } catch {
            present(message: "没能重命名", detail: error.localizedDescription)
        }
    }

    func duplicateFromSidebar(_ url: URL) {
        do {
            _ = try FileOperations.duplicate(url)
            browser.reload()
        } catch {
            present(message: "没能创建副本", detail: error.localizedDescription)
        }
    }

    func newFolderFromSidebar() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "新建文件夹"
        let field = NSTextField(string: "未命名文件夹")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "新建")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                _ = try self.browser.createFolder(named: field.stringValue)
            } catch {
                self.present(message: "没能新建文件夹", detail: error.localizedDescription)
            }
        }
        alert.window.initialFirstResponder = field
    }

    func compressFromSidebar(_ url: URL, format: ArchiveOutputFormat) {
        let dest = ArchiveWriter.suggestedArchiveURL(for: [url], format: format)
        var task: Task<Void, Never>?
        task = Task { [weak self] in
            guard let self else { return }
            self.model.showNotice(
                "正在压缩「\(url.lastPathComponent)」…",
                style: .info,
                action: NoticeAction(title: "取消") { task?.cancel() }
            )
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ArchiveWriter.compress(
                        items: [url],
                        to: dest,
                        options: ArchiveCompressOptions(format: format),
                        isCancelled: { Task.isCancelled }
                    )
                }.value
                self.browser.reload()
                self.model.showNotice(
                    "已生成「\(result.archiveURL.lastPathComponent)」（\(Fmt.bytes(result.archiveBytes))）",
                    style: .success,
                    action: NoticeAction(title: "在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.archiveURL])
                    }
                )
            } catch ArchiveOperationError.cancelled {
                self.model.showNotice("已取消压缩", style: .info, action: nil)
            } catch {
                self.model.showNotice(
                    (error as? LocalizedError)?.errorDescription ?? "压缩失败：\(error.localizedDescription)",
                    style: .warning,
                    action: nil
                )
            }
        }
    }

    func extractFromSidebar(_ url: URL) {
        let destFolder = url.deletingLastPathComponent()
        var task: Task<Void, Never>?
        task = Task { [weak self] in
            guard let self else { return }
            self.model.showNotice(
                "正在解压「\(url.lastPathComponent)」…",
                style: .info,
                action: NoticeAction(title: "取消") { task?.cancel() }
            )
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ArchiveExtractor.extract(
                        archiveURL: url,
                        to: destFolder,
                        options: ArchiveExtractOptions(smartWrap: true),
                        isCancelled: { Task.isCancelled }
                    )
                }.value
                self.browser.reload()
                var msg = "已解压 \(Fmt.number(result.extractedFiles)) 个文件（\(Fmt.bytes(result.totalBytes))）"
                if result.skippedUnsafe > 0 { msg += "，拦截 \(result.skippedUnsafe) 个不安全路径" }
                if result.skippedEncrypted > 0 { msg += "，跳过 \(result.skippedEncrypted) 个加密项" }
                self.model.showNotice(
                    msg,
                    style: result.skippedUnsafe > 0 || result.skippedEncrypted > 0 ? .warning : .success,
                    action: NoticeAction(title: "在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                    }
                )
            } catch ArchiveOperationError.cancelled {
                self.model.showNotice("已取消解压", style: .info, action: nil)
            } catch {
                self.model.showNotice(
                    (error as? LocalizedError)?.errorDescription ?? "解压失败：\(error.localizedDescription)",
                    style: .warning,
                    action: nil
                )
            }
        }
    }
}
