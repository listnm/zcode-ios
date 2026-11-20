import Foundation

/// Anthropic Messages API 客户端（`POST {base}/messages`）。
///
/// 与 OpenAI 的三处结构性差异，是本文件存在的理由：
/// 1. 工具调用不是增量 JSON 字符串，而是 `content_block_start` 声明 id/name，
///    随后 `input_json_delta` 分片；必须按 block index 聚合。
/// 2. 工具结果不是 `role: "tool"` 消息，而是 **user 消息里的 `tool_result` block**，
///    且连续的多个结果要合并进同一条 user 消息，否则 API 会报错。
/// 3. 结束原因是 `message_delta.stop_reason`（`tool_use`），不是 `finish_reason`。
public struct AnthropicClient: ModelClient {

    /// Anthropic 必填参数。取一个对主流 Claude 模型都合法的值。
    private static let maxTokens = 4096

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
        let endpoint = provider.normalizedBaseURL + "/messages"

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
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    // 必填；版本号写死为当前稳定值。
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    var body: [String: JSONValue] = [
                        "model": .string(model),
                        "max_tokens": .number(Double(Self.maxTokens)),
                        "stream": .bool(true),
                        "messages": .array(Self.buildMessages(messages))
                    ]

                    var systemText = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    for message in messages where message.role == .system {
                        if !systemText.isEmpty { systemText += "\n\n" }
                        systemText += message.content
                    }
                    if !systemText.isEmpty {
                        body["system"] = .string(systemText)
                    }
                    if !tools.isEmpty {
                        body["tools"] = .array(tools.map { tool in
                            .object([
                                "name": .string(tool.name),
                                "description": .string(tool.summary),
                                "input_schema": tool.parameters
                            ])
                        })
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
                        // 同 OpenAI 客户端：bytes 只能消费一次，成功路径不能先读 body。
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

                    var usage = TokenUsage()
                    var sawFinish = false
                    var currentEventName = ""

                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish(throwing: LLMError.cancelled)
                            return
                        }

                        if line.hasPrefix("event:") {
                            currentEventName = String(line.dropFirst(6)
                                .trimmingCharacters(in: .whitespaces))
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }

                        guard let chunkData = String(payload).data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(JSONValue.self, from: chunkData),
                              let root = chunk.objectValue else {
                            continue
                        }

                        let type = root["type"]?.stringValue ?? currentEventName

                        switch type {
                        case "message_start":
                            if let message = root["message"]?.objectValue,
                               let usageObject = message["usage"]?.objectValue {
                                usage.inputTokens = usageObject["input_tokens"]?.intValue
                            }

                        case "content_block_start":
                            let index = root["index"]?.intValue ?? 0
                            if let block = root["content_block"]?.objectValue,
                               block["type"]?.stringValue == "tool_use" {
                                // 先声明 id 与 name；参数随后由 input_json_delta 补齐。
                                continuation.yield(.toolCallDelta(
                                    index: index,
                                    id: block["id"]?.stringValue,
                                    name: block["name"]?.stringValue,
                                    argumentsFragment: ""
                                ))
                            }

                        case "content_block_delta":
                            let index = root["index"]?.intValue ?? 0
                            guard let delta = root["delta"]?.objectValue else { continue }
                            switch delta["type"]?.stringValue {
                            case "text_delta":
                                if let text = delta["text"]?.stringValue, !text.isEmpty {
                                    continuation.yield(.textDelta(text))
                                }
                            case "input_json_delta":
                                let fragment = delta["partial_json"]?.stringValue ?? ""
                                if !fragment.isEmpty {
                                    continuation.yield(.toolCallDelta(
                                        index: index,
                                        id: nil,
                                        name: nil,
                                        argumentsFragment: fragment
                                    ))
                                }
                            default:
                                continue
                            }

                        case "message_delta":
                            if let usageObject = root["usage"]?.objectValue {
                                usage.outputTokens = usageObject["output_tokens"]?.intValue
                            }
                            if let delta = root["delta"]?.objectValue,
                               let reason = delta["stop_reason"]?.stringValue {
                                sawFinish = true
                                continuation.yield(.finished(
                                    reason: FinishReason(raw: reason),
                                    usage: usage
                                ))
                            }

                        case "message_stop":
                            if !sawFinish {
                                continuation.yield(.finished(reason: .stop, usage: usage))
                            }

                        case "error":
                            let errorObject = root["error"]?.objectValue
                            let errorType = errorObject?["type"]?.stringValue ?? ""
                            let message = errorObject?["message"]?.stringValue ?? "未知错误"
                            switch errorType {
                            case "authentication_error", "permission_error":
                                throw LLMError.invalidAPIKey(provider: name, detail: message)
                            case "rate_limit_error":
                                throw LLMError.rateLimited(provider: name, retryAfter: nil)
                            case "not_found_error":
                                throw LLMError.modelNotFound(provider: name, model: model)
                            default:
                                throw LLMError.badRequest(provider: name, detail: message)
                            }

                        default:
                            continue
                        }
                    }

                    if !sawFinish {
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

    // MARK: - 消息转换

    /// 把统一的消息模型折叠成 Anthropic 的 user/assistant 交替结构。
    ///
    /// 关键：连续多条 `.tool` 必须合并成**一条** user 消息里的多个 `tool_result` block。
    static func buildMessages(_ messages: [ChatMessage]) -> [JSONValue] {
        var result: [JSONValue] = []
        var pendingToolResults: [JSONValue] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            result.append(.object([
                "role": .string("user"),
                "content": .array(pendingToolResults)
            ]))
            pendingToolResults.removeAll()
        }

        for message in messages {
            switch message.role {
            case .system:
                continue

            case .user:
                flushToolResults()
                result.append(.object([
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("text"),
                        "text": .string(message.content)
                    ])])
                ]))

            case .tool:
                // 不立刻 flush：等下一条非 tool 消息再合并。
                pendingToolResults.append(.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.content),
                    "is_error": .bool(message.isError)
                ]))

            case .assistant:
                flushToolResults()
                var blocks: [JSONValue] = []
                if !message.content.isEmpty {
                    blocks.append(.object([
                        "type": .string("text"),
                        "text": .string(message.content)
                    ]))
                }
                for call in message.toolCalls {
                    blocks.append(.object([
                        "type": .string("tool_use"),
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": .object(call.arguments)
                    ]))
                }
                if blocks.isEmpty {
                    blocks.append(.object(["type": .string("text"), "text": .string("")]))
                }
                result.append(.object([
                    "role": .string("assistant"),
                    "content": .array(blocks)
                ]))
            }
        }

        flushToolResults()
        return result
    }
}