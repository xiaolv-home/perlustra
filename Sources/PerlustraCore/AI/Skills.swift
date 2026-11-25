import Foundation

/// A skill: a folder with a SKILL.md (YAML front matter `name` / `description`, then the
/// instructions) plus any reference files. Same layout as Claude / Codex agent skills, so
/// skills from GitHub work as they are.
public struct Skill: Sendable, Identifiable, Equatable {
    public var id: String { folder.path }
    public var name: String
    public var description: String
    public var folder: URL
    /// Shipped with Perlustra (cannot be removed).
    public var builtIn: Bool
    /// Where it was installed from (a GitHub URL), if anywhere.
    public var source: String?

    public var skillFile: URL { folder.appendingPathComponent(SkillLibrary.fileName(in: folder) ?? "SKILL.md") }

    /// The instructions (front matter removed). Rejects symlinks escaping the skill folder.
    public func instructions() -> String {
        guard let safeFile = FileAccessPolicy.fileInsideRoot(skillFile, root: folder),
            (try? safeFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            let text = try? String(contentsOf: safeFile, encoding: .utf8)
        else { return "" }
        return SkillLibrary.parseFrontMatter(text).body
    }

    /// Other files in the skill's folder, relative paths (for reading references on demand).
    public func resourceFiles(limit: Int = 200) -> [String] {
        guard
            let e = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var out: [String] = []
        let base = folder.standardizedFileURL.path + "/"
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = u.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
            if rel.caseInsensitiveCompare("SKILL.md") == .orderedSame { continue }
            out.append(rel)
            if out.count >= limit { break }
        }
        return out.sorted()
    }
}

public enum SkillLibrary {
    static let sourceFile = ".perlustra-source.json"

    static func fileName(in folder: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.first { $0.caseInsensitiveCompare("SKILL.md") == .orderedSame }
    }

    /// Every skill directly inside the given folders (built-in folders first).
    public static func scan(builtIn: [URL], installed: URL) -> [Skill] {
        var out: [Skill] = []
        for dir in builtIn { out += skills(in: dir, builtIn: true) }
        out += skills(in: installed, builtIn: false)
        return out
    }

