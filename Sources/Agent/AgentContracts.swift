import Foundation

// ============================================================
// Agent 循环的事件与状态（对标 ZCode core/src/agent/turn-state.ts 的子集）
// ============================================================

/// 单次工具运行的状态（驱动 UI 的执行卡片）。
public enum ToolRunState: String, Sendable, Equatable {
    case running
    case success
    case failure
    case cancelled
    /// 从历史恢复时无法判定真实结果的卡片：既不能冒充成功，也不该冒充失败。
    case unknown
}

/// 一张执行卡片的数据。UI 只读这个结构。
public struct ToolRun: Identifiable, Sendable, Equatable {
    public let id: String          // == tool_call id
    public let name: String
    public let argumentsSummary: String
    /// 完整参数原文，卡片展开时显示。
    public let argumentsJSON: String
    public var state: ToolRunState
    public var resultText: String
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: String,
        name: String,
        argumentsSummary: String,
        argumentsJSON: String,
        state: ToolRunState = .running,
        resultText: String = "",
        startedAt: Date = Date(),
        endedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.argumentsSummary = argumentsSummary
        self.argumentsJSON = argumentsJSON
        self.state = state
        self.resultText = resultText
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

/// 回合终态。与 ZCode 的 `TurnResultType` 对齐：
/// 取消是**独立终态**，不能渲染成"失败"，也不能转圈到底（不变量 I9）。
public enum TurnOutcome: Sendable, Equatable {
    case success
    case maxTurns(Int)
    case cancelled
    case failed(String)

    public var isTerminalFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    public var displayText: String {
        switch self {
        case .success: return "已完成"
        case .maxTurns(let limit): return "已达到最大轮次（\(limit)），已停止。可以继续追问让它接着做。"
        case .cancelled: return "已停止"
        case .failed(let message): return "出错：\(message)"
        }
    }
}

/// 循环对外输出的事件流。
public enum AgentEvent: Sendable {
    /// 流式文本增量。
    case textDelta(String)
    /// 工具开始执行（UI 插入卡片）。
    case toolStarted(ToolRun)
    /// 工具结束（UI 更新卡片状态）。
    case toolFinished(ToolRun)
    /// 一条完整的 assistant 消息已写入历史。
    case assistantCommitted(ChatMessage)
    /// 一条工具结果已写入历史（与 tool_call 配对）。
    case toolCommitted(ChatMessage)
    /// 本轮模型用量（token 计数）。不是终态，只是统计。
    case usage(TokenUsage)
    /// 回合结束。
    case finished(TurnOutcome)
}

// MARK: - 工具调用累加器

/// 把流式分片聚合成完整工具调用。
///
/// 直接对标 ZCode `streaming-tool-call-assembler.ts` 的两条硬规则：
/// 1. 只有收到"闭合"信号（`finish_reason` / `message_delta`）才允许提交调用；
///    半截调用绝不能进执行器（否则 history 里会出现对不上的 tool_call）。
/// 2. id/name 只在首片出现，缺失时**不抛错**，由工具层产出配对错误结果（I10）。
struct ToolCallAccumulator {

    private struct Slot {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    private var slots: [Int: Slot] = [:]

    mutating func consume(_ event: StreamEvent) {
        guard case let .toolCallDelta(index, id, name, fragment) = event else { return }
        var slot = slots[index] ?? Slot()
        if let id, slot.id == nil { slot.id = id }
        if let name, slot.name == nil { slot.name = name }
        slot.arguments += fragment
        slots[index] = slot
    }

    var isEmpty: Bool { slots.isEmpty }

    /// 闭合时产出调用列表。按 index 升序，保证执行顺序与模型意图一致。
    func finalizedCalls() -> [ToolCall] {
        slots.keys.sorted().map { index in
            let slot = slots[index]!
            return ToolCall(
                // id 缺失时补一个稳定 id：配对关系仍然成立，只是模型看不到自己给的 id。
                id: slot.id ?? "call_\(index)",
                // name 缺失时留空串，交给执行器产出"未知工具"错误结果（I10）。
                name: slot.name ?? "",
                argumentsJSON: slot.arguments.isEmpty ? "{}" : slot.arguments
            )
        }
    }
}