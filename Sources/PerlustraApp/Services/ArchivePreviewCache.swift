import Foundation
import PerlustraCore

/// Manages temporary files extracted for in-app preview of archive members.
/// Each process uses its own session folder under `/tmp` and sweeps stale folders from exited processes.
final class ArchivePreviewCache: @unchecked Sendable {
    struct PreviewSource: Sendable {
        let archiveName: String
        let entryPath: String
    }

    static let shared = ArchivePreviewCache()

    private static let sessionPrefix = "PerlustraArchivePreview-"
    private let lock = NSLock()
    private var sessionRoot: URL?
    private var containerByFile: [String: URL] = [:]
    private var sourceByFile: [String: PreviewSource] = [:]

    private init() {
        sweepStaleSessions()
    }

    func extractForPreview(
        archiveURL: URL,
        entryPath: String,
        isCancelled: () -> Bool = { false }
    ) throws -> URL {
        let root = try ensureSessionRoot()
        let fileName =
            ArchivePathSafety.sanitizeRelativePath(entryPath)
            .map { ($0 as NSString).lastPathComponent } ?? "preview"
        let safeName = fileName.isEmpty ? "preview" : fileName
        let container = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destFile = container.appendingPathComponent(safeName).standardizedFileURL

        do {
            _ = try ArchiveExtractor.extractSingleEntryToFile(
                archiveURL: archiveURL,
                entryPath: entryPath,
                destinationFile: destFile,
                isCancelled: isCancelled
            )
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }

        lock.lock()
        containerByFile[destFile.path] = container
        sourceByFile[destFile.path] = PreviewSource(
            archiveName: archiveURL.lastPathComponent,
            entryPath: entryPath
        )
        lock.unlock()
        return destFile
    }

    func isPreviewFile(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return containerByFile[key] != nil
    }

    func previewSource(for url: URL) -> PreviewSource? {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return sourceByFile[key]
    }

    func release(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock()
        let container = containerByFile.removeValue(forKey: key)
        sourceByFile.removeValue(forKey: key)
        lock.unlock()
        if let container {
            try? FileManager.default.removeItem(at: container)
        }
    }

    func cleanupAll() {
        lock.lock()
        let root = sessionRoot
        sessionRoot = nil
        containerByFile.removeAll()
        sourceByFile.removeAll()
        lock.unlock()
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func ensureSessionRoot() throws -> URL {
        lock.lock()
        if let existing = sessionRoot {
            lock.unlock()
            return existing
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.sessionPrefix)\(pid)", isDirectory: true)
        sessionRoot = root
        lock.unlock()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sweepStaleSessions() {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for item in items {
            let name = item.lastPathComponent
            guard name.hasPrefix(Self.sessionPrefix) else { continue }
            let suffix = String(name.dropFirst(Self.sessionPrefix.count))
            guard let pid = Int32(suffix), pid != myPID else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}
