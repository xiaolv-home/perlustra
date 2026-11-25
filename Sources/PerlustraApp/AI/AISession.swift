import AppKit
import PerlustraCore

/// One entry in the AI panel's transcript.
struct AIItem: Identifiable, Equatable, Codable {
    enum Kind: Equatable, Codable {
        case user(String, context: String?)
        case assistant(String)
        case reasoning(String)
        case tool(name: String, summary: String, result: String?, failed: Bool)
        case file(URL)
        case approval(AIApproval, decided: Bool?)
        /// Pictures sent with a request (small thumbnails, base64 JPEG).
        case images([String])
        case note(String, isError: Bool)
    }
    var id = UUID()
    var kind: Kind
}

/// The conversation in one window: what was said, what the AI did, and the run in progress.
@MainActor
final class AISession: ObservableObject {
    @Published private(set) var items: [AIItem] = []
    @Published private(set) var running = false
    @Published var input = ""
    /// A skill the user picked for the next message.
    @Published var pinnedSkill: Skill?
    @Published var statusLine = ""
    /// The panel shows the list of saved conversations instead of this one.
    @Published var showHistory = false
    /// When the current run started (the panel shows how long it has been going).
    @Published private(set) var runStarted: Date?
    weak var workspace: AIWorkspace?
    /// Whether the transcript is keeping up with new output.
    let scrollFollow = AIScrollFollow()

    fileprivate(set) var history: [AIMessage] = []
    /// The saved conversation this is (nil until the first message).
    @Published private(set) var conversation: AIConversation?
    private var task: Task<Void, Never>?
    private var approvals: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init() {}

    var isEmpty: Bool { items.isEmpty }

    func newChat() {
        stop()
        history = []
        items = []
        statusLine = ""
        conversation = nil
    }

    /// Picks up a saved conversation where it left off.
    func open(_ id: UUID) {
        guard !running, id != conversation?.id, let c = AIConversations.shared.load(id) else { return }
        history = c.history
        // A conversation saved mid-run: unanswered questions count as declined, unfinished
        // actions as interrupted.
        items = c.items.map { item in
            var item = item
            switch item.kind {
            case .approval(let a, nil): item.kind = .approval(a, decided: false)
            case .tool(let n, let s, nil, _): item.kind = .tool(name: n, summary: s, result: "（已中断）", failed: true)
            default: break
            }
            return item
        }
        conversation = c
        statusLine = ""
        showHistory = false
    }

    func deleteConversation(_ id: UUID) {
        if conversation?.id == id { newChat() }
        AIConversations.shared.delete(id)
    }

    /// Saves after each request and each finished run, so nothing is lost if the app quits.
    fileprivate func save() {
        guard var c = conversation else { return }
        c.history = history
        c.items = items
        c.updated = Date()
        conversation = c
        AIConversations.shared.save(c)
    }

    func stop() {
        task?.cancel()
        for (_, c) in approvals { c.resume(returning: false) }
        approvals = [:]
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        input = ""
        send(text)
    }

