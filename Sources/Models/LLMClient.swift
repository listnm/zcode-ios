import Foundation

// ============================================================
// 模型请求层：错误语义 + 流式事件 + 客户端协议
// ============================================================
//
// 对应 ZCode adapters/src/model/ 里的一整套失败分类（failure-classifier.ts、
// failure-provider-business-codes.ts 等）。iOS 一期不重试、不做 off-peak 调度，
// 但**必须**把"哪一类失败"分清楚，否则用户只会看到一个转不完的圈。

/// 可读的模型请求错误。每一种都有中文说明 + 可执行的下一步。
public enum LLMError: Error, LocalizedError, Sendable, Equatable {
    /// 未配置 Key。
    case missingAPIKey(provider: String)
    /// 401 / 403：Key 无效或权限不足。
    case invalidAPIKey(provider: String, detail: String?)
    /// 连不上（DNS、TLS、超时、无网络）。
    case unreachable(provider: String, detail: String)
    /// 404：模型不存在，或 Base URL 路径不对。
    case modelNotFound(provider: String, model: String)
    /// 429：限流。
    case rateLimited(provider: String, retryAfter: String?)
    /// 400 / 422：请求被拒（通常是参数或模型不兼容）。
    case badRequest(provider: String, detail: String)
    /// 5xx。
    case serverError(provider: String, status: Int, detail: String)
    /// 返回体不是预期的流格式。
    case malformedStream(provider: String, detail: String)
    /// 用户取消。
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "「\(provider)」还没有配置 API Key。请到设置里填入后再试。"
        case .invalidAPIKey(let provider, let detail):
            let suffix = detail.map { "（服务端说：\($0)）" } ?? ""
            return "「\(provider)」的 API Key 无效或已过期\(suffix)。请到设置里更新 Key。"
        case .unreachable(let provider, let detail):
            return "连接「\(provider)」失败：\(detail)。请检查网络，以及 Base URL 是否可达。"
        case .modelNotFound(let provider, let model):
            return "「\(provider)」上找不到模型「\(model)」。请确认 Model ID 拼写，或检查 Base URL 是否指向正确的服务。"
        case .rateLimited(let provider, let retryAfter):
            let suffix = retryAfter.map { "，建议 \($0) 秒后重试" } ?? "，请稍后再试"
            return "「\(provider)」触发了限流\(suffix)。"
        case .badRequest(let provider, let detail):
            return "「\(provider)」拒绝了这次请求：\(detail)"
        case .serverError(let provider, let status, let detail):
            return "「\(provider)」服务端错误（HTTP \(status)）：\(detail)"
        case .malformedStream(let provider, let detail):
            return "「\(provider)」返回的数据无法解析：\(detail)"
        case .cancelled:
            return "已停止。"
        }
    }

    /// 是否为"重试可能有用"的错误（UI 可据此显示重试按钮）。
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .unreachable: return true
        default: return false
        }
    }
}

/// 结束原因。
public enum FinishReason: String, Sendable, Equatable {
    case stop
    case toolCalls = "tool_calls"
    case length
    case contentFilter = "content_filter"
    case unknown

    public init(raw: String?) {
        switch raw {
        case "stop": self = .stop
        case "tool_calls", "tool_use": self = .toolCalls
        case "length", "max_tokens": self = .length
        case "content_filter": self = .contentFilter
        default: self = .unknown
        }
    }
}

/// 流式事件。客户端只产出这三种，循环据此累加。
public enum StreamEvent: Sendable, Equatable {
    case textDelta(String)
    /// 工具调用分片。`index` 用于聚合同一调用的多个分片（不变量：分片必须按 index 归并）。
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String)
    case finished(reason: FinishReason, usage: TokenUsage?)
}

/// 模型客户端协议。
///
/// 实现必须：
/// - 尊重 `Task` 取消（`AsyncThrowingStream` 的 onTermination 里 cancel 内部 Task）；
/// - 只在收到完整的"调用闭合"信号后才产出非 nil 的 `id`/`name`，避免半截调用被提交；
/// - 网络/协议错误一律映射成 `LLMError`，不要抛出裸 `URLError`。
public protocol ModelClient: Sendable {
    func stream(
        provider: ModelProvider,
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        tools: [ToolCapability],
        systemPrompt: String?
    ) -> AsyncThrowingStream<StreamEvent, Error>
}

// MARK: - 共享工具

enum ModelHTTP {
    /// iOS 13+。超时给足，但流式阶段的空闲超时由 URLSession 自身控制。
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        return URLSession(configuration: configuration)
    }

    static func mapStatus(
        _ status: Int,
        provider: String,
        model: String,
        body: String
    ) -> LLMError? {
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = detail.count > 300 ? String(detail.prefix(300)) + "…" : detail
        switch status {
        case 200...299:
            return nil
        case 401, 403:
            return .invalidAPIKey(provider: provider, detail: clipped.isEmpty ? nil : clipped)
        case 404:
            return .modelNotFound(provider: provider, model: model)
        case 429:
            return .rateLimited(provider: provider, retryAfter: nil)
        case 400, 422:
            return .badRequest(provider: provider, detail: clipped)
        case 500...599:
            return .serverError(provider: provider, status: status, detail: clipped)
        default:
            return .badRequest(provider: provider, detail: "HTTP \(status) \(clipped)")
        }
    }

    /// 把 `[String: JSONValue]` 编码成请求体。
    static func encodeBody(_ object: [String: JSONValue]) -> Data? {
        try? JSONEncoder().encode(JSONValue.object(object))
    }

    /// 读取非流式错误响应体（流式 200 不走这条路）。
    static func readErrorBody(_ bytes: URLSession.AsyncBytes) async -> String {
        var chunks: [UInt8] = []
        do {
            for try await byte in bytes {
                chunks.append(byte)
                if chunks.count >= 4096 { break }
            }
        } catch {
            return ""
        }
        return String(decoding: chunks, as: UTF8.self)
    }
}