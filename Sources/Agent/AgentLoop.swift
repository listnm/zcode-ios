import Foundation

/// Agent 主循环（对标 ZCode `core/src/runtime/methods/turn-loop.ts` 的 `runRegularTurnLoop`）。
///
/// 语义要点（全部来自真实源码，见锚点 §2）：
/// 1. **回合制**：发送当前历史 → 模型返回 tool_calls 或最终文本 → 有调用就逐个执行并回传 →
///    直到模型不再请求工具，或达到 `maxTurns`。
/// 2. **配对性**：N 个 tool_call 必须产生 N 条 tool 结果，**包括被取消的那些**。
///    少一条，下一次请求 OpenAI/Anthropic 都会直接 400（不变量 I1）。
/// 3. **失败即结果**：工具失败不终止回合，错误文本继续喂给模型自我修正（I2）。
/// 4. **取消是独立终态**：`cancelled` 不能渲染成错误，也不能让 UI 转圈到底（I9）。
/// 5. **串行执行**：一期有意偏离（PROJECT.md D-01），换取取消检查点与卡片状态机的简单性。
public struct AgentLoop: Sendable {

    public let tools: [any AgentTool]
    public let systemPrompt: String
    public let maxTurns: Int

    public init(tools: [any AgentTool], systemPrompt: String, maxTurns: Int = 20) {
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxTurns = max(1, maxTurns)
    }