    func send(_ text: String) {
        let config = AIConfig.shared
        let endpoint: AIEndpoint
        do { endpoint = try debugEndpoint ?? config.endpoint() } catch {
            items.append(AIItem(kind: .user(text, context: nil)))
            items.append(AIItem(kind: .note((error as? AIError)?.message ?? error.localizedDescription, isError: true)))
            return
        }
        let doc = workspace?.aiDocument
        let docTools = doc?.renderer as? AIDocumentTools
        let context: String? = {
            guard let f = doc?.file else { return nil }
            let line = docTools?.aiContext ?? ""
            return line.isEmpty ? "当前打开的文件：\(f.url.path)" : line + "（路径：\(f.url.path)）"
        }()
        var message = text
        if let s = pinnedSkill {
            message = "请按照下面的技能来做这件事。\n\n" + AIToolbox.skillText(s) + "\n\n---\n我的要求：" + text
        }
        // The date goes with each request (not in the system prompt, which stays cacheable).
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 EEEE"
        let skills = AISkills.shared.enabled
        var header = "今天是 \(df.string(from: Date()))" + (context.map { "；\($0)" } ?? "")
        // With many skills installed, only the ones that fit this request are named here.
        if pinnedSkill == nil, skills.count > Self.listAllSkillsUpTo {
            let related = SkillLibrary.rank(skills.filter { !$0.builtIn }, for: text + " " + (doc?.file?.name ?? ""), limit: 8)
            if !related.isEmpty {
                header += "\n可能相关的已安装技能（用 use_skill 载入）：" + related.map { "\($0.name)（\($0.description.prefix(70))）" }.joined(separator: "；")
            }
        }
        message = "【\(header)】\n" + message
        items.append(AIItem(kind: .user(text, context: pinnedSkill.map { "技能：\($0.name)" })))
        let pictures = attachments
        attachments = []
        if !pictures.isEmpty { items.append(AIItem(kind: .images(pictures.map(\.thumbnail)))) }
        pinnedSkill = nil
        if conversation == nil {
            let title = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            conversation = AIConversation(
                title: String(title.prefix(30)), model: debugEndpoint.map { "\($0.proto.rawValue) · \($0.model)" } ?? config.summary,
                file: doc?.file?.name, history: [], items: [])
        }

        let host = debugEndpoint != nil ? "测试服务器" : config.mode == .local ? "这台 Mac 上运行的本地模型（不联网）" : config.provider.name + " 的云端 API"
        let system = Self.systemPrompt(skills: skills, endpoint: endpoint, host: host)
        let client = AIClients.make(endpoint)
        let allowCommands = config.allowCommands
        running = true
        runStarted = Date()
        statusLine = "思考中…"
        // The run holds the session until it ends (a window closing stops it first).
        let session = self
        task = Task {
            let vision = await AIVision.supports(endpoint)
            var user = AIMessage.user(message)
            if !pictures.isEmpty {
                if vision {
                    user.images = pictures.map(\.image)
                } else {
                    // A model that cannot see still gets what the pictures say.
                    session.note("当前模型不能看图，已改为识别图中文字后发送", isError: false)
                    let texts = await Task.detached(priority: .userInitiated) { pictures.map { AIVision.describe($0.image) } }.value
                    user.text += texts.enumerated().map { "\n\n【附图 \($0.offset + 1)：\(pictures[$0.offset].name) 识别出的文字】\n\($0.element)" }.joined()
                }
            }
            session.history.append(user)
            session.save()
            let toolbox = AIToolbox(
                document: doc, workspace: session.workspace, skills: skills, allowCommands: allowCommands, vision: vision,
                approve: { a in await session.ask(a) })
            do {
                try await AIAgent.run(
                    client: client, system: system, history: session.history, tools: toolbox.specs,
                    runTool: { call, args in await toolbox.run(call, args) },
                    onEvent: { ev in await session.handle(ev) })
            } catch is CancellationError {
                session.note("已停止", isError: false)
            } catch {
                let msg = AIHTTP.describe(error, endpoint: endpoint)
                session.note(msg, isError: msg != "已停止")
            }
            session.finishRun()
        }
    }

    // MARK: Pictures

    struct Attachment: Identifiable {
        let id = UUID()
        var name: String
        var image: AIImage
        /// Small JPEG (base64) for the transcript.
        var thumbnail: String
    }

    /// Pictures that go with the next message.
    @Published var attachments: [Attachment] = []

    func attach(files: [URL]) {
        for u in files {
            guard let (img, _) = try? AIVision.load(u), let (thumb, _) = try? AIVision.load(u, maxPixels: 240) else {
                note("「\(u.lastPathComponent)」不是能读的图片", isError: true)
                continue
            }
            attachments.append(Attachment(name: u.lastPathComponent, image: img, thumbnail: thumb.base64))
        }
    }

    func attach(image: NSImage, name: String = "粘贴的图片") {
        guard let img = try? AIVision.image(from: image), let thumb = try? AIVision.image(from: image, maxPixels: 240) else { return }
        attachments.append(Attachment(name: name, image: img, thumbnail: thumb.base64))
    }

    private func finishRun() {
        save()
        running = false
        runStarted = nil
        statusLine = ""
        task = nil
        streamingID = nil
        reasoningID = nil
    }

    fileprivate func note(_ text: String, isError: Bool) {
        items.append(AIItem(kind: .note(text, isError: isError)))
    }

    // MARK: Events

    /// The assistant text streaming into the transcript right now.
    private var streamingID: UUID?
    private var reasoningID: UUID?

