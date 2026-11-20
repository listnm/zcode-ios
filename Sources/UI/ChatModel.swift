import Foundation
import Observation

/// 对话页的状态机：把 Agent 事件流折叠成 UI 可直接渲染的状态。
///
/// 并发约定（不变量 I8）：
/// - 本类是 `@MainActor`，所有 UI 状态只在主线程写；
/// - `AgentLoop` 是 `Sendable` 值类型，工具与文件系统各自是 actor，
///   跨隔离域只传值，不传引用；
/// - 任务的唯一句柄是 `runTask`，`stop()` 取消它之后必定把 `isRunning` 复位。
@MainActor
@Observable
public final class ChatModel {

    public private(set) var messages: [ChatMessage] = []
    /// tool_call id → 执行卡片状态。
    public private(set) var runs: [String: ToolRun] = [:]
    public private(set) var isRunning = false
    /// 正在流式接收的文本（还没变成正式消息）。
    public private(set) var streamingText = ""
    public private(set) var outcome: TurnOutcome?
    public private(set) var errorText: String?

    /// 当前会话选择的模型。**只影响本会话**，切换不会改动其他会话或全局默认。
    public var selection: ModelRef?

    /// 当前会话的持久化标识。必须跨启动稳定，否则"重启后恢复会话"永远读到空。
    public private(set) var sessionID: UUID

    private static let sessionKey = "zcode.session.current.v1"

    private var runTask: Task<Void, Never>?
    /// 用户是否按过「停止」。用于区分「我按的」与「流自然断了」。
    private var didUserStop = false
    private let providers: ProviderStore
    private let sessions: SessionStore
    private let tools: [any AgentTool]
    private let maxTurns: Int

    public init(
        providers: ProviderStore,
        sessions: SessionStore,
        tools: [any AgentTool],
        maxTurns: Int = 20
    ) {
        self.providers = providers
        self.sessions = sessions
        self.tools = tools
        self.maxTurns = maxTurns
        self.selection = providers.defaultSelection

        if let stored = UserDefaults.standard.string(forKey: Self.sessionKey),
           let existing = UUID(uuidString: stored) {
            self.sessionID = existing
        } else {
            let fresh = UUID()
            self.sessionID = fresh
            UserDefaults.standard.set(fresh.uuidString, forKey: Self.sessionKey)
        }
    }

    // MARK: - 查询

    public var availableOptions: [ModelOption] {
        providers.modelOptions
    }

    public var currentOption: ModelOption? {
        providers.option(for: resolvedSelection)
    }

    public var resolvedSelection: ModelRef? {
        selection ?? providers.defaultSelection
    }

    public var canSend: Bool {
        !isRunning && resolvedSelection != nil
    }

    /// 单次任务的轮次上限（供设置页展示）。
    public var maxTurnsLimit: Int { maxTurns }

    /// 供列表渲染：把 assistant 的 tool_calls 与卡片状态对齐。
    /// 卡片状态优先取内存里的 runs；重启后 runs 是空的，就从落盘的历史消息反推，
    /// 反推不出来的一律标 .unknown——既不能冒充成功，也不该冒充失败。
    public func runs(for message: ChatMessage) -> [ToolRun] {
        message.toolCalls.map { call in
            if let existing = runs[call.id] {
                return existing
            }
            let answered = toolResultMessage(for: call.id)
            let state: ToolRunState
            if let answered {
                if answered.content.hasPrefix("[cancelled]") {
                    state = .cancelled
                } else if answered.isError {
                    state = .failure
                } else {
                    state = .success
                }
            } else {
                state = .unknown
            }
            return ToolRun(
                id: call.id,
                name: call.name.isEmpty ? "（未命名工具）" : call.name,
                argumentsSummary: call.argumentsSummary,
                argumentsJSON: call.argumentsJSON,
                state: state,
                resultText: answered?.content ?? "（这次对话没有记录到该工具的结果）"
            )
        }
    }

    private func toolResultMessage(for callID: String) -> ChatMessage? {
        messages.first { $0.role == .tool && $0.toolCallID == callID }
    }

    // MARK: - 会话恢复

    public func restoreSession() async {
        let restored = await sessions.load(sessionID: sessionID)
        guard !restored.isEmpty else { return }
        messages = restored
    }

    public func resetSession() async {
        stop()
        messages = []
        runs = [:]
        outcome = nil
        errorText = nil
        streamingText = ""
        await sessions.clear(sessionID: sessionID)

        // 清空会话 = 开一个新会话，而不是复用同一个 id（否则重启后又把旧的读回来）。
        let fresh = UUID()
        sessionID = fresh
        UserDefaults.standard.set(fresh.uuidString, forKey: Self.sessionKey)
    }

    // MARK: - 发送

