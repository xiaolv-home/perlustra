import Foundation

/// Runs the model until it stops asking for tools: stream a reply, run the tools it called,
/// send the results back, repeat. History is only ever appended to.
public enum AIAgent {
    public enum Event: Sendable {
        case text(String)
        case reasoning(String)
        case toolPreparing(String)
        case toolStarted(AIToolCall)
        case toolFinished(AIToolCall, AIToolOutput)
        /// A complete message to append to the conversation (assistant turns and tool results).
        case message(AIMessage)
        case stopped(AIStopReason)
    }

    public typealias ToolRunner = @Sendable (AIToolCall, AIJSON) async -> AIToolOutput
    public typealias EventSink = @Sendable (Event) async -> Void

    /// Longest tool output sent back to the model; the tool says how to read more.
    public static let maxToolOutput = 24_000

    public static func run(
        client: AIClient, system: String, history: [AIMessage], tools: [AIToolSpec],
        maxSteps: Int = 24, runTool: ToolRunner, onEvent: EventSink
    ) async throws {
        var messages = history
        for _ in 0..<maxSteps {
            var final: AIMessage?
            var stop = AIStopReason.done
            for try await ev in client.stream(system: system, messages: messages, tools: tools) {
                switch ev {
                case .text(let t): await onEvent(.text(t))
                case .reasoning(let t): await onEvent(.reasoning(t))
                case .toolCallStarted(let n): await onEvent(.toolPreparing(n))
                case .finished(let m, let s): final = m; stop = s
                }
            }
            try Task.checkCancellation()
            guard let reply = final else { throw AIError("模型没有返回内容") }
            messages.append(reply)
            await onEvent(.message(reply))
            if reply.toolCalls.isEmpty {
                await onEvent(.stopped(stop))
                return
            }
            for call in reply.toolCalls {
                // Every call gets a result, even after a stop, so the history stays valid.
                let output: AIToolOutput
                if Task.isCancelled {
                    output = .error("用户已停止")
                } else if stop == .maxTokens {
                    output = .error("回复被截断，参数不完整。请把内容分成几次较小的调用。")
                } else if let args = call.parsedArguments {
                    await onEvent(.toolStarted(call))
                    output = clip(await runTool(call, args))
                } else {
                    output = .error("参数不是有效的 JSON：\(call.arguments.prefix(200))")
                }
                await onEvent(.toolFinished(call, output))
                let result = AIMessage.toolResult(call, output)
                messages.append(result)
                await onEvent(.message(result))
            }
            try Task.checkCancellation()
        }
        await onEvent(.stopped(.other))
    }

    static func clip(_ o: AIToolOutput) -> AIToolOutput {
        guard o.text.count > maxToolOutput else { return o }
        return AIToolOutput(
            String(o.text.prefix(maxToolOutput)) + "\n…（输出过长已截断，共 \(o.text.count) 字；需要后面的内容请带 offset 再读）",
            isError: o.isError,
            images: o.images,
            createdFiles: o.createdFiles
        )
    }
}
