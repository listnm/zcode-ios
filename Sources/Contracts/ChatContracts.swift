import Foundation

// ============================================================
// 对话契约（对标 ZCode contracts 中的 message / tool-call 形状）
// ============================================================

/// 消息角色。`tool` 只用于回传工具结果。
public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// 一次工具调用（模型请求的）。
///
/// 注意 `argumentsJSON` 存的是**原始文本**而不是解析后的结构：
/// ZCode 的 `tool-input-normalization.ts` 明确要求"解析失败只降级为空对象"，
/// 保留原文才能在不中断回合的前提下让工具层自己决定怎么处理畸形参数（不变量 I11）。
public struct ToolCall: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// 解析参数。**任何**失败都降级为空字典，绝不抛错（I11）。
    public var arguments: [String: JSONValue] {
        ToolCallParser.parse(argumentsJSON)
    }

    /// 卡片标题上显示的一行参数摘要。
    public var argumentsSummary: String {
        let dict = arguments
        if dict.isEmpty {
            return argumentsJSON.isEmpty ? "（无参数）" : "（参数无法解析，已按空参数处理）"
        }
        let pairs = dict.keys.sorted().map { key -> String in
            let rendered = dict[key]?.compactDescription ?? "null"
            return "\(key)=\(rendered)"
        }
        let joined = pairs.joined(separator: ", ")
        return joined.count > 120 ? String(joined.prefix(120)) + "…" : joined
    }
}

/// 参数解析的唯一入口。独立出来便于单测，也便于在日志里统一口径。
public enum ToolCallParser {
    public static func parse(_ json: String) -> [String: JSONValue] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空串 / 空白 → 空参数（对应 normalizeModelToolInput 的 undefined/空串分支）。
        guard !trimmed.isEmpty else { return [:] }

        // 去掉可能存在的 BOM。
        let cleaned = trimmed.hasPrefix("\u{FEFF}") ? String(trimmed.dropFirst()) : trimmed

        guard let data = cleaned.data(using: .utf8) else { return [:] }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return [:]
        }
        // null / 数组 / 标量都降级为空参数，只有对象才是合法参数体。
        return value.objectValue ?? [:]
    }
}

/// 一条对话消息。工具结果也是消息，且必须带 `toolCallID` 才能与请求配对（不变量 I1）。
public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let role: ChatRole
    public var content: String
    /// 仅 assistant 使用：本轮请求的工具调用。
    public var toolCalls: [ToolCall]
    /// 仅 tool 使用：对应的 tool_call id。
    public var toolCallID: String?
    /// 仅 tool 使用：工具名（Anthropic 要求 tool_result 不带名字，但本地 UI 需要）。
    public var toolName: String?
    /// 仅 tool 使用：失败标记。
    public var isError: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        isError: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.isError = isError
        self.createdAt = createdAt
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: text)
    }

    public static func toolResult(call: ToolCall, result: ToolResult) -> ChatMessage {
        ChatMessage(
            role: .tool,
            content: result.content,
            toolCallID: call.id,
            toolName: call.name,
            isError: result.isError
        )
    }
}

/// 某个 Provider 下的某个模型。
public struct ModelRef: Codable, Hashable, Sendable {
    public let providerID: UUID
    public let modelID: String

    public init(providerID: UUID, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

/// token 用量（部分 provider 不返回，全部 optional）。
public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}