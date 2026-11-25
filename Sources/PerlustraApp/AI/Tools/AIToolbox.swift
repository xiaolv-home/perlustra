import AppKit
import PerlustraCore

/// Something the AI wants to do that needs a yes from the user first.
struct AIApproval: Identifiable, Equatable, Codable {
    var id = UUID()
    var title: String
    var detail: String
}

/// The tools for one request: files, skills and commands, plus the open document's own tools.
@MainActor
final class AIToolbox {
    weak var document: AIDocument?
    weak var workspace: AIWorkspace?
    let skills: [Skill]
    let allowCommands: Bool
    /// The model can look at pictures (view_image is offered).
    let vision: Bool
    let approve: (AIApproval) async -> Bool
    /// Extracted text of files read this run, for paging through long ones.
    private var textCache: [URL: String] = [:]
    /// A skill was loaded during this request. Commands then need a second confirmation.
    private var usedSkill = false

    init(
        document: AIDocument?, workspace: AIWorkspace?, skills: [Skill], allowCommands: Bool, vision: Bool = false,
        approve: @escaping (AIApproval) async -> Bool
    ) {
        self.vision = vision
        self.document = document
        self.workspace = workspace
        self.skills = skills
        self.allowCommands = allowCommands
        self.approve = approve
    }

    var documentTools: AIDocumentTools? { document?.renderer as? AIDocumentTools }
    var currentFile: URL? { document?.file?.url }
    var base: URL { AIFiles.baseFolder(near: currentFile, browsing: workspace?.aiBrowsingFolder) }

