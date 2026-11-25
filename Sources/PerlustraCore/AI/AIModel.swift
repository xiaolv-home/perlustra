import Foundation

/// Which wire protocol an endpoint speaks. "OpenAI-compatible" covers local servers (LM Studio,
/// Ollama, llama.cpp, mlx) and most cloud APIs (DeepSeek, 通义, Kimi, 智谱, OpenAI, OpenRouter).
public enum AIProtocol: String, Sendable, Codable, CaseIterable {
    case openAI
    case anthropic
}

public struct AIEndpoint: Sendable, Equatable {
    public var proto: AIProtocol
    /// OpenAI-compatible: the base including /v1 (…/v1/chat/completions is appended).
    /// Anthropic: the host (…/v1/messages is appended).
    public var baseURL: URL
    public var model: String
    public var apiKey: String?

    public init(proto: AIProtocol, baseURL: URL, model: String, apiKey: String? = nil) {
        self.proto = proto
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public var isLocal: Bool {
        guard let h = baseURL.host?.lowercased() else { return false }
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasSuffix(".local")
            || h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("100.")
    }
}

public struct AIToolCall: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    /// The arguments as the model wrote them (JSON text, possibly invalid).
    public var arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
    public var parsedArguments: AIJSON? {
        let t = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? .object([:]) : AIJSON.parse(t)
    }
}

public struct AIToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: AIJSON
    public init(_ name: String, _ description: String, _ parameters: AIJSON = Schema.object([:])) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A picture handed to a model that can see (JPEG/PNG, base64).
public struct AIImage: Sendable, Equatable, Codable {
    public var mediaType: String
    public var base64: String
    public init(mediaType: String, base64: String) {
        self.mediaType = mediaType
        self.base64 = base64
    }
    public var dataURL: String { "data:\(mediaType);base64,\(base64)" }
}

/// One turn of the conversation, provider-neutral.
/// Codable so conversations can be saved and picked up again later.
public struct AIMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant, tool }
    public var role: Role
    public var text: String
    /// Assistant: the tools it asked to run.
    public var toolCalls: [AIToolCall] = []
    /// Tool result: which call it answers.
    public var toolCallID: String?
    public var isError = false
    /// Assistant: the model's visible reasoning, if any.
    public var reasoning: String?
    /// Assistant turns from the Anthropic API, exactly as returned (thinking blocks carry
    /// signatures and must go back unchanged).
    public var anthropicBlocks: [AIJSON]?
    /// User turns and tool results: pictures the model should look at.
    public var images: [AIImage]?

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    public static func user(_ text: String) -> AIMessage { AIMessage(role: .user, text: text) }

    public static func toolResult(_ call: AIToolCall, _ output: AIToolOutput) -> AIMessage {
        var m = AIMessage(role: .tool, text: output.text)
        m.toolCallID = call.id
        m.isError = output.isError
        m.images = output.images
        return m
    }
}

public struct AIToolOutput: Sendable, Equatable {
    public var text: String
    public var isError: Bool
    /// Pictures returned for the model to look at (view_image).
    public var images: [AIImage]?
    /// Files produced on disk by this tool call, scoped to the owning AI session.
    public var createdFiles: [URL]
    public init(_ text: String, isError: Bool = false, images: [AIImage]? = nil, createdFiles: [URL] = []) {
        self.text = text
        self.isError = isError
        self.images = images
        self.createdFiles = createdFiles
    }
    public static func error(_ text: String) -> AIToolOutput { AIToolOutput(text, isError: true) }
}

public enum AIStopReason: String, Sendable {
    case done, toolUse, maxTokens, refused, other
}

/// What a streaming request reports: text as it arrives, then the whole assistant message.
public enum AIStreamEvent: Sendable {
    case text(String)
    case reasoning(String)
    /// A tool call has begun streaming (its name), so the UI can say what is coming.
    case toolCallStarted(String)
    case finished(AIMessage, AIStopReason)
}

public struct AIError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public protocol AIClient: Sendable {
    func stream(system: String, messages: [AIMessage], tools: [AIToolSpec]) -> AsyncThrowingStream<AIStreamEvent, Error>
}

public enum AIClients {
    public static func make(_ e: AIEndpoint, session: URLSession = AIHTTP.session) -> AIClient {
        switch e.proto {
        case .openAI: return OpenAIClient(endpoint: e, session: session)
        case .anthropic: return AnthropicClient(endpoint: e, session: session)
        }
    }

    /// The models an endpoint offers (embedding models left out).
    public static func listModels(_ e: AIEndpoint, session: URLSession = AIHTTP.session) async throws -> [String] {
        var req: URLRequest
        switch e.proto {
        case .openAI:
            req = URLRequest(url: e.baseURL.appendingPathComponent("models"))
            if let k = e.apiKey, !k.isEmpty { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            req = URLRequest(url: e.baseURL.appendingPathComponent("v1/models"))
            AnthropicClient.authorize(&req, e)
        }
        req.timeoutInterval = 8
        let (data, resp) = try await session.data(for: req)
        try AIHTTP.check(resp, data, endpoint: e)
        let ids = AIJSON.parse(data)?["data"]?.array?.compactMap { $0["id"]?.string } ?? []
        return ids.filter { !$0.lowercased().contains("embed") }
    }
}

public enum AIHTTP {
    /// Long-running generations: no request timeout beyond the per-chunk idle limit.
    public static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 3600
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Turns HTTP failures into messages a person can act on.
    public static func check(_ resp: URLResponse, _ body: Data, endpoint: AIEndpoint) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let detail =
            AIJSON.parse(body).flatMap { j in
                j["error"]?["message"]?.string ?? j["error"]?.string ?? j["message"]?.string
            } ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch http.statusCode {
        case 401, 403: throw AIError("API Key 不对或没有权限（\(detail)）")
        case 404: throw AIError("找不到模型「\(endpoint.model)」或接口地址不对（\(detail)）")
        case 429: throw AIError("请求太频繁或额度用完了，稍后再试（\(detail)）")
        case 400: throw AIError("请求被拒绝：\(detail)")
        default: throw AIError("服务出错（\(http.statusCode)）：\(detail)")
        }
    }

    public static func describe(_ error: Error, endpoint: AIEndpoint) -> String {
        if let e = error as? AIError { return e.message }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return endpoint.isLocal
                    ? "连不上本地模型（\(endpoint.baseURL.host ?? "")）。LM Studio / Ollama 打开了吗？"
                    : "连不上 \(endpoint.baseURL.host ?? "服务器")，检查一下网络"
            case NSURLErrorTimedOut: return "等太久没有回应，模型可能太忙了"
            case NSURLErrorNotConnectedToInternet: return "没有网络连接"
            case NSURLErrorCancelled: return "已停止"
            default: break
            }
        }
        return error.localizedDescription
    }

    /// Server-sent events: yields each `data:` payload.
    static func events(_ req: URLRequest, session: URLSession, endpoint: AIEndpoint) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, resp) = try await session.bytes(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 8192 { break } }
            try check(resp, body, endpoint: endpoint)
        }
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        cont.yield(payload)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
