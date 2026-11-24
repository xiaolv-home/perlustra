import Foundation
import CArchive

public struct ArchiveProgress: Sendable {
    public var completedFiles: Int
    public var totalFiles: Int?
    public var completedBytes: Int64
    public var currentName: String

    public init(completedFiles: Int, totalFiles: Int? = nil, completedBytes: Int64, currentName: String) {
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.completedBytes = completedBytes
        self.currentName = currentName
    }
}

public struct ArchiveExtractOptions: Sendable {
    /// `nil` extracts everything; non-nil extracts matching files or directories (with descendants).
    public var selectedPaths: Set<String>?
    /// Wraps multi-root archives in a folder so extraction never scatters files across the target directory.
    public var smartWrap: Bool
    /// Guard against zip bombs (default 4 GiB).
    public var maxTotalBytes: Int64
    /// Guard against archive entry floods (default 100,000 files).
    public var maxFiles: Int
    /// Skips Finder metadata (`__MACOSX`, `.DS_Store`, `._*`) during extraction.
    public var skipMacOSJunk: Bool

    public init(
        selectedPaths: Set<String>? = nil,
        smartWrap: Bool = true,
        maxTotalBytes: Int64 = 4 << 30,
        maxFiles: Int = 100_000,
        skipMacOSJunk: Bool = true
    ) {
        self.selectedPaths = selectedPaths
        self.smartWrap = smartWrap
        self.maxTotalBytes = maxTotalBytes
        self.maxFiles = maxFiles
        self.skipMacOSJunk = skipMacOSJunk
    }
}

public struct ArchiveExtractResult: Sendable {
    public var outputURL: URL
    public var extractedFiles: Int
    public var totalBytes: Int64
    public var skippedUnsafe: Int
    public var skippedEncrypted: Int
}

public enum ArchiveOperationError: Error, LocalizedError {
    case openFailed(String)
    case writeFailed(String)
    case entryNotFound(String)
    case encryptedEntry(String)
    case unsafePath(String)
    case sizeLimitExceeded(Int64)
    case fileCountLimitExceeded(Int)
    case nothingToProcess
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "无法打开压缩包：\(m)"
        case .writeFailed(let m): return "写入失败：\(m)"
        case .entryNotFound(let p): return "在压缩包里找不到「\(p)」"
        case .encryptedEntry(let p): return "「\(p)」已加密，当前不支持解密"
        case .unsafePath(let p): return "路径不安全，已拦截：\(p)"
        case .sizeLimitExceeded: return "解压内容超过安全上限，已中止"
        case .fileCountLimitExceeded: return "解压文件数量超过安全上限，已中止"
        case .nothingToProcess: return "没有可处理的文件"
        case .cancelled: return "已取消"
        }
    }
}

/// Safe streaming extractor built on the system `libarchive`.
/// Blocks Zip Slip traversal, symlink/hardlink escapes, special device nodes, and zip bombs.
public enum ArchiveExtractor {
    private static let fileTypeMask: mode_t = 0o170000
    private static let typeRegular: mode_t = 0o100000
    private static let typeDirectory: mode_t = 0o040000

