import Foundation

/// Pure path validation and destination helpers for archive extraction and creation.
/// Kept self-contained inside `PerlustraCore/Archive` so every security rule is unit-testable.
public enum ArchivePathSafety {
    private static let compoundExtensions = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4",
    ]

    /// Normalises a raw archive member path into a safe relative path, or returns `nil`
    /// if the path attempts traversal (`..`), contains NUL bytes, or resolves to empty.
    public static func sanitizeRelativePath(_ raw: String) -> String? {
        guard !raw.contains("\0") else { return nil }
        let normalised = raw.replacingOccurrences(of: "\\", with: "/")
        var parts: [String] = []
        for piece in normalised.split(separator: "/", omittingEmptySubsequences: true) {
            let s = String(piece)
            if s == "." { continue }
            if s == ".." { return nil }
            parts.append(s)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// Resolves `relativePath` under `root` and verifies both lexical containment and that
    /// no existing ancestor symlink escapes `root`.
    public static func safeDestination(relativePath: String, under root: URL) -> URL? {
        guard let clean = sanitizeRelativePath(relativePath) else { return nil }
        let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = rootURL.path
        let candidate = rootURL.appendingPathComponent(clean).standardizedFileURL
        guard isContained(candidate.path, inside: rootPath) else { return nil }

        // Walk existing prefixes from `root` downward to ensure no pre-existing symlink
        // redirects writes outside `root`.
        let fm = FileManager.default
        var current = rootURL
        for component in clean.split(separator: "/").map(String.init) {
            current.appendPathComponent(component)
            if let attrs = try? fm.attributesOfItem(atPath: current.path),
                let type = attrs[.type] as? FileAttributeType,
                type == .typeSymbolicLink
            {
                return nil
            }
            if fm.fileExists(atPath: current.path) {
                let real = current.resolvingSymlinksInPath().standardizedFileURL.path
                guard isContained(real, inside: rootPath) else { return nil }
            }
        }
        return candidate
    }

    /// Returns a wrapper folder name when an archive would otherwise scatter multiple items
    /// (or a single loose file) directly into the target folder; returns `nil` when the
    /// archive already has a single top-level directory.
    public static func smartRootDirectoryName(for entries: [ArchiveEntry], archiveURL: URL) -> String? {
        var topLevels: Set<String> = []
        var hasSingleDirectory = false
        for entry in entries {
            guard let clean = sanitizeRelativePath(entry.path) else { continue }
            let parts = clean.split(separator: "/").map(String.init)
            guard let first = parts.first else { continue }
            if first == "__MACOSX" || first == ".DS_Store" || first.hasPrefix("._") { continue }
            topLevels.insert(first)
            if parts.count > 1 || entry.isDirectory {
                hasSingleDirectory = true
            }
        }
        if topLevels.count == 1 && hasSingleDirectory {
            return nil
        }
        return archiveBaseName(for: archiveURL)
    }

    /// Strips known compound or single archive extensions (`foo.tar.gz` → `foo`).
    public static func archiveBaseName(for url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for ext in compoundExtensions where lower.hasSuffix(ext) {
            let stem = String(name.dropLast(ext.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stem.isEmpty { return stem }
        }
        let stem = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "解压内容" : stem
    }

    /// Picks a collision-free URL in `folder` (`name`, `name 2`, `name 3`, …).
    public static func uniqueDestinationURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        let initial = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: initial.path) { return initial }

        let lower = name.lowercased()
        var stem = name
        var ext = ""
        if let compound = compoundExtensions.first(where: { lower.hasSuffix($0) }) {
            stem = String(name.dropLast(compound.count))
            ext = String(name.suffix(compound.count))
        } else if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
            ext = String(name[dot...])
        }

        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(stem) \(n)\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Whether a file or folder name is macOS Finder metadata noise.
    public static func isMacOSJunk(name: String) -> Bool {
        name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._")
    }

    private static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz",
        "zst", "tzst", "lz4", "iso", "cpio", "xar", "cab",
    ]

    /// Fast filename-only check used by sidebar menus so menu building never touches disk.
    public static func isArchiveFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        if compoundExtensions.contains(where: { lower.hasSuffix($0) }) { return true }
        let ext = (lower as NSString).pathExtension
        return archiveExtensions.contains(ext)
    }

    static func isContained(_ path: String, inside root: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}
