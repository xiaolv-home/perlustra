import Foundation
import Testing
@testable import PerlustraCore

@Suite("AI：接口格式")
struct AIWireTests {
    let local = AIEndpoint(proto: .openAI, baseURL: URL(string: "http://127.0.0.1:1234/v1")!, model: "qwen")
    let claude = AIEndpoint(proto: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-opus-5-5", apiKey: "k")

    func conversation() -> [AIMessage] {
        var a = AIMessage(role: .assistant, text: "我来算")
        a.toolCalls = [
            AIToolCall(id: "c1", name: "calculate", arguments: #"{"formula":"SUM(B:B)"}"#),
            AIToolCall(id: "c2", name: "sheet_overview", arguments: ""),
        ]
        return [
            .user("B 列合计？"), a,
            .toolResult(a.toolCalls[0], AIToolOutput("42")),
            .toolResult(a.toolCalls[1], .error("没有表格")),
        ]
    }

    @Test("OpenAI 兼容：工具调用和结果按顺序回传")
    func openAIBody() {
        let body = OpenAIWire.requestBody(
            endpoint: local, system: "sys", messages: conversation(),
            tools: [AIToolSpec("calculate", "算", Schema.object(["formula": Schema.string("公式")], required: ["formula"]))])
        let msgs = body["messages"]!.array!
        #expect(msgs.map { $0["role"]!.string! } == ["system", "user", "assistant", "tool", "tool"])
        #expect(msgs[2]["tool_calls"]?[1]?["function"]?["arguments"]?.string == "{}")
        #expect(msgs[3]["tool_call_id"]?.string == "c1")
        #expect(body["tools"]?[0]?["function"]?["name"]?.string == "calculate")
        #expect(body["stream"] == .bool(true))
        #expect(body["max_tokens"]?.int == 16384)
        var cloud = local
        cloud.baseURL = URL(string: "https://api.openai.com/v1")!
        #expect(OpenAIWire.requestBody(endpoint: cloud, system: "", messages: [], tools: [])["max_tokens"] == nil)
    }

    @Test("Claude：同一轮的工具结果合并成一条 user 消息，开启自适应思考和兜底")
    func anthropicBody() {
        let body = AnthropicWire.requestBody(endpoint: claude, system: "sys", messages: conversation(), tools: [AIToolSpec("calculate", "算")])
        let msgs = body["messages"]!.array!
        #expect(msgs.count == 3)
        #expect(msgs[1]["content"]?[1]?["type"]?.string == "tool_use")
        #expect(msgs[1]["content"]?[1]?["input"]?["formula"]?.string == "SUM(B:B)")
        let results = msgs[2]["content"]!.array!
        #expect(results.count == 2)
        #expect(results[1]["is_error"] == .bool(true))
        #expect(body["thinking"]?["type"]?.string == "adaptive")
        #expect(body["fallbacks"]?.string == "default")
        #expect(body["temperature"] == nil)
        #expect(body["tools"]?[0]?["eager_input_streaming"] == .bool(true))
        // A non-Claude model on an Anthropic-compatible server gets the plain request.
        var other = claude
        other.model = "deepseek-chat"
        other.baseURL = URL(string: "https://api.deepseek.com/anthropic")!
        let plain = AnthropicWire.requestBody(endpoint: other, system: "s", messages: [.user("hi")], tools: [])
        #expect(plain["thinking"] == nil && plain["fallbacks"] == nil)
    }

    @Test("看图：用户附图、工具返回的图，两种接口的格式")
    func images() {
        let img = AIImage(mediaType: "image/jpeg", base64: "QUJD")
        var u = AIMessage.user("这是什么图？")
        u.images = [img]
        var a = AIMessage(role: .assistant, text: "")
        a.toolCalls = [AIToolCall(id: "v1", name: "view_image", arguments: "{}"), AIToolCall(id: "v2", name: "calculate", arguments: "{}")]
        let r1 = AIMessage.toolResult(a.toolCalls[0], AIToolOutput("已附上图片", images: [img]))
        let r2 = AIMessage.toolResult(a.toolCalls[1], AIToolOutput("42"))
        let msgs = [u, a, r1, r2]

        let o = OpenAIWire.requestBody(endpoint: local, system: "s", messages: msgs, tools: [])["messages"]!.array!
        #expect(o[1]["content"]?[0]?["image_url"]?["url"]?.string == "data:image/jpeg;base64,QUJD")
        #expect(o[1]["content"]?[1]?["text"]?.string == "这是什么图？")
        // Tool results stay text; the picture follows both results as a user message.
        #expect(o.map { $0["role"]!.string! } == ["system", "user", "assistant", "tool", "tool", "user"])
        #expect(o[5]["content"]?[0]?["type"]?.string == "image_url")

        let c = AnthropicWire.requestBody(endpoint: claude, system: "s", messages: msgs, tools: [])["messages"]!.array!
        #expect(c[0]["content"]?[0]?["source"]?["data"]?.string == "QUJD")
        let results = c[2]["content"]!.array!
        #expect(results[0]["content"]?[1]?["type"]?.string == "image")
        #expect(results[1]["content"]?.string == "42")
    }

    @Test("Claude：思考块原样回传（带签名）")
    func anthropicReplay() {
        var acc = AnthropicWire.Accumulator()
        let events: [String] = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"想一想"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"SIG"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"好的"}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t1","name":"calculate","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"formula\":"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"1+1\"}"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]
        var texts: [String] = []
        for e in events {
            for ev in acc.consume(AIJSON.parse(e)!) { if case .text(let t) = ev { texts.append(t) } }
        }
        let (m, stop) = acc.finish()
        #expect(stop == .toolUse)
        #expect(texts == ["好的"])
        #expect(m.reasoning == "想一想")
        #expect(m.toolCalls.first?.parsedArguments?["formula"]?.string == "1+1")
        #expect(m.anthropicBlocks?[0]["signature"]?.string == "SIG")
        #expect(m.anthropicBlocks?[2]["input"]?["formula"]?.string == "1+1")
        let body = AnthropicWire.requestBody(endpoint: claude, system: "", messages: [.user("q"), m], tools: [])
        #expect(body["messages"]?[1]?["content"]?[0]?["signature"]?.string == "SIG")
    }