    public static func extract(
        archiveURL: URL,
        to destinationDirectory: URL,
        options: ArchiveExtractOptions = .init(),
        progress: ((ArchiveProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> ArchiveExtractResult {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let cleanSelections: Set<String>? = options.selectedPaths.map { raw in
            Set(raw.compactMap { ArchivePathSafety.sanitizeRelativePath($0) })
        }

        // Determine whether to wrap output in a dedicated folder to avoid scattering files.
        let rootDir: URL
        let createdWrapper: Bool
        if cleanSelections == nil, options.smartWrap {
            let listing = try ArchiveReader.list(url: archiveURL, isCancelled: isCancelled)
            if let wrapperName = ArchivePathSafety.smartRootDirectoryName(for: listing.entries, archiveURL: archiveURL) {
                rootDir = ArchivePathSafety.uniqueDestinationURL(in: destinationDirectory, name: wrapperName)
                try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
                createdWrapper = true
            } else {
                rootDir = destinationDirectory
                createdWrapper = false
            }
        } else {
            rootDir = destinationDirectory
            createdWrapper = false
        }

        guard let a = archive_read_new() else {
            throw ArchiveOperationError.openFailed("libarchive 初始化失败")
        }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        archive_read_support_format_raw(a)
        guard archive_read_open_filename(a, archiveURL.path, 64 * 1024) == LA_ARCHIVE_OK else {
            if createdWrapper { try? fm.removeItem(at: rootDir) }
            throw ArchiveOperationError.openFailed(ArchiveReader.errorString(a))
        }

        var extractedFiles = 0
        var totalBytes: Int64 = 0
        var skippedUnsafe = 0
        var skippedEncrypted = 0
        var firstExtractedURL: URL?
        var topLevelOutputs: Set<String> = []
        var entry: OpaquePointer?
        var buf = [UInt8](repeating: 0, count: 64 * 1024)

        do {
            while true {
                if isCancelled() { throw ArchiveOperationError.cancelled }
                let r = archive_read_next_header(a, &entry)
                if r == LA_ARCHIVE_EOF { break }
                if r != LA_ARCHIVE_OK && r != LA_ARCHIVE_WARN {
                    throw ArchiveOperationError.openFailed(ArchiveReader.errorString(a))
                }
                guard let e = entry else { break }

                let rawPath = ArchiveReader.decodePath(e)
                guard let cleanPath = ArchivePathSafety.sanitizeRelativePath(rawPath) else {
                    skippedUnsafe += 1
                    archive_read_data_skip(a)
                    continue
                }
                if let selected = cleanSelections, !matchesSelection(cleanPath, selected: selected) {
                    archive_read_data_skip(a)
                    continue
                }
                if options.skipMacOSJunk && isJunkPath(cleanPath) {
                    archive_read_data_skip(a)
                    continue
                }
                if archive_entry_is_encrypted(e) != 0 {
                    skippedEncrypted += 1
                    archive_read_data_skip(a)
                    continue
                }
                // Reject symlinks, hardlinks, FIFOs, sockets, and device nodes.
                let ftype = archive_entry_filetype(e) & fileTypeMask
                let isDir = ftype == typeDirectory || rawPath.hasSuffix("/")
                let isReg = ftype == typeRegular || (ftype == 0 && !isDir)
                if archive_entry_symlink(e) != nil || archive_entry_hardlink(e) != nil || (!isDir && !isReg) {
                    skippedUnsafe += 1
                    archive_read_data_skip(a)
                    continue
                }

                // When extracting directly into an existing folder without a wrapper, avoid
                // silently clobbering an existing top-level directory or file.
                let relativeOut = relativeOutputPath(for: cleanPath, selected: cleanSelections)
                guard let target = ArchivePathSafety.safeDestination(relativePath: relativeOut, under: rootDir) else {
                    skippedUnsafe += 1
                    archive_read_data_skip(a)
                    continue
                }

                if isDir {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    if let firstComp = relativeOut.split(separator: "/").first {
                        topLevelOutputs.insert(String(firstComp))
                    }
                    continue
                }

                extractedFiles += 1
                if extractedFiles > options.maxFiles {
                    throw ArchiveOperationError.fileCountLimitExceeded(options.maxFiles)
                }

                let finalTarget =
                    fm.fileExists(atPath: target.path)
                    ? ArchivePathSafety.uniqueDestinationURL(
                        in: target.deletingLastPathComponent(),
                        name: target.lastPathComponent
                    )
                    : target
                try fm.createDirectory(at: finalTarget.deletingLastPathComponent(), withIntermediateDirectories: true)

                let bytesWritten = try streamEntryToDisk(
                    archive: a,
                    destination: finalTarget,
                    buffer: &buf,
                    remainingBudget: options.maxTotalBytes - totalBytes,
                    isCancelled: isCancelled
                )
                totalBytes += bytesWritten
                applySafeAttributes(entry: e, to: finalTarget)

                if firstExtractedURL == nil { firstExtractedURL = finalTarget }
                if let firstComp = relativeOut.split(separator: "/").first {
                    topLevelOutputs.insert(String(firstComp))
                }
                progress?(
                    ArchiveProgress(
                        completedFiles: extractedFiles,
                        totalFiles: nil,
                        completedBytes: totalBytes,
                        currentName: finalTarget.lastPathComponent
                    ))
            }
        } catch {
            if createdWrapper { try? fm.removeItem(at: rootDir) }
            throw error
        }

        let outputURL: URL
        if createdWrapper {
            outputURL = rootDir
        } else if topLevelOutputs.count == 1, let single = topLevelOutputs.first {
            outputURL = rootDir.appendingPathComponent(single)
        } else if let first = firstExtractedURL, extractedFiles == 1 {
            outputURL = first
        } else {
            outputURL = rootDir
        }

        return ArchiveExtractResult(
            outputURL: outputURL,
            extractedFiles: extractedFiles,
            totalBytes: totalBytes,
            skippedUnsafe: skippedUnsafe,
            skippedEncrypted: skippedEncrypted
        )
    }

    /// Streams one archive member directly to `destinationFile` for temporary in-app preview.
    @discardableResult
    public static func extractSingleEntryToFile(
        archiveURL: URL,
        entryPath: String,
        destinationFile: URL,
        maxBytes: Int64 = 256 << 20,
        isCancelled: () -> Bool = { false }
    ) throws -> Int64 {
        guard let targetClean = ArchivePathSafety.sanitizeRelativePath(entryPath) else {
            throw ArchiveOperationError.unsafePath(entryPath)
        }
        guard let a = archive_read_new() else {
            throw ArchiveOperationError.openFailed("libarchive 初始化失败")
        }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        archive_read_support_format_raw(a)
        guard archive_read_open_filename(a, archiveURL.path, 64 * 1024) == LA_ARCHIVE_OK else {
            throw ArchiveOperationError.openFailed(ArchiveReader.errorString(a))
        }

        var entry: OpaquePointer?
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if isCancelled() { throw ArchiveOperationError.cancelled }
            let r = archive_read_next_header(a, &entry)
            if r == LA_ARCHIVE_EOF { break }
            if r != LA_ARCHIVE_OK && r != LA_ARCHIVE_WARN {
                throw ArchiveOperationError.openFailed(ArchiveReader.errorString(a))
            }
            guard let e = entry else { break }
            let rawPath = ArchiveReader.decodePath(e)
            guard let clean = ArchivePathSafety.sanitizeRelativePath(rawPath), clean == targetClean else {
                archive_read_data_skip(a)
                continue
            }
            if archive_entry_is_encrypted(e) != 0 {
                throw ArchiveOperationError.encryptedEntry(destinationFile.lastPathComponent)
            }
            if archive_entry_symlink(e) != nil || archive_entry_hardlink(e) != nil {
                throw ArchiveOperationError.unsafePath(rawPath)
            }
            try FileManager.default.createDirectory(
                at: destinationFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try streamEntryToDisk(
                archive: a,
                destination: destinationFile,
                buffer: &buf,
                remainingBudget: maxBytes,
                isCancelled: isCancelled
            )
        }
        throw ArchiveOperationError.entryNotFound(entryPath)
    }

    // MARK: Private Helpers

    private static func matchesSelection(_ cleanPath: String, selected: Set<String>) -> Bool {
        if selected.contains(cleanPath) { return true }
        for prefix in selected where cleanPath.hasPrefix(prefix + "/") {
            return true
        }
        return false
    }

    private static func relativeOutputPath(for cleanPath: String, selected: Set<String>?) -> String {
        guard let selected, selected.count == 1, let only = selected.first else {
            return cleanPath
        }
        // Extracting a single nested file places it directly in the destination folder.
        if cleanPath == only {
            return (cleanPath as NSString).lastPathComponent
        }
        // Extracting a single nested folder keeps that folder as the top level.
        let parent = (only as NSString).deletingLastPathComponent
        if !parent.isEmpty && cleanPath.hasPrefix(parent + "/") {
            return String(cleanPath.dropFirst(parent.count + 1))
        }
        return cleanPath
    }

    private static func isJunkPath(_ cleanPath: String) -> Bool {
        cleanPath.split(separator: "/").contains { ArchivePathSafety.isMacOSJunk(name: String($0)) }
    }

    private static func streamEntryToDisk(
        archive a: OpaquePointer,
        destination: URL,
        buffer: inout [UInt8],
        remainingBudget: Int64,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw ArchiveOperationError.writeFailed("无法创建文件 \(destination.lastPathComponent)")
        }
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var written: Int64 = 0
            while true {
                if isCancelled() { throw ArchiveOperationError.cancelled }
                let n = buffer.withUnsafeMutableBytes { archive_read_data(a, $0.baseAddress, $0.count) }
                if n < 0 {
                    throw ArchiveOperationError.openFailed(ArchiveReader.errorString(a))
                }
                if n == 0 { break }
                written += Int64(n)
                if written > remainingBudget {
                    throw ArchiveOperationError.sizeLimitExceeded(remainingBudget)
                }
                try handle.write(contentsOf: buffer[0..<n])
            }
            return written
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    private static func applySafeAttributes(entry e: OpaquePointer, to url: URL) {
        var attrs: [FileAttributeKey: Any] = [:]
        let rawPerm = archive_entry_perm(e) & 0o777
        let safePerm = rawPerm == 0 ? 0o644 : (rawPerm | 0o600)
        attrs[.posixPermissions] = Int(safePerm)
        let mtime = archive_entry_mtime(e)
        if mtime > 0 {
            attrs[.modificationDate] = Date(timeIntervalSince1970: TimeInterval(mtime))
        }
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }
}
