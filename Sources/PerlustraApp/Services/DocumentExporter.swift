import AppKit
import SwiftUI
import Quartz
import PDFKit
import CryptoKit
import PerlustraCore

enum ExportError: LocalizedError {
    case notAuthorized
    case appMissing(String)
    case failed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "未获得「自动化」权限"
        case .appMissing(let a): return "未安装 \(a)"
        case .failed(let m): return m
        case .timeout: return "导出超时"
        }
    }
}

/// Converts iWork (and PowerPoint, via Keynote) documents to PDF by scripting the installed
/// iWork app in the background. Results are cached by path + size + modification date.
enum ExportFormat: String {
    case pdf, xlsx
}

enum DocumentExporter {
    static func appURL(_ kind: IWorkKind) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID)
    }

    static var cacheDir: URL {
        let dir = AppPaths.exportsCache
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(for url: URL, format: ExportFormat = .pdf) -> URL {
        let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .totalFileSizeKey])
        let stamp = "\(url.path)|\(rv?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(rv?.fileSize ?? rv?.totalFileSize ?? 0)"
        let hash = SHA256.hash(data: Data(stamp.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hash).\(format.rawValue)")
    }

    static func cached(_ url: URL, format: ExportFormat = .pdf) -> URL? {
        let c = cacheURL(for: url, format: format)
        guard FileManager.default.fileExists(atPath: c.path) else { return nil }
        if format == .pdf, PDFDocument(url: c) == nil { return nil }
        return c
    }

    static func script(kind: IWorkKind, src: String, out: String, quitAfter: Bool, format: ExportFormat = .pdf) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let exportLine: String
        switch (kind, format) {
        case (_, .xlsx): exportLine = "export theDoc to (POSIX file \(q(out))) as Microsoft Excel"
        case (.keynote, _): exportLine = "export theDoc to (POSIX file \(q(out))) as PDF with properties {PDF image quality:Best}"
        default: exportLine = "export theDoc to (POSIX file \(q(out))) as PDF"
        }
        return """
            with timeout of 50 seconds
                tell application id "\(kind.bundleID)"
                    -- The app was launched with this document; wait for it rather than opening it a
                    -- second time (a concurrent second open can wedge the app).
                    set theDoc to missing value
                    repeat 80 times
                        try
                            repeat with d in documents
                                try
                                    if POSIX path of ((file of d) as alias) is \(q(src)) then set theDoc to contents of d
                                end try
                            end repeat
                        end try
                        if theDoc is not missing value then exit repeat
                        delay 0.25
                    end repeat
                    if theDoc is missing value then set theDoc to open (POSIX file \(q(src)) as alias)
                    try
                        \(exportLine)
                    on error errMsg number errNum
                        close theDoc saving no
                        error errMsg number errNum
                    end try
                    close theDoc saving no
                    \(quitAfter ? "quit saving no" : "")
                end tell
            end timeout
            """
    }

    /// Exports `url` to PDF (or xlsx, via Numbers) with the given iWork app. Runs osascript off the main thread.
    static func export(_ url: URL, with kind: IWorkKind, as format: ExportFormat = .pdf, timeout: TimeInterval = 60) async throws -> URL {
        if let c = cached(url, format: format) { return c }
        guard appURL(kind) != nil else { throw ExportError.appMissing(kind.appName) }
        let out = cacheURL(for: url, format: format)
        let tmp = out.deletingPathExtension().appendingPathExtension("partial.\(format.rawValue)")
        try? FileManager.default.removeItem(at: tmp)
        let bundleID = kind.bundleID
        // Only quit the app afterwards if we were the ones who started it.
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        let src = script(kind: kind, src: url.path, out: tmp.path, quitAfter: !wasRunning, format: format)
        return try await Task.detached(priority: .userInitiated) {
            // Launch hidden (with the document) so no window flashes on screen.
            let pre = Process()
            pre.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // Hand the document over at launch: a cold-started iWork app otherwise shows its own
            // modal "Open" panel, which blocks every scripted command until someone dismisses it.
            pre.arguments = ["-g", "-j", "-b", bundleID, url.path]
            try? pre.run()
            pre.waitUntilExit()
            // Wait for the app to be up, then ask for Automation permission from *our* process.
            // Without this the consent prompt may never surface and osascript just fails.
            for _ in 0..<100 where NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let status = DocumentExporter.automationPermission(bundleID)
            Log.write("automation permission for \(bundleID): \(status)")
            if status == OSStatus(errAEEventNotPermitted) || status == OSStatus(errAEEventWouldRequireUserConsent) {
                throw ExportError.notAuthorized
            }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", src]
            let errPipe = Pipe()
            let errBuf = PipeCollector()
            errPipe.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
            p.standardError = errPipe
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning {
                if Task.isCancelled || Date() > deadline {
                    p.terminate()
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    throw Task.isCancelled ? CancellationError() : ExportError.timeout
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            p.waitUntilExit()
            errPipe.fileHandleForReading.readabilityHandler = nil
            errBuf.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            let err = String(decoding: errBuf.data, as: UTF8.self)
            if p.terminationStatus != 0 {
                Log.write("export \(url.lastPathComponent) with \(bundleID) failed: \(err)")
                if err.contains("-1743") || err.contains("Not authorized") || err.contains("不允许") { throw ExportError.notAuthorized }
                throw ExportError.failed("导出失败：" + err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(160))
            }
            guard FileManager.default.fileExists(atPath: tmp.path) else { throw ExportError.failed("未生成导出文件") }
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: tmp, to: out)
            return out
        }.value
    }

    /// Asks TCC whether we may send Apple Events to `bundleID`, prompting the user if needed.
    nonisolated static func automationPermission(_ bundleID: String) -> OSStatus {
        var addr = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &addr) }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&addr) }
        return AEDeterminePermissionToAutomateTarget(&addr, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
    }

    static func openAutomationSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Embedded preview image inside an iWork file (zip or package).
    static func embeddedPreview(_ url: URL, isDirectory: Bool) -> NSImage? {
        let names = ["preview.jpg", "QuickLook/Preview.jpg", "QuickLook/Thumbnail.jpg", "preview-web.jpg", "preview-micro.jpg", "QuickLook/Preview.pdf"]
        if isDirectory {
            for n in names {
                let u = url.appendingPathComponent(n)
                if let img = NSImage(contentsOf: u) { return img }
            }
            return nil
        }
        var best: (String, Data)?
        for n in names {
            if let hit = ArchiveReader.extract(url: url, matching: { $0 == n }) { best = hit; break }
        }
        return best.flatMap { NSImage(data: $0.1) }
    }
}
