import Foundation
import PerlustraCore

/// A cloud service the AI can use. Most speak the OpenAI-compatible protocol; Claude speaks its own.
struct CloudProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let proto: AIProtocol
    let baseURL: String
    let defaultModel: String
    /// Where to get a key.
    let keyPage: String
    /// Built-in hosts are pinned. Only 自定义 and 豆包 (regional endpoints) may change the base URL.
    var allowsCustomBaseURL: Bool { id == "custom" || id == "doubao" }

    static let all: [CloudProvider] = [
        CloudProvider(
            id: "deepseek", name: "DeepSeek", proto: .openAI, baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat",
            keyPage: "https://platform.deepseek.com/api_keys"),
        CloudProvider(
            id: "qwen", name: "通义千问（阿里云百炼）", proto: .openAI, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-plus", keyPage: "https://bailian.console.aliyun.com/?apiKey=1"),
        CloudProvider(
            id: "kimi", name: "Kimi（月之暗面）", proto: .openAI, baseURL: "https://api.moonshot.cn/v1", defaultModel: "kimi-latest",
            keyPage: "https://platform.moonshot.cn/console/api-keys"),
        CloudProvider(
            id: "zhipu", name: "智谱 GLM", proto: .openAI, baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "glm-4-plus",
            keyPage: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys"),
        CloudProvider(
            id: "doubao", name: "豆包（火山方舟）", proto: .openAI, baseURL: "https://ark.cn-beijing.volces.com/api/v3", defaultModel: "",
            keyPage: "https://console.volcengine.com/ark"),
        CloudProvider(
            id: "siliconflow", name: "硅基流动", proto: .openAI, baseURL: "https://api.siliconflow.cn/v1", defaultModel: "deepseek-ai/DeepSeek-V3",
            keyPage: "https://cloud.siliconflow.cn/account/ak"),
        CloudProvider(
            id: "anthropic", name: "Claude（Anthropic）", proto: .anthropic, baseURL: "https://api.anthropic.com", defaultModel: "claude-opus-5-5",
            keyPage: "https://console.anthropic.com/settings/keys"),
        CloudProvider(
            id: "openai", name: "OpenAI", proto: .openAI, baseURL: "https://api.openai.com/v1", defaultModel: "gpt-5",
            keyPage: "https://platform.openai.com/api-keys"),
        CloudProvider(
            id: "openrouter", name: "OpenRouter", proto: .openAI, baseURL: "https://openrouter.ai/api/v1", defaultModel: "openrouter/auto",
            keyPage: "https://openrouter.ai/keys"),
        CloudProvider(id: "custom", name: "自定义（OpenAI 兼容）", proto: .openAI, baseURL: "", defaultModel: "", keyPage: ""),
    ]

    static func find(_ id: String) -> CloudProvider { all.first { $0.id == id } ?? all[0] }
}

/// The AI's settings: which mode, where the models are, and what it may do.
@MainActor
final class AIConfig: ObservableObject {
    static let shared = AIConfig()
    private let d = UserDefaults.standard
    /// The debug harness may pick a model for its runs without changing the user's choice.
    private func save(_ v: Any, _ key: String) { if !AppEnvironment.isScripted { d.set(v, forKey: key) } }

    enum Mode: String { case local, cloud }

    @Published var mode: Mode { didSet { save(mode.rawValue, "ai.mode") } }
    @Published var localBaseURL: String { didSet { save(localBaseURL, "ai.local.base") } }
    @Published var localModel: String { didSet { save(localModel, "ai.local.model") } }
    @Published var providerID: String { didSet { save(providerID, "ai.cloud.provider") } }
    /// Per-provider overrides (base URL for 自定义 / 豆包 endpoints, chosen model).
    @Published var cloudBaseURLs: [String: String] { didSet { save(cloudBaseURLs, "ai.cloud.bases") } }
    @Published var cloudModels: [String: String] { didSet { save(cloudModels, "ai.cloud.models") } }
    /// The AI may run Terminal commands (each one still needs a click to allow).
    @Published var allowCommands: Bool { didSet { save(allowCommands, "ai.allowCommands") } }
    /// Skills switched off (by folder path).
    @Published var disabledSkills: Set<String> { didSet { save(Array(disabledSkills), "ai.disabledSkills") } }

    private init() {
        mode = Mode(rawValue: d.string(forKey: "ai.mode") ?? "") ?? .local
        localBaseURL = d.string(forKey: "ai.local.base") ?? "http://127.0.0.1:1234/v1"
        localModel = d.string(forKey: "ai.local.model") ?? ""
        providerID = d.string(forKey: "ai.cloud.provider") ?? "deepseek"
        cloudBaseURLs = d.dictionary(forKey: "ai.cloud.bases") as? [String: String] ?? [:]
        cloudModels = d.dictionary(forKey: "ai.cloud.models") as? [String: String] ?? [:]
        allowCommands = d.bool(forKey: "ai.allowCommands")
        disabledSkills = Set(d.stringArray(forKey: "ai.disabledSkills") ?? [])
    }

    var provider: CloudProvider { CloudProvider.find(providerID) }

    func cloudBaseURL(_ p: CloudProvider) -> String {
        guard p.allowsCustomBaseURL else { return p.baseURL }
        let override = cloudBaseURLs[p.id] ?? ""
        return override.isEmpty ? p.baseURL : override
    }
    func cloudModel(_ p: CloudProvider) -> String { cloudModels[p.id].flatMap { $0.isEmpty ? nil : $0 } ?? p.defaultModel }

    func apiKey(_ p: CloudProvider) -> String? { AIKeyStore.shared.key(p.id) }
    func setAPIKey(_ key: String, for p: CloudProvider) {
        AIKeyStore.shared.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: p.id)
        objectWillChange.send()
    }

    /// Where requests go right now, or what is missing.
    func endpoint() throws -> AIEndpoint {
        switch mode {
        case .local:
            guard let u = URL(string: localBaseURL.trimmingCharacters(in: .whitespaces)), u.host != nil else { throw AIError("本地模型地址不对，请在设置里检查") }
            guard FileAccessPolicy.isLoopback(url: u) else {
                throw AIError("本地模式只连接本机（localhost 或 127.0.0.1）。访问其他地址请改用「云端 API」里的自定义服务。")
            }
            guard !localModel.isEmpty else { throw AIError("还没选本地模型。打开 LM Studio / Ollama 后在 AI 面板顶部选一个") }
            return AIEndpoint(proto: .openAI, baseURL: u, model: localModel)
        case .cloud:
            let p = provider
            guard let u = URL(string: cloudBaseURL(p)), u.host != nil else { throw AIError("请在设置里填写「\(p.name)」的接口地址") }
            guard let key = apiKey(p), !key.isEmpty else { throw AIError("还没填「\(p.name)」的 API Key（设置 › AI）") }
            let model = cloudModel(p)
            guard !model.isEmpty else { throw AIError("请在设置里选择「\(p.name)」的模型") }
            return AIEndpoint(proto: p.proto, baseURL: u, model: model, apiKey: key)
        }
    }

    var summary: String {
        switch mode {
        case .local: return localModel.isEmpty ? "本地 · 未选模型" : "本地 · " + Self.shortModel(localModel)
        case .cloud: return "云端 · " + provider.name.components(separatedBy: "（").first! + " · " + Self.shortModel(cloudModel(provider))
        }
    }

    static func shortModel(_ m: String) -> String { m.split(separator: "/").last.map(String.init) ?? m }

    /// Finds a running local model server (LM Studio, Ollama, llama.cpp, vLLM) and its models.
    func detectLocal() async -> (base: String, models: [String])? {
        var candidates = [localBaseURL]
        for c in ["http://127.0.0.1:1234/v1", "http://127.0.0.1:11434/v1", "http://127.0.0.1:8080/v1", "http://127.0.0.1:8000/v1"] where !candidates.contains(c)
        {
            candidates.append(c)
        }
        for c in candidates {
            guard let u = URL(string: c), FileAccessPolicy.isLoopback(url: u) else { continue }
            if let models = try? await AIClients.listModels(AIEndpoint(proto: .openAI, baseURL: u, model: "")), !models.isEmpty {
                return (c, models)
            }
        }
        return nil
    }
}

