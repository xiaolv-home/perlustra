import Foundation
import CArchive

public enum ArchiveOutputFormat: String, Sendable, CaseIterable {
    case zip
    case tarGz

    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tarGz: return "tar.gz"
        }
    }

    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .tarGz: return "tar.gz"
        }
    }
}

public struct ArchiveCompressOptions: Sendable {
    public var format: ArchiveOutputFormat
    /// Omits `.DS_Store`, `__MACOSX`, and `._*` AppleDouble files.
    public var skipMacOSJunk: Bool

    public init(format: ArchiveOutputFormat = .zip, skipMacOSJunk: Bool = true) {
        self.format = format
        self.skipMacOSJunk = skipMacOSJunk
    }
}

public struct ArchiveCompressResult: Sendable {
    public var archiveURL: URL
    public var fileCount: Int
    public var totalSourceBytes: Int64
    public var archiveBytes: Int64
}

/// Atomic streaming archive creator built on the system `libarchive`.
/// Writes to a sibling temporary file and moves into place only after full completion.
public enum ArchiveWriter {
    private static let typeRegular: UInt32 = 0o100000
    private static let typeDirectory: UInt32 = 0o040000

    public static func suggestedArchiveURL(
        for items: [URL],
        format: ArchiveOutputFormat,
        in directory: URL? = nil
    ) -> URL {
        let baseDir = directory ?? items.first?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        let stem: String
        if items.count == 1, let only = items.first {
            let rv = try? only.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDir = (rv?.isDirectory == true) && (rv?.isPackage != true)
            let candidate = isDir ? only.lastPathComponent : only.deletingPathExtension().lastPathComponent
            stem = candidate.isEmpty ? only.lastPathComponent : candidate
        } else {
            stem = "归档"
        }
        return ArchivePathSafety.uniqueDestinationURL(in: baseDir, name: "\(stem).\(format.fileExtension)")
    }

