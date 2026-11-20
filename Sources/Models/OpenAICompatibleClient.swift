import Foundation

/// OpenAI 兼容协议客户端（`POST {base}/chat/completions`）。
///
/// 覆盖：OpenAI、DeepSeek、Moonshot/Kimi、通义、智谱、OpenRouter、硅基流动、
/// vLLM、Ollama、各类中转站。这类服务的差别几乎都在鉴权头和路径上，
/// 因此这里只做两件事：拼请求、解析 SSE delta。
public struct OpenAICompatibleClient: ModelClient {

    public init() {}

    public func stream(
        provider: ModelProvider,
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        tools: [ToolCapability],
        systemPrompt: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let name = provider.displayName
        let endpoint = provider.normalizedBaseURL + "/chat/completions"

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: endpoint) else {
                        throw LLMError.unreachable(provider: name, detail: "Base URL 不是合法地址")
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // OpenAI 兼容层只用 Bearer。不再附带 x-api-key：多投一份凭证副本
                    // 只会让第三方网关的日志多一个可以泄露 Key 的地方。
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    var body: [String: JSONValue] = [
                        "model": .string(model),
                        "stream": .bool(true),
                        "messages": .array(Self.buildMessages(messages, systemPrompt: systemPrompt))
                    ]
                    if !tools.isEmpty {
                        body["tools"] = .array(Self.buildTools(tools))
                        body["tool_choice"] = .string("auto")
                    }
                    guard let data = ModelHTTP.encodeBody(body) else {
                        throw LLMError.badRequest(provider: name, detail: "请求体编码失败")
                    }
                    request.httpBody = data

                    let session = ModelHTTP.makeSession()
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.malformedStream(provider: name, detail: "不是 HTTP 响应")
                    }
                    if !(200...299).contains(http.statusCode) {
                        // 只在失败路径读 body：bytes 是单遍异步序列，成功路径提前消费会把 SSE 流吃掉。
                        let errorBody = await ModelHTTP.readErrorBody(bytes)
                        if let error = ModelHTTP.mapStatus(
                            http.statusCode,
                            provider: name,
                            model: model,
                            body: errorBody
                        ) {
                            throw error
                        }
                        throw LLMError.serverError(provider: name, status: http.statusCode, detail: errorBody)
                    }

                    var sawFinish = false
                    var usage: TokenUsage?

                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish(throwing: LLMError.cancelled)
                            return
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }

                        guard let chunkData = String(payload).data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(JSONValue.self, from: chunkData),
                              let root = chunk.objectValue else {
                            // 单条解析失败不打断整条流：跳过即可，末尾会以 finish 收口。
                            continue
                        }

                        if let usageObject = root["usage"]?.objectValue {
                            usage = TokenUsage(
                                inputTokens: usageObject["prompt_tokens"]?.intValue,
                                outputTokens: usageObject["completion_tokens"]?.intValue
                            )
                        }

                        guard let choices = root["choices"]?.arrayValue,
                              let first = choices.first?.objectValue else {
                            continue
                        }

                        if let delta = first["delta"]?.objectValue {
                            if let text = delta["content"]?.stringValue, !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            }
                            if let calls = delta["tool_calls"]?.arrayValue {
                                for (offset, raw) in calls.enumerated() {
                                    guard let call = raw.objectValue else { continue }
                                    let index = call["index"]?.intValue ?? offset
                                    let id = call["id"]?.stringValue
                                    let function = call["function"]?.objectValue
                                    let toolName = function?["name"]?.stringValue
                                    let fragment = function?["arguments"]?.stringValue ?? ""
                                    // id/name 可能只在首片出现，fragment 可能很多片；全部原样下发给累加器。
                                    if id != nil || toolName != nil || !fragment.isEmpty {
                                        continuation.yield(.toolCallDelta(
                                            index: index,
                                            id: id,
                                            name: toolName,
                                            argumentsFragment: fragment
                                        ))
                                    }
                                }
                            }
                        }

                        if let reason = first["finish_reason"]?.stringValue {
                            sawFinish = true
                            continuation.yield(.finished(
                                reason: FinishReason(raw: reason),
                                usage: usage
                            ))
                        }
                    }

                    if !sawFinish {
                        // 某些网关不发 finish_reason 直接关流：按 stop 收口，
                        // 由上层用"是否收到 tool_call"来决定这也是不是 toolCalls。
                        continuation.yield(.finished(reason: .stop, usage: usage))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    if error.code == .cancelled {
                        continuation.finish(throwing: LLMError.cancelled)
                    } else {
                        continuation.finish(throwing: LLMError.unreachable(
                            provider: name,
                            detail: error.localizedDescription
                        ))
                    }
                } catch {
                    continuation.finish(throwing: LLMError.unreachable(
                        provider: name,
                        detail: error.localizedDescription
                    ))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 请求体构造

    static func buildMessages(_ messages: [ChatMessage], systemPrompt: String?) -> [JSONValue] {
        var result: [JSONValue] = []

        var systemText = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for message in messages where message.role == .system {
            if !systemText.isEmpty { systemText += "\n\n" }
            systemText += message.content
        }
        if !systemText.isEmpty {
            result.append(.object(["role": .string("system"), "content": .string(systemText)]))
        }

        for message in messages where message.role != .system {
            switch message.role {
            case .user:
                result.append(.object(["role": .string("user"), "content": .string(message.content)]))

            case .assistant:
                var object: [String: JSONValue] = [
                    "role": .string("assistant"),
                    "content": message.content.isEmpty ? .null : .string(message.content)
                ]
                if !message.toolCalls.isEmpty {
                    object["tool_calls"] = .array(message.toolCalls.map { call in
                        .object([
                            "id": .string(call.id),
                            "type": .string("function"),
                            "function": .object([
                                "name": .string(call.name),
                                "arguments": .string(call.argumentsJSON)
                            ])
                        ])
                    })
                }
                result.append(.object(object))

            case .tool:
                result.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.content)
                ]))

            case .system:
                continue
            }
        }
        return result
    }

    static func buildTools(_ tools: [ToolCapability]) -> [JSONValue] {
        tools.map { tool in
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string(tool.name),
                    "description": .string(tool.summary),
                    "parameters": tool.parameters
                ])
            ])
        }
    }
}