    private func handle(_ ev: AIAgent.Event) {
        switch ev {
        case .text(let t):
            statusLine = "正在回答…"
            if let id = streamingID, let i = items.firstIndex(where: { $0.id == id }), case .assistant(let s) = items[i].kind {
                items[i].kind = .assistant(s + t)
            } else {
                let item = AIItem(kind: .assistant(t.trimmingLeadingNewlines))
                streamingID = item.id
                items.append(item)
            }
        case .reasoning(let t):
            statusLine = "思考中…"
            if let id = reasoningID, let i = items.firstIndex(where: { $0.id == id }), case .reasoning(let s) = items[i].kind {
                items[i].kind = .reasoning(s + t)
            } else {
                let item = AIItem(kind: .reasoning(t))
                reasoningID = item.id
                items.append(item)
            }
        case .toolPreparing(let name):
            statusLine = "准备" + AIToolNames.verb(name) + "…"
        case .toolStarted(let call):
            streamingID = nil
            reasoningID = nil
            statusLine = AIToolNames.verb(call.name) + "…"
            items.append(AIItem(kind: .tool(name: call.name, summary: AIToolNames.summary(call), result: nil, failed: false)))
        case .toolFinished(let call, let out):
            if let i = items.lastIndex(where: {
                if case .tool(let n, _, nil, _) = $0.kind { return n == call.name }; return false
            }),
                case .tool(let n, let s, _, _) = items[i].kind
            {
                items[i].kind = .tool(name: n, summary: s, result: AIToolNames.resultLine(call, out), failed: out.isError)
            }
            for url in out.createdFiles {
                items.append(AIItem(kind: .file(url)))
            }
            statusLine = "继续…"
        case .message(let m):
            history.append(m)
            if m.role == .assistant {
                // The streamed text is final now; tidy it.
                if let id = streamingID, let i = items.firstIndex(where: { $0.id == id }) {
                    if m.text.isEmpty { items.remove(at: i) } else { items[i].kind = .assistant(m.text) }
                }
                streamingID = nil
                reasoningID = nil
            }
        case .stopped(let reason):
            switch reason {
            case .maxTokens: note("回复太长被截断了，可以说「继续」", isError: false)
            case .refused: note("模型拒绝回答这个请求", isError: true)
            case .other: note("步骤太多，先停在这里。可以说「继续」", isError: false)
            default: break
            }
        }
    }

    // MARK: Approval

    /// Debug harness: talk to this endpoint instead of the configured one (mock servers).
    #if DEBUG
        var debugEndpoint: AIEndpoint?
    #else
        let debugEndpoint: AIEndpoint? = nil
    #endif
    /// Debug harness: answer approval requests automatically.
    #if DEBUG
        var debugAutoApprove: Bool?
    #else
        let debugAutoApprove: Bool? = nil
    #endif

    fileprivate func ask(_ a: AIApproval) async -> Bool {
        items.append(AIItem(kind: .approval(a, decided: debugAutoApprove)))
        if let auto = debugAutoApprove { return auto }
        statusLine = "等你确认…"
        NSApp.requestUserAttention(.informationalRequest)
        return await withCheckedContinuation { c in approvals[a.id] = c }
    }

    func decide(_ a: AIApproval, _ allow: Bool) {
        guard let c = approvals.removeValue(forKey: a.id) else { return }
        if let i = items.firstIndex(where: {
            if case .approval(let x, _) = $0.kind { return x.id == a.id }; return false
        }) {
            items[i].kind = .approval(a, decided: allow)
        }
        c.resume(returning: allow)
    }

    // MARK: Prompt

    /// Up to this many skills are all listed in the system prompt.
    static let listAllSkillsUpTo = 24

    static func systemPrompt(skills: [Skill], endpoint: AIEndpoint, host: String) -> String {
        var s = """
            你是 Perlustra 里的 AI 助手，现在由 \(host) 提供的模型「\(endpoint.model)」驱动（用户问起你是什么模型时如实告诉对方）。Perlustra 是 macOS 上的文件查看器，用户正在看文件，你能用工具真正动手：读文件、精确计算、汇总、筛选、改文档、生成 Word / PDF / Excel 文件交付给用户。

            做事原则：
            - 先弄清材料：处理文件前先读（表格先 sheet_overview，文档先 read_file），不要凭空猜内容。
            - 数字全部用工具算（calculate / summarize / add_column），绝不心算或估算；引用数据时说明来自哪里。
            - 用户要的是结果，就交付文件：报告、意见书、简历用 write_file 生成 .docx（或用户要求的格式），表格结果用 create_spreadsheet 或 summarize 的 save_as。文件放在当前文件旁边，起清楚的中文名。生成后用一两句话说明做了什么、文件在哪。
            - 转录、还原、提取数据时逐字保留原值：不四舍五入、不改格式、不补不删，识别不清的标出来让用户核对。
            - 原文件永远不改；需要修改时生成新文件（Markdown 文档可以用 edit_document 在编辑器里改，用户自己保存）。
            - 任务和某个技能相关时，先 use_skill 载入它，按技能里的方法和标准做。
            - 一次工具调用失败就看错误信息换个办法，不要重复同样的调用。
            - 用中文回答，简洁、具体；不要复述用户已经看到的内容。
            """
        if skills.count <= listAllSkillsUpTo {
            if !skills.isEmpty {
                s += "\n\n可用技能（用 use_skill 载入完整说明）：\n" + skills.map { "- \($0.name)：\($0.description.prefix(160))" }.joined(separator: "\n")
            }
        } else {
            // Listing hundreds of skills would crowd out the work (local models especially).
            let own = skills.filter(\.builtIn)
            s += "\n\nPerlustra 自带技能（用 use_skill 载入完整说明）：\n" + own.map { "- \($0.name)：\($0.description.prefix(120))" }.joined(separator: "\n")
            s += "\n\n另外安装了 \(skills.count - own.count) 个技能。每次请求会附上可能相关的几个；其他的用 find_skills 按关键词（中英文都可以）搜索。"
        }
        return s
    }
}