    public static func compress(
        items: [URL],
        to destinationURL: URL,
        options: ArchiveCompressOptions = .init(),
        progress: ((ArchiveProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> ArchiveCompressResult {
        guard !items.isEmpty else { throw ArchiveOperationError.nothingToProcess }
        let fm = FileManager.default
        let destDir = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let destReal = destinationURL.standardizedFileURL.path
        let tempURL = destDir.appendingPathComponent(".perlustra-archive-\(UUID().uuidString).tmp")
        let tempReal = tempURL.standardizedFileURL.path

        // Collect entries up front so progress can report total file count and skip self/symlinks.
        var entriesToWrite: [(diskURL: URL, archivePath: String, isDirectory: Bool, size: Int64)] = []
        for item in items {
            if isCancelled() { throw ArchiveOperationError.cancelled }
            let std = item.standardizedFileURL
            try collect(
                url: std,
                archivePrefix: std.lastPathComponent,
                excludingPaths: [destReal, tempReal],
                skipJunk: options.skipMacOSJunk,
                into: &entriesToWrite,
                isCancelled: isCancelled
            )
        }
        guard !entriesToWrite.isEmpty else { throw ArchiveOperationError.nothingToProcess }

        let totalFiles = entriesToWrite.filter { !$0.isDirectory }.count
        guard let a = archive_write_new() else {
            throw ArchiveOperationError.writeFailed("libarchive 初始化失败")
        }
        var closed = false
        defer {
            if !closed { _ = archive_write_close(a) }
            archive_write_free(a)
        }

        let fmtStatus: Int32
        let filterStatus: Int32
        switch options.format {
        case .zip:
            fmtStatus = archive_write_set_format_zip(a)
            filterStatus = archive_write_add_filter_none(a)
        case .tarGz:
            fmtStatus = archive_write_set_format_pax_restricted(a)
            filterStatus = archive_write_add_filter_gzip(a)
        }
        guard fmtStatus == LA_ARCHIVE_OK, filterStatus == LA_ARCHIVE_OK else {
            throw ArchiveOperationError.writeFailed(ArchiveReader.errorString(a))
        }
        guard archive_write_open_filename(a, tempURL.path) == LA_ARCHIVE_OK else {
            throw ArchiveOperationError.writeFailed(ArchiveReader.errorString(a))
        }

        var completedFiles = 0
        var totalSourceBytes: Int64 = 0
        var buf = [UInt8](repeating: 0, count: 64 * 1024)

        do {
            for item in entriesToWrite {
                if isCancelled() { throw ArchiveOperationError.cancelled }
                try writeEntry(
                    archive: a,
                    diskURL: item.diskURL,
                    archivePath: item.archivePath,
                    isDirectory: item.isDirectory,
                    size: item.size,
                    buffer: &buf,
                    isCancelled: isCancelled
                )
                if !item.isDirectory {
                    completedFiles += 1
                    totalSourceBytes += item.size
                    progress?(
                        ArchiveProgress(
                            completedFiles: completedFiles,
                            totalFiles: totalFiles,
                            completedBytes: totalSourceBytes,
                            currentName: item.diskURL.lastPathComponent
                        ))
                }
            }
            if archive_write_close(a) != LA_ARCHIVE_OK {
                throw ArchiveOperationError.writeFailed(ArchiveReader.errorString(a))
            }
            closed = true

            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: tempURL, to: destinationURL)
        } catch {
            if !closed {
                _ = archive_write_close(a)
                closed = true
            }
            try? fm.removeItem(at: tempURL)
            throw error
        }

        let archiveBytes = (try? fm.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ArchiveCompressResult(
            archiveURL: destinationURL,
            fileCount: completedFiles,
            totalSourceBytes: totalSourceBytes,
            archiveBytes: archiveBytes
        )
    }

    // MARK: Private Helpers

    private static func collect(
        url: URL,
        archivePrefix: String,
        excludingPaths: Set<String>,
        skipJunk: Bool,
        into out: inout [(diskURL: URL, archivePath: String, isDirectory: Bool, size: Int64)],
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw ArchiveOperationError.cancelled }
        let path = url.standardizedFileURL.path
        if excludingPaths.contains(path) { return }
        if skipJunk && ArchivePathSafety.isMacOSJunk(name: url.lastPathComponent) { return }

        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
            let ftype = attrs[.type] as? FileAttributeType
        else { return }

        // Never follow symlinks when compressing to prevent infinite cycles and out-of-tree leaks.
        if ftype == .typeSymbolicLink { return }

        if ftype == .typeDirectory {
            let dirArchivePath = archivePrefix.hasSuffix("/") ? archivePrefix : archivePrefix + "/"
            out.append((url, dirArchivePath, true, 0))
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
            let sorted = children.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            for child in sorted {
                try collect(
                    url: child,
                    archivePrefix: archivePrefix + "/" + child.lastPathComponent,
                    excludingPaths: excludingPaths,
                    skipJunk: skipJunk,
                    into: &out,
                    isCancelled: isCancelled
                )
            }
        } else if ftype == .typeRegular {
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            out.append((url, archivePrefix, false, size))
        }
    }

    private static func writeEntry(
        archive a: OpaquePointer,
        diskURL: URL,
        archivePath: String,
        isDirectory: Bool,
        size: Int64,
        buffer: inout [UInt8],
        isCancelled: () -> Bool
    ) throws {
        guard let entry = archive_entry_new() else {
            throw ArchiveOperationError.writeFailed("无法创建归档条目")
        }
        defer { archive_entry_free(entry) }

        archivePath.withCString { archive_entry_set_pathname(entry, $0) }
        archive_entry_set_filetype(entry, isDirectory ? typeDirectory : typeRegular)
        archive_entry_set_size(entry, isDirectory ? 0 : size)

        let attrs = try? FileManager.default.attributesOfItem(atPath: diskURL.path)
        let rawPerm = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? (isDirectory ? 0o755 : 0o644)
        archive_entry_set_perm(entry, mode_t(rawPerm & 0o777))
        if let mtime = attrs?[.modificationDate] as? Date {
            archive_entry_set_mtime(entry, time_t(mtime.timeIntervalSince1970), 0)
        }

        guard archive_write_header(a, entry) == LA_ARCHIVE_OK else {
            throw ArchiveOperationError.writeFailed(ArchiveReader.errorString(a))
        }
        guard !isDirectory, size > 0 else { return }

        let handle = try FileHandle(forReadingFrom: diskURL)
        defer { try? handle.close() }
        while true {
            if isCancelled() { throw ArchiveOperationError.cancelled }
            guard let chunk = try handle.read(upToCount: buffer.count), !chunk.isEmpty else { break }
            let written = chunk.withUnsafeBytes { ptr in
                archive_write_data(a, ptr.baseAddress, chunk.count)
            }
            if written < 0 {
                throw ArchiveOperationError.writeFailed(ArchiveReader.errorString(a))
            }
        }
    }
}