    /// 启动一次任务。返回的事件流在终止态之后必定 `finish()`，不会悬挂。
    public func run(
        client: any ModelClient,
        provider: ModelProvider,
        apiKey: String,
        model: String,
        history: [ChatMessage]
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let tools = self.tools
        let capabilities = tools.map { $0.capability }
        let systemPrompt = self.systemPrompt
        let maxTurns = self.maxTurns

        return AsyncThrowingStream { continuation in
            let task = Task {
                var messages = history
                var turns = 0

                do {
                    while true {
                        if Task.isCancelled {
                            continuation.yield(.finished(.cancelled))
                            continuation.finish()
                            return
                        }
                        if turns >= maxTurns {
                            continuation.yield(.finished(.maxTurns(maxTurns)))
                            continuation.finish()
                            return
                        }
                        turns += 1

                        // ---- 1. 请求模型 ----
                        var text = ""
                        var accumulator = ToolCallAccumulator()

                        let stream = client.stream(
                            provider: provider,
                            apiKey: apiKey,
                            model: model,
                            messages: messages,
                            tools: capabilities,
                            systemPrompt: systemPrompt
                        )

                        for try await event in stream {
                            if Task.isCancelled {
                                continuation.yield(.finished(.cancelled))
                                continuation.finish()
                                return
                            }
                            switch event {
                            case .textDelta(let delta):
                                text += delta
                                continuation.yield(.textDelta(delta))
                            case .toolCallDelta:
                                accumulator.consume(event)
                            case .finished(_, let usage):
                                // 用量单独上报：UI 要显示"这一轮烧了多少 token"，
                                // 但不能把它混进终态，否则终态会被覆盖成非终态。
                                continuation.yield(.usage(usage))
                                // 只在闭合信号之后才允许提交调用（见累加器注释）。
                                break
                            }
                        }

                        let calls = accumulator.finalizedCalls()

                        // ---- 2. 记录 assistant 消息（即便没有文本，也可能只有 tool_calls）----
                        let assistant = ChatMessage(role: .assistant, content: text, toolCalls: calls)
                        messages.append(assistant)
                        continuation.yield(.assistantCommitted(assistant))

                        // ---- 3. 没有工具调用 → 回合正常结束 ----
                        if calls.isEmpty {
                            continuation.yield(.finished(.success))
                            continuation.finish()
                            return
                        }

                        // ---- 4. 串行执行工具，保证 N 个调用 → N 条结果 ----
                        var cancelledDuringBatch = false

                        for (offset, call) in calls.enumerated() {
                            if Task.isCancelled {
                                cancelledDuringBatch = true
                                // 把**尚未执行**的调用补齐为取消结果，保持配对完整。
                                for remaining in calls[offset...] {
                                    Self.commitCancelled(remaining, into: &messages, continuation: continuation)
                                }
                                break
                            }

                            var run = ToolRun(
                                id: call.id,
                                name: call.name.isEmpty ? "（未命名工具）" : call.name,
                                argumentsSummary: call.argumentsSummary,
                                argumentsJSON: call.argumentsJSON
                            )
                            continuation.yield(.toolStarted(run))

                            let result = await Self.execute(call, tools: tools)

                            run.state = Self.state(for: result)
                            run.resultText = result.content
                            run.endedAt = Date()
                            continuation.yield(.toolFinished(run))

                            let message = ChatMessage.toolResult(call: call, result: result)
                            messages.append(message)
                            continuation.yield(.toolCommitted(message))

                            if case .cancelled = run.state {
                                cancelledDuringBatch = true
                                // 当前这条已结算，剩下的同样补齐。
                                for remaining in calls[(offset + 1)...] {
                                    Self.commitCancelled(remaining, into: &messages, continuation: continuation)
                                }
                                break
                            }
                        }

                        if cancelledDuringBatch {
                            continuation.yield(.finished(.cancelled))
                            continuation.finish()
                            return
                        }

                        // 工具全部失败也继续下一轮：让模型看到错误并自我修正（I2）。
                    }
                } catch is CancellationError {
                    continuation.yield(.finished(.cancelled))
                    continuation.finish()
                } catch let error as LLMError {
                    continuation.yield(.finished(.failed(error.errorDescription ?? "请求失败")))
                    continuation.finish()
                } catch {
                    continuation.yield(.finished(.failed(error.localizedDescription)))
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 工具执行

    /// 未知/空工具名：**不抛错**，产出配对错误结果（I10）。
    static func execute(_ call: ToolCall, tools: [any AgentTool]) async -> ToolResult {
        guard !call.name.isEmpty else {
            return .error("模型没有给出工具名。请重新选择一个可用工具并给出完整参数。可用工具：\(toolNames(tools))")
        }
        guard let tool = tools.first(where: { $0.capability.name == call.name }) else {
            return .error("未知工具 `\(call.name)`。可用工具：\(toolNames(tools))")
        }
        return await tool.execute(arguments: ToolArguments(call.arguments))
    }

    static func toolNames(_ tools: [any AgentTool]) -> String {
        tools.map { $0.capability.name }.joined(separator: "、")
    }

    static func state(for result: ToolResult) -> ToolRunState {
        if result.content.hasPrefix("[cancelled]") { return .cancelled }
        return result.isError ? .failure : .success
    }

    /// 为"还没轮到执行"的调用补一条取消结果。
    private static func commitCancelled(
        _ call: ToolCall,
        into messages: inout [ChatMessage],
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        let result = ToolResult.cancelled("任务已停止，该工具未执行")
        var run = ToolRun(
            id: call.id,
            name: call.name.isEmpty ? "（未命名工具）" : call.name,
            argumentsSummary: call.argumentsSummary,
            argumentsJSON: call.argumentsJSON,
            state: .cancelled,
            resultText: result.content,
            endedAt: Date()
        )
        run.state = .cancelled
        continuation.yield(.toolStarted(run))
        continuation.yield(.toolFinished(run))

        let message = ChatMessage.toolResult(call: call, result: result)
        messages.append(message)
        continuation.yield(.toolCommitted(message))
    }
}

// MARK: - 系统提示词

/// 系统提示词。写成常量而不是让用户填，是为了让"只在工作区内操作"这条规则
/// 出现在每一次请求里——模型忘记规则的代价是越界尝试，而不是简单报错。
public enum AgentPrompts {

    public static func systemPrompt(workspaceName: String, toolNames: String) -> String {
        """
        你是 ZCode，一个在用户 iOS 设备上工作的编程 Agent。

        你只能在用户授权的工作区「\(workspaceName)」内读写文件。

        可用工具：\(toolNames)

        规则：
        1. 所有路径都是**相对工作区根**的路径，例如 "src/main.swift"。不要写绝对路径，也不要写 ".."。
        2. 动手前先用 list_files / read_file 了解现状，不要凭空猜测文件内容。
        3. 工具失败时，你会收到一条 is_error 的结果。读它、修正参数、再试一次；不要重复同样的失败调用。
        4. 删除操作会要求用户二次确认。用户拒绝时不要重试同一路径，改为询问意图。
        5. 任务完成时用自然语言简短总结你做了什么、涉及哪些文件。不要编造没有执行过的操作。
        """
    }
}