    static func skills(in dir: URL, builtIn: Bool) -> [Skill] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { n -> Skill? in
            let folder = dir.appendingPathComponent(n)
            return load(folder, builtIn: builtIn)
        }
    }

    public static func load(_ folder: URL, builtIn: Bool = false) -> Skill? {
        guard let f = fileName(in: folder),
            let text = try? String(contentsOf: folder.appendingPathComponent(f), encoding: .utf8)
        else { return nil }
        let (meta, body) = parseFrontMatter(text)
        let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        var desc = meta["description"] ?? ""
        if desc.isEmpty {
            // No front matter: the first paragraph of the body describes it.
            desc =
                body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        }
        let source = (try? Data(contentsOf: folder.appendingPathComponent(sourceFile)))
            .flatMap { AIJSON.parse($0)?["url"]?.string }
        return Skill(name: name, description: desc, folder: folder, builtIn: builtIn, source: source)
    }

    /// Skills ordered by how well their name and description match `query` (Chinese by character
    /// pairs, other text by words). Skills with no overlap are left out.
    public static func rank(_ skills: [Skill], for query: String, limit: Int = 10) -> [Skill] {
        let q = terms(query)
        guard !q.isEmpty else { return [] }
        let scored = skills.map { s -> (Skill, Double) in
            let name = terms(s.name), desc = terms(s.description)
            let score = Double(q.intersection(name).count) * 3 + Double(q.intersection(desc).count)
            return (s, score)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static let stopTerms: Set<String> = [
        "the", "and", "for", "with", "use", "when", "you", "this", "that", "from", "user", "帮我", "一下", "这个", "一份", "我的", "进行", "可以", "需要", "使用", "用于", "适用",
    ]

    static func terms(_ text: String) -> Set<String> {
        var out = Set<String>()
        let lower = text.lowercased()
        var word = ""
        var han: [Character] = []
        func endWord() { if word.count >= 3, !stopTerms.contains(word) { out.insert(word) }; word = "" }
        func endHan() {
            if han.count == 1 { out.insert(String(han)) }
            for i in 0..<max(0, han.count - 1) { let t = String(han[i...i + 1]); if !stopTerms.contains(t) { out.insert(t) } }
            han = []
        }
        for ch in lower {
            if ch.unicodeScalars.first.map({ (0x4E00...0x9FFF).contains($0.value) }) == true {
                endWord(); han.append(ch)
            } else if ch.isLetter || ch.isNumber {
                endHan(); word.append(ch)
            } else {
                endWord(); endHan()
            }
        }
        endWord(); endHan()
        return out
    }

    /// Splits `---` front matter from the body. Understands `key: value`, quoted values and
    /// folded / literal blocks (`>` / `|`), which is what skill files use.
    public static func parseFrontMatter(_ text: String) -> (meta: [String: String], body: String) {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
            let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            return ([:], text)
        }
        var meta: [String: String] = [:]
        var i = 1
        while i < end {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value == ">" || value == "|" || value == ">-" || value == "|-" {
                var parts: [String] = []
                while i < end, lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") || lines[i].isEmpty {
                    parts.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                value = parts.joined(separator: value.hasPrefix(">") ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.count >= 2, let q = value.first, (q == "\"" || q == "'"), value.last == q {
                value = String(value.dropFirst().dropLast())
                if q == "\"" {
                    value = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
                } else {
                    value = value.replacingOccurrences(of: "''", with: "'")
                }
            }
            meta[key] = value
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (meta, body)
    }
}

/// Installs skills from a GitHub repository (or a folder of one).
public enum SkillInstaller {
    public struct Source: Sendable, Equatable {
        public var owner: String
        public var repo: String
        public var ref: String?
        public var path: String
        public var webURL: String {
            "https://github.com/\(owner)/\(repo)" + (ref.map { "/tree/\($0)" + (path.isEmpty ? "" : "/" + path) } ?? "")
        }
    }

    /// Understands github.com/owner/repo, …/tree/branch/sub/path, …/blob/branch/sub/SKILL.md
    /// and the short form owner/repo.
    public static func parse(_ text: String) -> Source? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasPrefix("github.com/") { s.removeFirst("github.com/".count) }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/").map { ($0.removingPercentEncoding ?? String($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let safeToken: (String) -> Bool = { tok in
            !tok.isEmpty && tok != "." && tok != ".." && !tok.contains(where: { $0.isWhitespace || $0.isNewline })
        }
        guard parts.count >= 2, !parts[0].contains("."), safeToken(parts[0]), safeToken(parts[1]) else { return nil }
        var src = Source(owner: parts[0], repo: parts[1], ref: nil, path: "")
        if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob", safeToken(parts[3]) {
            src.ref = parts[3]
            var rest = Array(parts.dropFirst(4))
            if parts[2] == "blob", let last = rest.last, last.lowercased().hasSuffix(".md") { rest.removeLast() }
            src.path = rest.joined(separator: "/")
        }
        return src
    }

    public enum Progress: Sendable { case downloading, unpacking, installing }

    private static func makeGitHubURL(host: String, segments: [String]) throws -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        let encoded = segments.map { seg in
            seg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? seg
        }
        c.percentEncodedPath = "/" + encoded.joined(separator: "/")
        guard let u = c.url else { throw AIError("GitHub 仓库地址格式不正确") }
        return u
    }

    /// Downloads the repository and copies every skill folder under `source.path` into `destination`.
    /// Returns the installed skills. Existing skills with the same folder name are replaced.
    public static func install(
        _ source: Source, into destination: URL, session: URLSession = .shared,
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> [Skill] {
        await progress(.downloading)
        let ref = try await resolveRef(source, session: session)
        let zipURL = try makeGitHubURL(host: "codeload.github.com", segments: [source.owner, source.repo, "zip", ref])
        var req = URLRequest(url: zipURL)
        req.timeoutInterval = 120
        let (tmp, resp) = try await session.download(for: req)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw AIError(http.statusCode == 404 ? "GitHub 上找不到这个仓库或分支" : "下载失败（\(http.statusCode)）")
        }
        await progress(.unpacking)
        let files = try ArchiveReader.extractAll(url: tmp, matching: { !$0.hasSuffix("/") }, maxBytes: 300 << 20)
        await progress(.installing)
        return try installFiles(files, source: source, into: destination)
    }

    static func resolveRef(_ s: Source, session: URLSession) async throws -> String {
        if let r = s.ref { return r }
        let apiURL = try makeGitHubURL(host: "api.github.com", segments: ["repos", s.owner, s.repo])
        var req = URLRequest(url: apiURL)
        req.timeoutInterval = 30
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 { throw AIError("GitHub 上找不到 \(s.owner)/\(s.repo)") }
        return AIJSON.parse(data)?["default_branch"]?.string ?? "main"
    }

    /// Picks the skill folders out of an unpacked archive (paths start with "repo-ref/").
    static func installFiles(_ files: [String: Data], source: Source, into destination: URL) throws -> [Skill] {
        // Strip the archive's top folder.
        var tree: [String: Data] = [:]
        for (p, d) in files {
            guard let slash = p.firstIndex(of: "/") else { continue }
            tree[String(p[p.index(after: slash)...])] = d
        }
        let prefix = source.path.isEmpty ? "" : source.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        let skillDirs = tree.keys.filter { k in
            (k.hasPrefix(prefix) || prefix.isEmpty) && (k as NSString).lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame
        }.map { ($0 as NSString).deletingLastPathComponent }
        guard !skillDirs.isEmpty else { throw AIError("这个位置没有找到技能（需要包含 SKILL.md 的文件夹）") }
        // Nested SKILL.md inside another skill's folder belongs to that skill (examples, templates).
        let roots = skillDirs.filter { d in !skillDirs.contains { o in o != d && (o.isEmpty || d.hasPrefix(o + "/")) } }
        let license = tree.keys.first { ["license", "license.md", "license.txt"].contains($0.lowercased()) }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var installed: [Skill] = []
        for dir in roots.sorted() {
            let folderName = dir.isEmpty ? source.repo : (dir as NSString).lastPathComponent
            var target = destination.appendingPathComponent(sanitize(folderName))
            // Same folder name from another repository: keep both.
            if let existing = SkillLibrary.load(target)?.source,
                !existing.lowercased().hasPrefix("https://github.com/\(source.owner)/\(source.repo)/".lowercased()),
                existing.lowercased() != "https://github.com/\(source.owner)/\(source.repo)".lowercased()
            {
                target = destination.appendingPathComponent(sanitize(folderName + "-" + source.owner))
            }
            let staging = destination.appendingPathComponent(".staging-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer {
                if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) }
            }
            let base = dir.isEmpty ? "" : dir + "/"
            for (path, data) in tree where path.hasPrefix(base) {
                let rawRel = String(path.dropFirst(base.count))
                guard let rel = ArchivePathSafety.sanitizeRelativePath(rawRel) else { continue }
                // Repository plumbing is not part of a skill.
                if rel.hasPrefix(".git/") || rel.hasPrefix(".github/") || rel.contains("node_modules/") || data.count > 20 << 20 { continue }
                guard let out = ArchivePathSafety.safeDestination(relativePath: rel, under: staging) else { continue }
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: out)
            }
            if let license, !fm.fileExists(atPath: staging.appendingPathComponent("LICENSE").path), let d = tree[license] {
                try d.write(to: staging.appendingPathComponent("LICENSE"))
            }
            var src = source
            src.path = dir
            let meta: AIJSON = ["url": .string(src.webURL), "installed": .string(ISO8601DateFormatter().string(from: Date()))]
            try meta.data().write(to: staging.appendingPathComponent(SkillLibrary.sourceFile))
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
            if let s = SkillLibrary.load(target) { installed.append(s) }
        }
        return installed
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s.hasPrefix(".") ? "skill" : s
    }
}
