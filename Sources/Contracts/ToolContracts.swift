import Foundation

// ============================================================
// 工具契约 —— 对标 ZCode contracts/src/tool/types.ts（子集）
// ============================================================
//
// 关键点：readOnly / destructive / sideEffectScope / riskLevel / needsApproval
// 不是文档注释，而是权限策略引擎的**输入**。任何“先执行再问”的写法都是回退。

/// 副作用域。对标 `ModelToolSideEffectScope`。
/// iOS 上 `git` / `system` 不存在，保留枚举值以便策略恒为 deny（见锚点 §4.1）。
public enum SideEffectScope: String, Codable, Sendable, CaseIterable {
    case none
    case session
    case workspace
    case git
    case network
    case system
    case userInteraction
}

/// 风险等级。对标 ZCode 的 `RiskLevel`。
public enum RiskLevel: String, Codable, Sendable {
    case low
    case medium
    case high
}

/// 工具能力声明。字段名与 ZCode 的 `ToolMetadata` 保持一一对应（取子集）。
public struct ToolCapability: Sendable, Equatable {
    public var name: String
    /// 给模型看的一句话描述（会进 tool schema）。
    public var summary: String
    public var readOnly: Bool
    public var destructive: Bool
    public var requiresUserInteraction: Bool
    public var sideEffectScope: SideEffectScope
    public var riskLevel: RiskLevel
    public var needsApproval: Bool
    /// 成功即终止回合的终态工具（如 submit_result）。一期恒为 false。
    public var stopTurnOnSuccess: Bool
    /// 给模型看的参数 JSON Schema（OpenAI 的 `function.parameters` / Anthropic 的 `input_schema`）。
    /// 与 ZCode 的 `strict-tool-schema.ts` 同思路：schema 越严格，畸形参数越少。
    public var parameters: JSONValue

    /// 无参数工具的默认 schema。
    public static let emptyObjectSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false)
    ])

    public init(
        name: String,
        summary: String,
        readOnly: Bool,
        destructive: Bool,
        requiresUserInteraction: Bool = false,
        sideEffectScope: SideEffectScope,
        riskLevel: RiskLevel,
        needsApproval: Bool,
        stopTurnOnSuccess: Bool = false,
        parameters: JSONValue = ToolCapability.emptyObjectSchema
    ) {
        self.name = name
        self.summary = summary
        self.readOnly = readOnly
        self.destructive = destructive
        self.requiresUserInteraction = requiresUserInteraction
        self.sideEffectScope = sideEffectScope
        self.riskLevel = riskLevel
        self.needsApproval = needsApproval
        self.stopTurnOnSuccess = stopTurnOnSuccess
        self.parameters = parameters
    }
}

/// 工具执行结果。
///
/// 不变量 I2：工具失败**不抛异常给上层**，而是产出 `isError == true` 的结果，
/// 由循环写回一条配对的 tool 消息，让模型自我修正。
public struct ToolResult: Sendable, Equatable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool) {
        self.content = content
        self.isError = isError
    }

    public static func ok(_ content: String) -> ToolResult {
        ToolResult(content: content, isError: false)
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: true)
    }

    /// 取消必须也是**结果**，否则历史里会留半条（锚点 §2.4 / I1）。
    public static func cancelled(_ message: String = "操作已被用户取消") -> ToolResult {
        ToolResult(content: "[cancelled] \(message)", isError: true)
    }
}

/// 工具参数解析错误。仅在**工具内部**使用，最终都会被转成 `ToolResult.error`。
public enum ToolArgumentError: Error, LocalizedError, Sendable {
    case missing(String)
    case wrongType(key: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .missing(let key):
            return "缺少必需参数 `\(key)`"
        case .wrongType(let key, let expected):
            return "参数 `\(key)` 类型错误，应为 \(expected)"
        }
    }
}

/// 工具参数容器（来自模型的 tool_call.arguments）。
public struct ToolArguments: Sendable {
    public let raw: [String: JSONValue]

    public init(_ raw: [String: JSONValue] = [:]) {
        self.raw = raw
    }

    public func optionalString(_ key: String) -> String? {
        raw[key]?.stringValue
    }

    public func string(_ key: String) throws -> String {
        guard let value = raw[key] else { throw ToolArgumentError.missing(key) }
        guard let text = value.stringValue else {
            throw ToolArgumentError.wrongType(key: key, expected: "string")
        }
        return text
    }

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        raw[key]?.boolValue ?? defaultValue
    }

    public func int(_ key: String, default defaultValue: Int, clamped range: ClosedRange<Int>) -> Int {
        let value = raw[key]?.intValue ?? defaultValue
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 工具协议。实现必须是不可变 struct（`Sendable`），执行体是 `async`。
public protocol AgentTool: Sendable {
    var capability: ToolCapability { get }
    func execute(arguments: ToolArguments) async -> ToolResult
}