    @Test("OpenAI 兼容：分片的工具参数、<think> 标签、缺少 id")
    func openAIStream() {
        var acc = OpenAIWire.Accumulator()
        let chunks: [String] = [
            #"{"choices":[{"delta":{"content":"<thi"}}]}"#,
            #"{"choices":[{"delta":{"content":"nk>先想</think>答"}}]}"#,
            #"{"choices":[{"delta":{"reasoning_content":"另一种思考"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"calculate","arguments":"{\"formula\""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"2*3\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]
        for c in chunks { _ = acc.consume(AIJSON.parse(c)!) }
        let (m, stop) = acc.finish()
        #expect(m.text == "答")
        #expect(m.reasoning == "先想另一种思考")
        #expect(stop == .toolUse)
        #expect(m.toolCalls.count == 1)
        #expect(!m.toolCalls[0].id.isEmpty)
        #expect(m.toolCalls[0].parsedArguments?["formula"]?.string == "2*3")
    }

    @Test("对话可以存盘再读回（含 Claude 的思考签名、工具调用）")
    func messageCoding() throws {
        var a = AIMessage(role: .assistant, text: "我来算")
        a.toolCalls = [AIToolCall(id: "t1", name: "calculate", arguments: #"{"formula":"SUM(B:B)"}"#)]
        a.reasoning = "想一想"
        a.anthropicBlocks = [
            ["type": "thinking", "thinking": "想一想", "signature": "SIG"], ["type": "tool_use", "id": "t1", "input": ["n": 3, "one": 1, "zero": 0, "ok": true]],
        ]
        let msgs = [AIMessage.user("合计？"), a, .toolResult(a.toolCalls[0], .error("没有表格"))]
        let back = try JSONDecoder().decode([AIMessage].self, from: JSONEncoder().encode(msgs))
        #expect(back == msgs)
        #expect(back[1].anthropicBlocks?[1]["input"]?["ok"] == .bool(true))
    }

    @Test("JSON：数字、布尔、键排序稳定")
    func json() {
        let v: AIJSON = ["b": 1, "a": [true, 2.5, "x", nil]]
        #expect(v.encoded() == #"{"a":[true,2.5,"x",null],"b":1}"#)
        #expect(AIJSON.parse(#"{"n":3,"t":true}"#)?["t"] == .bool(true))
        #expect(AIJSON.parse(#"{"n":3}"#)?["n"]?.int == 3)
    }
}

/// Plays back scripted replies.
final class ScriptedClient: AIClient, @unchecked Sendable {
    var replies: [AIMessage]
    var seen: [[AIMessage]] = []
    init(_ replies: [AIMessage]) { self.replies = replies }
    func stream(system: String, messages: [AIMessage], tools: [AIToolSpec]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        seen.append(messages)
        let r = replies.removeFirst()
        return AsyncThrowingStream { c in
            if !r.text.isEmpty { c.yield(.text(r.text)) }
            c.yield(.finished(r, r.toolCalls.isEmpty ? .done : .toolUse))
            c.finish()
        }
    }
}

actor EventLog {
    var events: [AIAgent.Event] = []
    func add(_ e: AIAgent.Event) { events.append(e) }
}

@Suite("AI：工具循环")
struct AgentTests {
    @Test("调用工具 → 回传结果 → 得到最终回答；坏参数回错误")
    func loop() async throws {
        var first = AIMessage(role: .assistant, text: "")
        first.toolCalls = [
            AIToolCall(id: "a", name: "calculate", arguments: #"{"formula":"1+1"}"#),
            AIToolCall(id: "b", name: "calculate", arguments: "{oops"),
        ]
        let client = ScriptedClient([first, AIMessage(role: .assistant, text: "结果是 2")])
        let log = EventLog()
        try await AIAgent.run(
            client: client, system: "", history: [.user("1+1")], tools: [],
            runTool: { call, args in AIToolOutput(args["formula"]?.string == "1+1" ? "2" : "?") },
            onEvent: { await log.add($0) })
        let messages = await log.events.compactMap { e -> AIMessage? in
            if case .message(let m) = e { return m }; return nil
        }
        #expect(messages.map(\.role) == [.assistant, .tool, .tool, .assistant])
        #expect(messages[1].text == "2")
        #expect(messages[2].isError)
        #expect(messages[3].text == "结果是 2")
        // The second request carried the tool results.
        #expect(client.seen[1].count == 4)
    }

    @Test("超长输出会截断并提示")
    func clip() {
        let o = AIAgent.clip(AIToolOutput(String(repeating: "字", count: AIAgent.maxToolOutput + 10)))
        #expect(o.text.contains("已截断"))
    }
}

@Suite("AI：技能")
struct SkillTests {
    @Test("SKILL.md 头信息：引号、折叠块")
    func frontMatter() {
        let text = """
            ---
            name: contract-review
            description: >
              审阅合同，
              找出风险条款
            license: "MIT"
            ---
            # 合同审阅
            步骤……
            """
        let (meta, body) = SkillLibrary.parseFrontMatter(text)
        #expect(meta["name"] == "contract-review")
        #expect(meta["description"] == "审阅合同， 找出风险条款")
        #expect(meta["license"] == "MIT")
        #expect(body.hasPrefix("# 合同审阅"))
    }

    @Test("按请求挑出相关技能（中文按字对，英文按词）")
    func rank() {
        func sk(_ n: String, _ d: String) -> Skill { Skill(name: n, description: d, folder: URL(fileURLWithPath: "/x/\(n)"), builtIn: false) }
        let all = [
            sk("resume-optimizer", "面向求职者的简历审计与优化"), sk("contract-review", "Review legal contracts and NDAs"),
            sk("合同审查-国企", "国有企业合同合规审查"), sk("mermaid", "Generate Mermaid diagrams"),
        ]
        #expect(SkillLibrary.rank(all, for: "帮我优化一下简历").first?.name == "resume-optimizer")
        #expect(SkillLibrary.rank(all, for: "审查这份采购合同").first?.name == "合同审查-国企")
        #expect(SkillLibrary.rank(all, for: "review this contract").first?.name == "contract-review")
        #expect(SkillLibrary.rank(all, for: "今天天气").isEmpty)
    }

    @Test("GitHub 链接解析")
    func parseURL() {
        #expect(SkillInstaller.parse("https://github.com/wyh0626/resume-optimizer") == .init(owner: "wyh0626", repo: "resume-optimizer", ref: nil, path: ""))
        let s = SkillInstaller.parse("github.com/appautomaton/document-SKILLs/tree/main/xlsx")
        #expect(s?.ref == "main" && s?.path == "xlsx")
        #expect(SkillInstaller.parse("https://github.com/a/b/blob/dev/skills/x/SKILL.md")?.path == "skills/x")
        #expect(SkillInstaller.parse("owner/repo")?.repo == "repo")
        #expect(SkillInstaller.parse("https://github.com/owner/repo?tab=readme-ov-file#readme")?.repo == "repo")
        #expect(SkillInstaller.parse("https://github.com/owner/bad repo") == nil)
        #expect(SkillInstaller.parse("not a url") == nil)
    }

    @Test("安装技能时拦截反斜杠穿越且不残留 .staging 目录")
    func installSafetyAndStagingCleanup() throws {
        let files: [String: Data] = [
            "repo-main/SKILL.md": Data("---\nname: safe\n---\nok".utf8),
            "repo-main/sub\\..\\..\\outside.txt": Data("evil".utf8),
        ]
        let dest = TestTemp.dir("skills-safe")
        let src = SkillInstaller.Source(owner: "o", repo: "repo", ref: "main", path: "")
        let skills = try SkillInstaller.installFiles(files, source: src, into: dest)
        #expect(skills.count == 1)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        #expect(!entries.contains { $0.hasPrefix(".staging-") })
        #expect(!FileManager.default.fileExists(atPath: dest.deletingLastPathComponent().appendingPathComponent("outside.txt").path))
    }

    @Test("从仓库包里挑出技能文件夹（带上许可证和来源）")
    func installFromArchive() throws {
        let files: [String: Data] = [
            "repo-main/LICENSE": Data("MIT".utf8),
            "repo-main/README.md": Data("readme".utf8),
            "repo-main/skills/resume/SKILL.md": Data("---\nname: 简历\ndescription: 改简历\n---\n正文".utf8),
            "repo-main/skills/resume/references/tips.md": Data("tips".utf8),
            "repo-main/skills/resume/examples/SKILL.md": Data("nested".utf8),
            "repo-main/skills/legal/SKILL.md": Data("# 法务\n审合同".utf8),
            "repo-main/.github/workflows/ci.yml": Data("x".utf8),
        ]
        let dest = TestTemp.dir("skills")
        let src = SkillInstaller.Source(owner: "o", repo: "repo", ref: "main", path: "")
        let skills = try SkillInstaller.installFiles(files, source: src, into: dest)
        #expect(skills.map(\.name).sorted() == ["legal", "简历"])
        let resume = skills.first { $0.name == "简历" }!
        #expect(resume.resourceFiles().contains("references/tips.md"))
        #expect(FileManager.default.fileExists(atPath: resume.folder.appendingPathComponent("LICENSE").path))
        #expect(resume.source == "https://github.com/o/repo/tree/main/skills/resume")
        #expect(resume.instructions() == "正文")
        #expect(skills.first { $0.name == "legal" }?.description == "审合同")
        // Nothing found → a clear error.
        #expect(throws: AIError.self) {
            try SkillInstaller.installFiles(["r-main/a.txt": Data()], source: src, into: dest)
        }
    }
}

@Suite("AI：生成文档与汇总")
struct AIOutputTests {
    @Test("Markdown 转 HTML：标题、列表、表格、强调")
    func markdown() {
        let html = MarkdownHTML.render(
            """
            # 审阅意见
            **甲方**：某公司 <x>

            - 第一条
            - 第二条

            1. 甲
            2. 乙

            | 条款 | 风险 |
            | --- | --- |
            | 第 5 条 | *高* |
            """)
        #expect(html.contains("<h1>审阅意见</h1>"))
        #expect(html.contains("<strong>甲方</strong>：某公司 &lt;x&gt;"))
        #expect(html.contains("<ul><li>第一条</li><li>第二条</li></ul>"))
        #expect(html.contains("<ol><li>甲</li><li>乙</li></ol>"))
        #expect(html.contains("<td><em>高</em></td>"))
    }

    @Test("行内格式：加粗、斜体、代码、链接，未闭合的星号原样保留")
    func inlineRuns() {
        let r = MarkdownParser.runs("**甲方**付款 *30* 天，见 `第5条` 与 [附件](https://x.cn)，2*3")
        #expect(
            r.first
                == {
                    var x = MarkdownRun("甲方"); x.bold = true; return x
                }())
        #expect(r.contains { $0.italic && $0.text == "30" })
        #expect(r.contains { $0.code && $0.text == "第5条" })
        #expect(r.contains { $0.link == "https://x.cn" && $0.text == "附件" })
        #expect(MarkdownParser.plain("**甲方**付款 2*3") == "甲方付款 2*3")
    }

    @Test("Word：原生表格、标题样式、编号列表，XML 合法")
    func docx() throws {
        let url = TestTemp.dir("docx").appendingPathComponent("意见书.docx")
        try DocxWriter.write(
            markdown: """
                # 审阅意见书
                **立场**：甲方 & 合作方 <内部>

                ## 主要风险
                | 序号 | 条款 | 建议 |
                | --- | --- | --- |
                | 1 | 第二条 | 改为分期<br>先付 20% |

                1. 第一项
                2. 第二项

                - 要点
                """, title: "意见书", to: url)
        let parts = try ArchiveReader.extractAll(url: url) { _ in true }
        for (name, data) in parts where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            #expect(XMLParser(data: data).parse(), "\(name) 不是合法 XML")
        }
        let doc = String(decoding: parts["word/document.xml"]!, as: UTF8.self)
        #expect(doc.contains("<w:pStyle w:val=\"Heading1\"/>"))
        #expect(doc.contains("<w:tbl>") && doc.contains("<w:tblHeader/>"))
        #expect(doc.contains("<w:numId w:val=\"2\"/>") && doc.contains("<w:numId w:val=\"1\"/>"))
        #expect(doc.contains("甲方 &amp; 合作方 &lt;内部&gt;"))
        #expect(doc.contains("改为分期"))
        // 序号 stays narrow, the explanation column gets the room.
        let w = DocxWriter.columnWidths(["序号", "问题说明"], [["1", "签约后三日内一次性支付全部款项，甲方丧失全部履约杠杆"]], cols: 2, total: 9000)
        #expect(w[0] < 2000 && w[1] > 7000 && abs(w.reduce(0, +) - 9000) < 3)
    }

    @Test("图片文字按行还原：同一行按左右排序，列之间是制表符")
    func ocrRows() {
        func p(_ t: String, _ x: Double, _ y: Double, _ w: Double = 0.1) -> OCRLayout.Piece { .init(text: t, box: CGRect(x: x, y: y, width: w, height: 0.03)) }
        let text = OCRLayout.rows([
            p("4549.38", 0.6, 0.801), p("门店001", 0.05, 0.8), p("上海", 0.3, 0.799),
            p("门店", 0.05, 0.9), p("城市", 0.3, 0.9), p("营业额", 0.6, 0.9),
        ])
        #expect(text == "门店\t城市\t营业额\n门店001\t上海\t4549.38")
    }

    @Test("分组汇总：按门店合计、总计行、降序")
    func groupBy() {
        var s = Sheet(
            name: "s",
            rows: [
                [.text("门店"), .text("金额")],
                [.text("A"), .number(10)], [.text("B"), .number(30)], [.text("A"), .number(5)], [.text("C"), .text("n/a")],
            ])
        s.columnCount = 2
        let t = SheetSummary.groupBy(s, rows: Array(1..<5), header: 0, groupColumns: [0], valueColumns: [1], aggregate: .sum)
        #expect(t[0] == [.text("门店"), .text("金额（合计）")])
        #expect(t[1] == [.text("B"), .number(30)])
        #expect(t[2] == [.text("A"), .number(15)])
        #expect(t.last == [.text("总计"), .number(45)])
        let counts = SheetSummary.groupBy(s, rows: Array(1..<5), header: 0, groupColumns: [0], valueColumns: [], aggregate: .count)
        #expect(counts[1] == [.text("A"), .number(2)])
    }
}