extension AIItem {
    /// One line for the debug harness.
    var debugLine: String {
        switch kind {
        case .user(let t, let c): return "USER\(c.map { "[\($0)]" } ?? ""): \(t)"
        case .assistant(let t): return "ASSISTANT: " + t.replacingOccurrences(of: "\n", with: "⏎")
        case .reasoning(let t): return "REASONING: \(t.count) chars"
        case .tool(let n, let s, let r, let f): return "TOOL \(n)\(f ? " ✕" : ""): \(s) → \(r ?? "…")".replacingOccurrences(of: "\n", with: "⏎")
        case .file(let u): return "FILE: \(u.path)"
        case .approval(let a, let d): return "APPROVAL: \(a.title) \(a.detail) → \(d.map { $0 ? "allowed" : "denied" } ?? "pending")"
        case .note(let t, let e): return "NOTE\(e ? " ✕" : ""): \(t)"
        case .images(let t): return "IMAGES: \(t.count)"
        }
    }
}

private extension String {
    var trimmingLeadingNewlines: String { String(drop { $0 == "\n" }) }
}

/// How tool calls read in the transcript.
enum AIToolNames {
    static func verb(_ name: String) -> String {
        switch name {
        case "read_file": return "读取文件"
        case "list_folder": return "查看文件夹"
        case "search_text": return "搜索"
        case "write_file": return "生成文件"
        case "create_spreadsheet": return "生成表格"
        case "open_file": return "打开文件"
        case "use_skill": return "载入技能"
        case "find_skills": return "查找技能"
        case "view_image": return "看图"
        case "run_command": return "运行命令"
        case "sheet_overview": return "查看表格结构"
        case "read_cells": return "读取单元格"
        case "calculate": return "计算"
        case "summarize": return "分组汇总"
        case "add_column": return "添加计算列"
        case "filter_view": return "筛选"
        case "select_cells": return "选中单元格"
        case "export_view": return "导出视图"
        case "edit_document": return "修改文档"
        case "rewrite_document": return "改写文档"
        default: return name
        }
    }

    static func summary(_ call: AIToolCall) -> String {
        let a = call.parsedArguments ?? .object([:])
        func file(_ k: String) -> String { (a[k]?.string).map { ($0 as NSString).lastPathComponent } ?? "" }
        let detail: String
        switch call.name {
        case "read_file": detail = file("path").isEmpty ? "当前文件" : file("path")
        case "view_image": detail = (file("path").isEmpty ? "当前文件" : file("path")) + ((a["page"]?.int).map { " 第 \($0) 页" } ?? "")
        case "list_folder": detail = file("path")
        case "search_text": detail = "「\(a["query"]?.string ?? "")」"
        case "write_file", "create_spreadsheet", "export_view", "open_file": detail = file("path")
        case "use_skill": detail = a["name"]?.string ?? ""
        case "find_skills": detail = "「\(a["query"]?.string ?? "")」"
        case "run_command": detail = a["command"]?.string ?? ""
        case "read_cells", "select_cells": detail = a["range"]?.string ?? ""
        case "calculate": detail = a["formula"]?.string ?? ""
        case "summarize":
            // Built in steps: as one expression, older compilers time out type-checking it.
            let groups: String = a["group_by"]?.stringList.joined(separator: "、") ?? ""
            let aggregate: String = SheetSummary.Aggregate(rawValue: a["aggregate"]?.string ?? "")?.title ?? ""
            let values: [String] = a["values"]?.stringList ?? []
            let valueText: String = values.isEmpty ? "" : " " + values.joined(separator: "、")
            detail = "按 \(groups) · \(aggregate)\(valueText)"
        case "add_column": detail = "\(a["name"]?.string ?? "")：\(a["formula"]?.string ?? "")"
        case "filter_view": detail = [a["column"]?.string, a["op"]?.string, a["value"]?.string].compactMap { $0 }.joined(separator: " ")
        case "edit_document": detail = String((a["find"]?.string ?? "").prefix(30))
        default: detail = ""
        }
        return verb(call.name) + (detail.isEmpty ? "" : " " + detail)
    }

    /// One line of result shown under the tool (the full output went to the model).
    static func resultLine(_ call: AIToolCall, _ out: AIToolOutput) -> String {
        let first = out.text.split(separator: "\n").first.map(String.init) ?? ""
        switch call.name {
        case "calculate": return out.isError ? first : (out.text.components(separatedBy: " = ").last ?? first)
        case "read_file", "read_cells", "sheet_overview", "list_folder", "use_skill":
            return out.isError ? first : "\(out.text.count) 字"
        default: return String(first.prefix(160))
        }
    }
}