    public func send(_ text: String, workspaceName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        // 每个回合开头清空卡片表：id 兜底值（模型漏给 id 时的 call_0）会跨回合重复，
        // 不清就会让上一轮的结果被这一轮的卡片读到。
        runs.removeAll()
        didUserStop = false

        guard let ref = resolvedSelection,
              let provider = providers.provider(for: ref) else {
            errorText = "还没有可用的模型。请先到设置里添加 Provider 和 Model ID。"
            return
        }
        guard let apiKey = providers.apiKey(for: provider.id), !apiKey.isEmpty else {
            errorText = "「\(provider.displayName)」缺少 API Key，请到设置里填写。"
            return
        }

        errorText = nil
        outcome = nil
        streamingText = ""
        isRunning = true

        let userMessage = ChatMessage.user(trimmed)
        messages.append(userMessage)

        let history = messages
        let toolNames = tools.map { $0.capability.name }.joined(separator: "、")
        let loop = AgentLoop(
            tools: tools,
            systemPrompt: AgentPrompts.systemPrompt(
                workspaceName: workspaceName ?? "未命名工作区",
                toolNames: toolNames
            ),
            maxTurns: maxTurns
        )

        let client = providers.makeClient(for: provider)

        runTask = Task { [weak self] in
            guard let self else { return }

            let stream = loop.run(
                client: client,
                provider: provider,
                apiKey: apiKey,
                model: ref.modelID,
                history: history
            )

            do {
                for try await event in stream {
                    self.apply(event)
                }
            } catch is CancellationError {
                self.finish(outcome: .cancelled)
            } catch let error as LLMError {
                self.finish(outcome: .failed(error.errorDescription ?? "请求失败"))
            } catch {
                self.finish(outcome: .failed(error.localizedDescription))
            }

            // 兜底：消费端被取消时 AsyncStream 会直接结束、不产生 finished 事件，
            // 这里必须补一个终态，否则 UI 会一直转圈（自检清单第 4 条）。
            if self.outcome == nil {
                self.finish(outcome: .cancelled)
            }
            await self.persist()
        }
    }

    private func apply(_ event: AgentEvent) {
        switch event {
        case .textDelta(let delta):
            streamingText += delta

        case .toolStarted(let run):
            runs[run.id] = run

        case .toolFinished(let run):
            runs[run.id] = run

        case .assistantCommitted(let message):
            messages.append(message)
            streamingText = ""

        case .toolCommitted(let message):
            messages.append(message)

        case .finished(let result):
            finish(outcome: result)
        }
    }

    private func finish(outcome result: TurnOutcome) {
        // 用户按过停止：终态固定为 cancelled，不被随后到达的事件覆盖
        // （工具补结果时还会再发一个 finished，那是"收尾"而不是"结果"）。
        let resolved: TurnOutcome = didUserStop ? .cancelled : result
        outcome = resolved
        isRunning = false
        streamingText = ""
        runTask = nil
        if case .failed(let message) = resolved {
            errorText = message
        }
    }

    private func persist() async {
        await sessions.save(messages: messages, sessionID: sessionID)
    }

    // MARK: - 取消

    /// 用户点「停止」。取消会穿透到网络请求与工具执行；未完成的工具在这里补成取消结果，
    /// 保证 tool_call ↔ tool_result 仍然配对——否则历史带着半截批次进下一次请求会直接 400。
    public func stop() {
        guard isRunning else { return }
        didUserStop = true
        runTask?.cancel()
        runTask = nil
        // 立刻复位 UI，不等事件流收尾。
        isRunning = false
        streamingText = ""
        healUnpairedToolCalls()
        outcome = .cancelled
        Task { await persist() }
    }

    /// 给历史里"最后一个 assistant 消息中还没拿到结果"的调用补一条取消结果。
    /// 已执行完的调用会被 toolCommitted 记过账，这里只补缺的那些。
    private func healUnpairedToolCalls() {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        let calls = messages[index].toolCalls
        guard !calls.isEmpty else { return }
        let answered = Set(messages[(index + 1)...].compactMap { $0.toolCallID })

        for call in calls where !answered.contains(call.id) {
            let result = ToolResult.cancelled("任务已停止，该工具未执行")
            var existing = runs[call.id] ?? ToolRun(
                id: call.id,
                name: call.name.isEmpty ? "（未命名工具）" : call.name,
                argumentsSummary: call.argumentsSummary,
                argumentsJSON: call.argumentsJSON
            )
            existing.state = .cancelled
            existing.resultText = result.content
            existing.endedAt = Date()
            runs[call.id] = existing
            messages.append(ChatMessage.toolResult(call: call, result: result))
        }
    }

    public func clearError() {
        errorText = nil
    }
}