/// API keys, in a file only this Mac account can read (~/Library/Application Support/Perlustra/
/// ai-keys.json, mode 600), read once and kept in memory.
///
/// Not the keychain: Perlustra is signed locally, so every new build looks like a different app
/// to the keychain and macOS asked for the login password again and again.
@MainActor
final class AIKeyStore {
    static let shared = AIKeyStore()
    private var keys: [String: String] = [:]

    private static var file: URL {
        let base =
            AppEnvironment.isScripted
            ? FileManager.default.temporaryDirectory.appendingPathComponent("perlustra-harness-keys")
            : AppPaths.applicationSupport
        return base.appendingPathComponent("ai-keys.json")
    }

    private init() {
        // Keys from earlier versions stay in the keychain unread: reading them is exactly what
        // made macOS ask for the password. They are pasted in once more.
        if let d = try? Data(contentsOf: Self.file), let k = try? JSONDecoder().decode([String: String].self, from: d) {
            keys = k
        }
    }

    func key(_ provider: String) -> String? { keys[provider].flatMap { $0.isEmpty ? nil : $0 } }

    func set(_ key: String, for provider: String) {
        keys[provider] = key.isEmpty ? nil : key
        save()
    }

    private func save() {
        let fm = FileManager.default
        let dir = Self.file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let d = try? JSONEncoder().encode(keys) else { return }
        // Create the inode with mode 0600 before writing bytes so keys are never world-readable.
        let tmp = dir.appendingPathComponent(".ai-keys-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return }
        if Darwin.rename(tmp.path, Self.file.path) != 0 {
            try? fm.removeItem(at: tmp)
        }
    }
}