    var specs: [AIToolSpec] {
        var out: [AIToolSpec] = [
            AIToolSpec(
                "read_file", "读取文件内容为文字：文本/Markdown/代码按原编码，PDF 按页，Word/RTF，PPT 幻灯片文字，Excel 各工作表，图片会做文字识别（OCR，同一行用制表符分隔）。不填 path 读当前打开的文件。长文件用 offset 分段读。",
                Schema.object([
                    "path": Schema.string("文件路径：绝对路径、~/… 或相对当前文件所在文件夹"),
                    "offset": Schema.integer("从第几个字开始（默认 0）"),
                    "max_chars": Schema.integer("最多读多少字（默认 20000）"),
                ])),
            AIToolSpec(
                "list_folder", "列出文件夹里的文件和子文件夹（含大小、修改时间）。不填 path 为当前文件所在文件夹。",
                Schema.object(["path": Schema.string("文件夹路径")])),
            AIToolSpec(
                "search_text", "在文件夹（含子文件夹）的文本类文件里搜索文字，返回「文件:行号: 内容」。适合在资料库、法规库、笔记里找依据。",
                Schema.object(
                    [
                        "query": Schema.string("要找的文字（或正则表达式，regex=true 时）"),
                        "folder": Schema.string("在哪个文件夹里搜，默认当前文件所在文件夹"),
                        "regex": Schema.boolean("query 是否为正则表达式"),
                    ], required: ["query"])),
            AIToolSpec(
                "write_file", "生成一个新文件交付给用户。按扩展名决定格式：.docx/.pdf/.html/.rtf 会把 Markdown 内容排版成正式文档（标题、列表、表格都保留）；.md/.txt/.json/.csv 等原样写入。已存在的文件需要用户同意才会覆盖。",
                Schema.object(
                    [
                        "path": Schema.string("文件路径，建议放在当前文件旁边，如 「合同审阅意见.docx」"),
                        "content": Schema.string("文件内容（富文本格式请用 Markdown 书写）"),
                    ], required: ["path", "content"])),
            AIToolSpec(
                "create_spreadsheet", "生成新的 Excel（.xlsx）或 CSV 表格。每张表是行的数组，每行是单元格数组；数字写成数字；以 = 开头的文字会作为公式写入（例如 \"=SUM(B2:B10)\"），保存前会先算好结果。",
                Schema.object(
                    [
                        "path": Schema.string("文件路径（.xlsx / .csv）"),
                        "sheets": Schema.array(
                            "工作表",
                            items: Schema.object(
                                [
                                    "name": Schema.string("工作表名称"),
                                    "rows": Schema.array("行", items: Schema.array("单元格", items: ["description": "数字、文字或公式"])),
                                ], required: ["name", "rows"])),
                    ], required: ["path", "sheets"])),
            AIToolSpec(
                "open_file", "在 Perlustra 的新标签页里打开一个文件给用户看（例如刚生成的文件）。",
                Schema.object(["path": Schema.string("文件路径")], required: ["path"])),
        ]
        if vision {
            out.append(
                AIToolSpec(
                    "view_image", "直接看一张图片（或 PDF 的某一页）：理解照片、图表、截图、版式、印章、手写等画面内容。只需要其中的文字时用 read_file（文字识别更快更准）。不填 path 看当前打开的文件。",
                    Schema.object(["path": Schema.string("图片或 PDF 路径"), "page": Schema.integer("PDF 的第几页（默认 1）")])))
        }
        if !skills.isEmpty {
            let many = skills.count > AISession.listAllSkillsUpTo
            out.append(
                AIToolSpec(
                    "use_skill", "载入一个技能的完整说明（工作方法、检查清单、模板）。任务和某个技能相关时，先调用它再动手。",
                    Schema.object(["name": Schema.string("技能名称", enum: many ? nil : skills.map(\.name))], required: ["name"])))
            if many {
                out.append(
                    AIToolSpec(
                        "find_skills", "按关键词在已安装的技能里搜索（名称和说明，中英文都可以），返回最相关的技能名和说明。",
                        Schema.object(["query": Schema.string("关键词，如「合同 审查」或 resume")], required: ["query"])))
            }
        }
        if allowCommands {
            out.append(
                AIToolSpec(
                    "run_command", "在终端运行一条 shell 命令（zsh），例如运行技能里附带的 Python 脚本、转换格式。每次都会先请用户点「允许」。不要用它删除或覆盖文件。",
                    Schema.object(
                        [
                            "command": Schema.string("命令"),
                            "cwd": Schema.string("工作目录，默认当前文件所在文件夹"),
                        ], required: ["command"])))
        }
        if let d = documentTools { out += d.aiTools }
        return out
    }

    func run(_ call: AIToolCall, _ args: AIJSON) async -> AIToolOutput {
        switch call.name {
        case "read_file": return await readFile(args)
        case "list_folder": return listFolder(args["path"]?.string)
        case "search_text": return await searchText(args)
        case "write_file": return await writeFile(args)
        case "create_spreadsheet": return createSpreadsheet(args)
        case "open_file": return openFile(args["path"]?.string ?? "")
        case "view_image": return await viewImage(args)
        case "use_skill": return useSkill(args["name"]?.string ?? "")
        case "find_skills":
            let found = SkillLibrary.rank(skills, for: args["query"]?.string ?? "", limit: 12)
            if found.isEmpty { return AIToolOutput("没有找到相关技能。可以换个说法，或直接动手。") }
            return AIToolOutput(found.map { "- \($0.name)：\($0.description.prefix(200))" }.joined(separator: "\n"))
        case "run_command": return await runCommand(args)
        default:
            if let d = documentTools, d.aiTools.contains(where: { $0.name == call.name }) { return await d.aiRun(call.name, args) }
            return .error("没有叫 \(call.name) 的工具")
        }
    }

    // MARK: Files

    private func readFile(_ args: AIJSON) async -> AIToolOutput {
        let path = args["path"]?.string ?? ""
        guard let url = path.isEmpty ? currentFile : AIFiles.resolve(path, base: base) else { return .error("当前没有打开文件，请给出 path") }
        if let why = AIFiles.readable(url) { return .error(why) }
        guard FileManager.default.fileExists(atPath: url.path) else { return .error("文件不存在：\(url.path)") }
        let text: String
        if let t = textCache[url] {
            text = t
        } else {
            do { text = try await DocumentText.extract(url) } catch {
                return .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            textCache[url] = text
        }
        let offset = max(0, args["offset"]?.int ?? 0)
        let limit = min(max(1000, args["max_chars"]?.int ?? 20_000), AIAgent.maxToolOutput - 400)
        guard offset < max(1, text.count) else { return AIToolOutput("（已读到末尾，共 \(text.count) 字）") }
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        let piece = String(text[start..<end])
        let shownEnd = offset + piece.count
        var head = "文件：\(url.path)（共 \(text.count) 字"
        head += shownEnd < text.count ? "，这里是第 \(offset)–\(shownEnd) 字，后面还有，可用 offset=\(shownEnd) 继续读）" : (offset > 0 ? "，这里是第 \(offset) 字到结尾）" : "）")
        return AIToolOutput(head + "\n\n" + piece)
    }

    private func listFolder(_ path: String?) -> AIToolOutput {
        let url = (path?.isEmpty ?? true) ? base : AIFiles.resolve(path!, base: base)
        if let why = AIFiles.readable(url) { return .error(why) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return .error("打不开文件夹：\(url.path)")
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(400).map { u -> String in
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true && v?.isPackage != true { return "📁 \(u.lastPathComponent)/" }
            let size = ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)
            return "   \(u.lastPathComponent)  \(size)  \(v?.contentModificationDate.map(df.string) ?? "")"
        }
        return AIToolOutput("\(url.path)（\(items.count) 项）\n" + rows.joined(separator: "\n") + (items.count > 400 ? "\n…" : ""))
    }

    private func searchText(_ args: AIJSON) async -> AIToolOutput {
        guard let q = args["query"]?.string, !q.isEmpty else { return .error("缺少 query") }
        let folder = (args["folder"]?.string).flatMap { $0.isEmpty ? nil : AIFiles.resolve($0, base: base) } ?? base
        if let why = AIFiles.readable(folder) { return .error(why) }
        let useRegex = args["regex"]?.bool ?? false
        let re: NSRegularExpression?
        if useRegex {
            guard let r = try? NSRegularExpression(pattern: q, options: [.caseInsensitive]) else { return .error("正则表达式写错了") }
            re = r
        } else {
            re = nil
        }
        let hits = await Task.detached(priority: .userInitiated) {
            Self.search(q, regex: re, in: folder, isCancelled: { Task.isCancelled })
        }.value
        if hits.isEmpty { return AIToolOutput("在 \(folder.path) 里没有找到「\(q)」") }
        return AIToolOutput("在 \(folder.path) 里找到 \(hits.count)\(hits.count >= 120 ? "+" : "") 处：\n" + hits.joined(separator: "\n"))
    }

    nonisolated static func search(
        _ q: String,
        regex re: NSRegularExpression?,
        in folder: URL,
        timeout: TimeInterval = 15,
        isCancelled: () -> Bool = { false }
    ) -> [String] {
        var out: [String] = []
        guard
            let e = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return out }
        let deadline = Date().addingTimeInterval(timeout)
        var scanned = 0
        while let u = e.nextObject() as? URL {
            if isCancelled() || Date() >= deadline || out.count >= 120 || scanned > 5000 { break }
            guard DocumentText.textExtensions.contains(u.pathExtension.lowercased()),
                let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
                (v.fileSize ?? 0) < 8 << 20, let text = try? TextFileFormat.read(u).0
            else { continue }
            scanned += 1
            let rel = u.path.replacingOccurrences(of: folder.path + "/", with: "")
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if i % 256 == 0, (isCancelled() || Date() >= deadline) { break }
                // Cap per-line regex input length to mitigate catastrophic backtracking on minified lines.
                let capped = line.count > 4096 ? String(line.prefix(4096)) : String(line)
                let match =
                    re.map { $0.firstMatch(in: capped, range: NSRange(capped.startIndex..., in: capped)) != nil }
                    ?? capped.localizedCaseInsensitiveContains(q)
                if match {
                    out.append("\(rel):\(i + 1): \(capped.trimmingCharacters(in: .whitespaces).prefix(240))")
                    if out.count >= 120 { break }
                }
            }
        }
        return out
    }

    private func writeFile(_ args: AIJSON) async -> AIToolOutput {
        guard let path = args["path"]?.string, !path.isEmpty else { return .error("缺少 path") }
        let content = args["content"]?.string ?? ""
        let url = AIFiles.resolve(path, base: base)
        if let why = AIFiles.writable(url) { return .error(why) }
        if FileManager.default.fileExists(atPath: url.path) {
            if url == currentFile && document?.renderer?.hasUnsavedChanges == true {
                return .error("这个文件正开着且有未保存的修改，请换一个文件名")
            }
            guard await approve(AIApproval(title: "覆盖已有文件？", detail: url.path)) else {
                return .error("用户没有同意覆盖。请换一个新文件名再写。")
            }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DocumentWriter.write(markdown: content, to: url)
        } catch {
            return .error("写入失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return AIToolOutput(
            "已生成 \(url.path)（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))）",
            createdFiles: [url]
        )
    }

    private func createSpreadsheet(_ args: AIJSON) -> AIToolOutput {
        guard let path = args["path"]?.string, !path.isEmpty else { return .error("缺少 path") }
        guard let sheets = args["sheets"]?.array, !sheets.isEmpty else { return .error("缺少 sheets") }
        let parsed: [(name: String, rows: [[CellValue]])] = sheets.enumerated().map { i, s in
            let rows: [[CellValue]] = (s["rows"]?.array ?? []).map { row in
                (row.array ?? [row]).map { v -> CellValue in
                    switch v {
                    case .number(let d): return .number(d)
                    case .bool(let b): return .bool(b)
                    case .string(let t): return t.hasPrefix("=") ? .text(t) : CellValue.infer(t)
                    default: return .empty
                    }
                }
            }
            return (name: s["name"]?.string ?? "Sheet\(i + 1)", rows: rows)
        }
        switch AIFiles.writeTable(parsed, to: path, near: currentFile, browsing: workspace?.aiBrowsingFolder) {
        case .success(let url):
            return AIToolOutput(
                "已生成 \(url.path)（\(parsed.map { "\($0.name) \($0.rows.count) 行" }.joined(separator: "，"))）",
                createdFiles: [url]
            )
        case .failure(let e): return .error(e.message)
        }
    }

    private func openFile(_ path: String) -> AIToolOutput {
        let url = AIFiles.resolve(path, base: base)
        if let why = AIFiles.readable(url) { return .error(why) }
        guard FileManager.default.fileExists(atPath: url.path) else { return .error("文件不存在：\(url.path)") }
        guard let workspace else { return .error("没有可用的窗口") }
        workspace.aiOpen(url)
        return AIToolOutput("已在新标签页打开 \(url.lastPathComponent)")
    }

    private func viewImage(_ args: AIJSON) async -> AIToolOutput {
        let path = args["path"]?.string ?? ""
        guard let url = path.isEmpty ? currentFile : AIFiles.resolve(path, base: base) else { return .error("当前没有打开文件，请给出 path") }
        if let why = AIFiles.readable(url) { return .error(why) }
        let ext = url.pathExtension.lowercased()
        guard ext == "pdf" || AIVision.imageExtensions.contains(ext) else { return .error("view_image 只能看图片或 PDF 页面") }
        let page = max(1, args["page"]?.int ?? 1)
        do {
            let (img, size) = try await Task.detached(priority: .userInitiated) { try AIVision.load(url, page: page) }.value
            let what = ext == "pdf" ? "\(url.lastPathComponent) 第 \(page) 页" : url.lastPathComponent
            return AIToolOutput("已附上图片：\(what)（\(Int(size.width))×\(Int(size.height))）", images: [img])
        } catch {
            return .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Skills and commands

    private func useSkill(_ name: String) -> AIToolOutput {
        guard let s = skills.first(where: { $0.name == name }) ?? AISkills.shared.find(name) else {
            return .error("没有这个技能。可用：" + skills.map(\.name).joined(separator: "、"))
        }
        usedSkill = true
        return AIToolOutput(Self.skillText(s))
    }

    static func skillText(_ s: Skill) -> String {
        var text = "# 技能：\(s.name)\n\n" + s.instructions()
        let files = s.resourceFiles()
        if !files.isEmpty {
            text += "\n\n---\n技能文件夹：\(s.folder.path)\n附带文件（需要时用 read_file 读，路径写 技能文件夹/相对路径）：\n" + files.prefix(80).map { "- \($0)" }.joined(separator: "\n")
            if files.count > 80 { text += "\n…共 \(files.count) 个文件；可用 search_text 在技能文件夹里搜索" }
        }
        return text
    }

    private func runCommand(_ args: AIJSON) async -> AIToolOutput {
        guard allowCommands else { return .error("用户没有开启「允许 AI 运行终端命令」") }
        guard let cmd = args["command"]?.string, !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return .error("缺少 command") }
        let cwd = (args["cwd"]?.string).flatMap { $0.isEmpty ? nil : AIFiles.resolve($0, base: base) } ?? base
        if let why = AIFiles.readable(cwd) { return .error(why) }
        guard await approve(AIApproval(title: "运行终端命令？", detail: "在 \(cwd.path) 中运行：\n\(cmd)")) else {
            return .error("用户拒绝运行这条命令")
        }
        if usedSkill {
            let again = AIApproval(title: "再确认一次：运行这条命令？", detail: "本次对话载入过技能。技能内容未经 Perlustra 审核，命令会以你的账户权限执行。\n\(cmd)")
            guard await approve(again) else { return .error("用户没有再次确认，命令没有运行") }
        }
        return await Task.detached(priority: .userInitiated) {
            Self.shell(cmd, cwd: cwd, isCancelled: { Task.isCancelled })
        }.value
    }

    nonisolated static func shell(
        _ cmd: String,
        cwd: URL,
        timeout: TimeInterval = 180,
        isCancelled: () -> Bool = { false }
    ) -> AIToolOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in buffer.append(h.availableData) }
        do { try p.run() } catch { return .error("无法运行：\(error.localizedDescription)") }
        let pid = p.processIdentifier
        _ = setpgid(pid, pid)
        let deadline = Date().addingTimeInterval(timeout)
        var cancelled = false
        while p.isRunning && Date() < deadline {
            if isCancelled() {
                cancelled = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        var timedOut = false
        if p.isRunning {
            timedOut = !cancelled
            if getpgid(pid) == pid { _ = kill(-pid, SIGTERM) } else { p.terminate() }
            let killDeadline = Date().addingTimeInterval(0.6)
            while p.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                if getpgid(pid) == pid { _ = kill(-pid, SIGKILL) }
                _ = kill(pid, SIGKILL)
            }
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        let text = String(decoding: buffer.data, as: UTF8.self)
        let status: String
        if cancelled {
            status = "用户已停止"
        } else if timedOut {
            status = "超时（\(Int(timeout)) 秒）已停止"
        } else {
            status = "退出码 \(p.terminationStatus)"
        }
        return AIToolOutput("\(status)\n\(text.isEmpty ? "（无输出）" : text)", isError: cancelled || timedOut || p.terminationStatus != 0)
    }
}

/// Collects a command's output from the pipe's background handler (capped at 400 KB).
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ d: Data) { lock.lock(); if bytes.count < 400_000 { bytes.append(d) }; lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
