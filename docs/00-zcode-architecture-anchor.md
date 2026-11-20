# 阶段 0：ZCode 架构锚点（iOS 移植的语义基准）

> 本文是后续所有 iOS 实现的**验收基准**。实现与本文冲突时，要么改实现，要么在此登记"为什么改"。
> **v2 说明**：v1 基于用户口述的锚点写成；v2 已用真实源码（`github.com/zai-org/ZCode@main`）逐条校验，修正了 4 处与源码不符的表述，见 §9 勘误记录。**冲突时以源码为准**。

---

## 0. 一句话定性

ZCode 的本质不是"聊天框 + 几个工具"，而是：

> **一个有权限边界、可中止、以工具结果为燃料的回合制状态机。**

移植时最容易被丢掉、也最不该丢的四件事：

1. **工具结果是一条 `tool` 角色的结构化消息**（带 `tool_call_id`），不是异常、不是 UI 事件。
2. **权限决策发生在工具执行入口**，不在 prompt 里、不在按钮上。
3. **中止是一个显式终态**，但**中止也必须保持 call↔result 配对**——不能"UI 停了，历史里留半条"。
4. **工具失败不终止回合**：错误结果继续喂给模型，让模型自我修正。

---

## 1. 分层与依赖方向（已校正）

真实的包位置是 `apps/zcode-cli/packages/*`（不是 repo 根 `packages/`；根下的 `ui/server/provider/android/desktop/web` 与本移植无关）。

| 层 | ZCode 包 | 职责 | iOS 对应物 |
|---|---|---|---|
| 宿主 | `apps/zcode-cli` | 入口、参数、终端渲染、进程生命周期 | App target + `AppEnvironment` 生命周期 |
| 装配 | `zcode-cli/packages/bootstrap` | 读配置、选 provider、注册工具、注入权限策略 | `AppComposition`（组合根，唯一知道具体实现的地方） |
| 核心 | `zcode-cli/packages/core` | **Agent 循环**、回合状态机、工具调度、上下文管理 | `actor AgentLoop` |
| 适配 | `zcode-cli/packages/adapters` | 模型执行 + 全部工具实现 | `ModelProvider` 实现 + `ToolRegistry` |
| 契约 | `zcode-cli/packages/contracts` | 消息、工具 schema、权限、副作用声明（纯类型） | `Contracts.swift`（纯类型，零 IO） |

**依赖方向**：`cli → bootstrap → core → contracts`；`adapters` 实现 `contracts` 的接口，由 `bootstrap` 注入 `core`。

**这条方向感是移植的第一原则**：`AgentLoop` 不知道 OpenAI 的 JSON 形状，不知道 HTTP，也不知道"文件"是什么；它只知道"有一个 provider 能产出 tool_calls，有一个注册表能执行工具"。任何让 `AgentLoop` 直接 `import` 网络细节或 `FileManager` 的写法，都是架构回退。

---

## 2. Agent 循环的语义（已校正到真实主循环）

### 2.1 主循环归属

- **主循环**：`core/src/runtime/methods/turn-loop.ts` 的 `runRegularTurnLoop()`。
  `while (true)`：每轮做 MCP 刷新 → `getTurnTools()` → 输入附件收集 → microcompact / autoCompact → `prepareRuntimeProviderRequest()` → `runModelBackedTurnStep()`；返回 `"break"` 跳出，`"continue"` 进下一轮。
- **不是主循环**：`core/src/memory/memory-agent-loop.ts`（289 行）。它是 **Memory 子 Agent**（Extraction / Dream）的受控循环，只允许 Read/Grep/Glob、只读 Bash、`rootDir` 内 `.md` 的 Edit/Write；源码注释明确说它与 Main"共用单步内核"。
- `runModelBackedTurnStep()`（`turn-model-step.ts`，981 行）负责单步：流式收流 → 组装 tool_calls → 调用 `turn-tools.ts` 执行 → 返回 `"continue" | "break"`。

### 2.2 回合状态机（`core/src/agent/turn-machine.ts` / `turn-state.ts`）

```
Idle → ProcessingInput → AwaitingModelResponse → Streaming
     → SchedulingTools → (AwaitingPermission) → ExecutingTools → AggregatingResults
     → 回 AwaitingModelResponse  或  → Completing
Error 是终态；非法迁移抛 CoreErrorType.InvalidTurnPhase（白名单 canTransitionTo 校验）
```

终态 `TurnResultType`（`turn-state.ts:151-158`）：

| 值 | 含义 |
|---|---|
| `success` | 模型返回最终文本 |
| `cancelled` | 用户主动中断。源码注释：「cancelled 属于正常结束，复用 TurnComplete 上报而非 TurnError」 |
| `error_max_turns` | 达到最大回合 |
| `error_max_tool_calls` | 达到单回合最大工具调用数 |
| `error_max_budget` | 预算（token / 时长）耗尽 |
| `error_during_execution` | 执行期错误 |

> **移植要点**：`cancelled` **不是** error 分支。iOS 侧同样应把它做成 `.cancelled` 这一独立终态，UI 显示"已停止"而非红色报错。

### 2.3 单回合流程

```
loop:
  1. 组装请求 = system + 全量历史（含历史 assistant.tool_calls 与其配对的 tool 结果）
  2. 调模型（流式：text delta 先推 UI，tool_calls 累积到完整再解析）
  3. 分流：
     a. 有 tool_calls → 按 §3 调度执行 → 每个结果追加 role=tool 消息 → 回 1
     b. 无 tool_calls，返回最终文本 → 终止
     c. 触达 maxTurns / 用户取消 / 不可恢复错误 → 对应终态
```

### 2.4 关键不变量

- **配对性（硬约束）**：assistant 消息若有 N 个 `tool_call`，下一回合必须有 N 条 `tool` 结果，`tool_call_id` 一一对应。缺一条，OpenAI/Anthropic 直接 400。
- **取消也保持配对**（源码确认，`turn-tools.ts:132-134`）：assistant 的 `tool_use` 一旦进入 history，Stop **不允许**在 tool result 创建前直接抛出。正确做法是把 `aborted` signal 交给 executor，由既有取消路径为**每个** tool call 生成一条 `ToolCancelled` 结果，再由循环层感知 abort。→ iOS：`Task.cancel()` 后仍需为每个未完成 call 写一条 `is_error`/`cancelled` 结果。
- **错误即结果**：工具抛错 → 捕获 → 转成 `{is_error: true, content: "..."}`。**工具失败不 break 循环**（`turn-tools.ts:315-325` 在完整批次后一律 `return "continue"`），错误继续喂模型自我修正。
- **唯一 break 例外**：工具声明了 `stopTurnOnSuccess`（如 `submit_result`）且成功 → `turnControl.stopTurnAfterResult === true` → `"break"`。iOS 一期的四个文件工具都不属于此类。
- **中止结算顺序**：工具执行中 abort 时，**先结算**（写 `ToolCancelled` 结果 + 置 `interruptedDuringToolBatch`），**再** `throwIfTurnAborted`。
- **上下文预算**：单条工具结果按 `maxBytes` 截断；超预算时先丢最老的工具输出，永不丢 system、不丢最近一轮用户意图（ZCode 对应 `core/src/compact/` 的 microcompact / autoCompact 两级）。

### 2.5 工具调用解析的容错语义（源码确认，最易被移植丢掉）

`adapters/src/model/tool-call-validation.ts` 与 `tool-input-normalization.ts` 体现两条硬规则，**它们的方向都是"降级到工具层，绝不升级为整个请求失败"**：

1. **工具名为空**（`tool-call-validation.ts:4-29`）：client-executed 且 id 非空时**不抛错**，保留空名让该 call 用原 id 闭合。
   源码注释：「在 Adapter 直接抛错的话，模型收不到同 id 的 tool error，整个 turn 因而停止。」
   → iOS：工具名无法匹配注册表时，**产出配对错误结果**（`is_error: true, content: "unknown tool: X"`），回合继续。
2. **参数 JSON 畸形**（`tool-input-normalization.ts`）：`undefined` / 空串 / `"null"` / 解析失败 → 一律降级为 `{}`（并去 BOM）。
   源码注释：「会把参数错误错误地升级为整个模型请求失败……严格解析失败后只降级为空对象，由普通工具 schema 决定返回 error result 还是继续执行。」
   → iOS：`JSONDecoder` 失败 → `{}` + 一条 warning，交给工具参数校验产出错误结果。

> 这两条合起来是配对性不变量（I1）在**输入侧**的保障：坏输入也要能"闭合"，而不是让历史留半条。

---

## 3. 工具系统、调度与最小集裁剪

### 3.1 ZCode 的调度语义（已校正：不是纯串行）

`core/src/tool/scheduler.ts`：`ToolScheduler`，`DEFAULT_MAX_CONCURRENCY = 10`，按依赖拓扑排序后**分层分组**，环依赖抛 `InvalidStateTransition`。

并行判定 `canRunInParallel()`：

```
destructive === true            → 禁止并行
concurrentSafe === true / false → 显式优先
readOnly === true               → 可并行
否则                             → 仅 sideEffectScope === "none" 可并行
```

`READ_ONLY_TOOLS = Read, Glob, Grep, WebSearch, WebFetch, TodoRead, TodoWrite, AskUserQuestion, Skill`

> **移植决策（有意偏离）**：iOS 一期**串行执行**本批工具。理由：四个文件工具里 `write/delete` 触碰 `workspace` 域，本身就不满足并行条件；串行让"取消检查点"和"执行卡片状态机"的实现简单一个量级。**登记为偏离 D-01**，二期若加只读工具（如 `grep`）再按上述规则分组。偏离只影响吞吐，不影响语义。

### 3.2 工具命名对照

ZCode 用 Claude-Code 风格命名，与本任务要求的名字不同。**iOS 保留任务书要求的名字**（对模型更直观），但 capability 元数据必须与 ZCode 等价：

| ZCode | iOS（本项目） | readOnly | destructive | sideEffectScope | riskLevel |
|---|---|---|---|---|---|
| `Glob` | `list_files` | ✅ | ❌ | `none` | low |
| `Read` | `read_file` | ✅ | ❌ | `none` | low |
| `Write` / `Edit` | `write_file` | ❌ | 覆盖已存在文件时 ✅ | `workspace` | medium |
| `Bash rm` / 删除类 | `delete_file` | ❌ | ✅ | `workspace` | high |

**裁掉与理由**：

- `Bash`/`exec`：iOS 无子进程（`Process` 不可用），语义无法等价。
- `browser`：WKWebView 属 UI 层，做成"工具"会引入无法取消的副作用。
- `MCP`：依赖 stdio 长连接；iOS 只能走远程 HTTP，二期。
- `ReadImage` / `ReadPdf` / `ReadVideo`：一期不做多模态。

### 3.3 工具元数据契约（`core/src/tool/types.ts:75-111` 的移植子集）

```swift
name, description, parametersJSONSchema,
readOnly: Bool, destructive: Bool, concurrentSafe: Bool,
sideEffectScope: SideEffectScope,   // none | session | workspace | git | network | system | userInteraction
riskLevel: RiskLevel,               // low | medium | high
needsApproval: Bool,
stopTurnOnSuccess: Bool             // 一期恒 false
```

`readOnly` / `destructive` 不是文档注释，是**策略引擎的输入**。

---

## 4. 权限与副作用分层（已校正到真实机制）

> **v1 错误**：`orchestrationReadOnly` / `effectiveReadOnly` 在 ZCode 当前源码中**不存在**（对 `core/src` 全量 grep 无命中）。它们可以继续作为 iOS 侧的**抽象名**使用，但不能声称是 ZCode 的符号。真实机制是三层叠加：

| 层 | ZCode 真实机制 | 回答的问题 | 谁读它 |
|---|---|---|---|
| L1 **模式** | `CollaborationMode` = `plan` / `build` / `edit` + `allowedInPlanMode` + plan-mode policy | 这一轮编排处于什么模式，默认放行哪类工具 | 循环 / 编排层 |
| L2 **单次能力** | 运行时解析的 `ResolvedPermissionCapability`（per-call，非 per-turn） | 这次调用实际能不能免询问 | 工具执行入口 |
| L3 **副作用域** | `sideEffectScope` | 这次调用会碰到哪些域 | 策略引擎 |
| L4 **规则集** | `PermissionRuleset { allow, deny, ask, ruleContent }` | 用户/项目是否已给出长期授权 | broker |

**L2 必须是运行时判定**：同一轮里读操作免询问、写操作仍要询问；环境因素（如"工作区未授权"）也会把 L2 压成不可写。

默认推导（`permission/service.ts:696-724` `resolveCapability()`）：

```
isReadOnlyTool(name)  → sideEffectScope = "none",    needsApproval = false, riskLevel = low
否则                   → sideEffectScope = "workspace", needsApproval = true
写工具 Write/Edit/ApplyPatch/Bash → riskLevel = medium
destructive 工具 Bash            → riskLevel = high
```

模式检查（`service.ts:631-645` `checkEditMode`）：`permissionName == "edit" && sideEffectScope == "workspace"` → 直接 `allow`。

**决策类型**（`contracts/src/interfaces/permission.port.ts`）：`allow | deny | escalate | modify`。
broker 是**异步**的（`requestPermission(req, { signal, timeoutMs })`），可返回 `modifiedInput` / `permissionUpdates`（持久规则）/ `sessionPermissionUpdates`（仅内存，不落盘）/ `inputAdjustments`。`approvalMode: "user-once"` 表示"只批这一次"。

### 4.1 sideEffectScope 的六个域与 iOS 映射

| 域 | iOS 落地 |
|---|---|
| `session` | 会话级状态（不做工具） |
| `workspace` | security-scoped resource 是否 active（`startAccessing...` 成功且未 `stop`） |
| `git` / `system` | iOS 上不存在 → 策略恒 `deny`（保留枚举值，便于将来） |
| `network` | 只有 provider 请求可发起；**文件工具永不发起网络** |
| `userInteraction` | 删除确认 alert；工具执行在此 `await` 用户决策 |

### 4.2 破坏性操作的提权

`delete`、覆盖写 → **必须 `ask`，且由用户显式确认**。在 iOS 里它是一个**可 `await` 的 UI 决策点**（工具执行挂起等用户点"删除/取消"），不是 fire-and-forget 弹个 alert 然后继续跑。

### 4.3 一期的规则集策略

iOS 一期只实现 `ask` 的两种粒度（`user-once` / `session-always-allow`），不做持久化 `allow/deny` 规则集编辑。理由：真机上重装即失效的持久授权价值低，且 UI 成本高。**登记为偏离 D-02**。

---

## 5. 移植不变量（验收用，逐条可测）

| ID | 不变量 | 验证方式 |
|---|---|---|
| I1 | 每个 `tool_call` 都有配对 `tool` 结果，顺序与 id 一致 | 假 provider 返回 3 个 call，断言 3 条结果且 id 匹配 |
| I2 | 工具错误以结构化结果回传，不冒泡到 UI，且**循环继续** | 让工具抛错，断言模型收到 `is_error` 且下一轮被调用 |
| I3 | 权限检查在 `ToolRegistry.execute` 入口 | 绕过 UI 直接调 execute，断言仍被拒 |
| I4 | 路径校验三重（standardize → symlink 解析 → pathComponents 前缀比对） | 用 `../`、绝对路径、指向外部的 symlink 三种输入验证拒绝 |
| I5 | 取消检查点 ≥ 3 处（请求前 / 流式 token 间 / 工具前后），且**取消后配对仍完整** | 中途 cancel，断言终态 `.cancelled`、无遗留 Task、每个 call 都有结果 |
| I6 | `maxTurns` 命中返回可读原因（`error_max_turns`） | 假 provider 永远返回 tool_calls |
| I7 | 工具结果按 `maxBytes` 截断；超预算先丢最老工具输出 | 读一个 10MB 文件 |
| I8 | 状态变更只在 MainActor / actor 内 | 开 Thread Sanitizer 跑一轮完整对话 |
| I9 | `.cancelled` 是独立终态，不渲染为错误 | cancel 后断言 UI 状态文案为"已停止" |
| I10 | 未知/空工具名 → 产出配对错误结果，回合继续 | 让模型调用不存在的工具，断言历史闭合且模型被再次调用 |
| I11 | 畸形参数 JSON → 降级 `{}`，不中断请求 | 喂 `{"path": ` 截断串，断言工具返回"参数缺失"错误且回合继续 |

---

## 6. 概念映射表

| ZCode | iOS |
|---|---|
| `runRegularTurnLoop()` | `actor AgentLoop`，对外 `AsyncThrowingStream<AgentEvent>` |
| `TurnMachine` / `TurnPhase` | `enum TurnPhase` + 迁移白名单（失败即断言） |
| `TurnResultType` | `enum TurnOutcome { success, cancelled, maxTurns, maxToolCalls, failed }` |
| `ModelToolSideEffectScope` | `enum SideEffectScope` |
| `PermissionRuleset` / broker | `actor PermissionGate`（`await` 决策，含 `user-once` / `session`） |
| provider 执行 | `protocol ModelProvider`，SSE 用 `URLSession.bytes(for:)`（iOS 15+） |
| 工具注册 | `actor ToolRegistry` + `protocol AgentTool` |
| `ToolMetadata` | `struct ToolCapability`（同上字段子集） |
| 消息 | `enum AgentMessage`（system/user/assistant/tool），`Codable` |
| 会话持久化 | JSON 落 Application Support（**不含 Key**） |
| `bootstrap` | `AppEnvironment`（组合根，注入 provider 与工具） |
| `abort` + `ToolCancelled` | `Task.cancel()` → 扫描未结算 call → 写 `.cancelled` 结果 → 抛 `.cancelled` 终态 |

---

## 7. 与 iOS 现实的三个落差（设计里必须承认，不要假装没有）

1. **没有持久目录授权**。`URL.BookmarkCreationOptions.withSecurityScope` 在 iOS **不可用**；iOS 的 security-scoped URL 冷启动后不能静默续用。
   → 方案：UserDefaults 存"目录标识"，启动时若无法解析则提示"重新选择工作区"。**不生成"重启后仍能静默访问"的代码**。

2. **没有后台长驻**。App 进后台即被挂起；`beginBackgroundTask` 只有约 30 秒，不能作为可靠性保证。
   → 方案：任务前台执行；切后台 = 暂停并保留可恢复状态（当前回合、已完成工具结果），回前台续跑或明确提示"任务已中断"。

3. **外部/云盘文件需要协调与下载**。iCloud Drive 里的文件可能是占位符，直接读会失败或长时间阻塞。
   → 方案：`NSFileCoordinator` 包裹读写；必要时先 `startDownloadingUbiquitousItem` 并给 UI"正在下载"状态。

---

## 8. 一期非目标

多人协作、远程沙箱执行、代码运行（无 Bash）、MCP、多模态、Agent 间编排（sub-agent / workflow）、后台定时任务、持久 permission 规则集编辑。

---

## 9. 勘误记录（v1 → v2，全部有源码出处）

| # | v1 的错误表述 | v2 校正 | 源码出处 |
|---|---|---|---|
| E1 | 主循环是 `memory-agent-loop.ts` | 主循环是 `runtime/methods/turn-loop.ts` 的 `runRegularTurnLoop()`；`memory-agent-loop.ts` 是 Memory 子 Agent 的受控循环 | `core/src/memory/memory-agent-loop.ts` 头注释；`core/src/runtime/methods/turn-loop.ts` |
| E2 | "ZCode 串行跑工具" | 按 `readOnly`/`concurrentSafe`/`sideEffectScope`/`destructive` 做拓扑分层，最多 10 并发；破坏性工具禁并行 | `core/src/tool/scheduler.ts:85-103`、`:233-243` |
| E3 | 权限分层是 `orchestrationReadOnly` / `effectiveReadOnly` | 两个符号在源码中不存在。真实机制 = `CollaborationMode` + `ResolvedPermissionCapability`（per-call）+ `PermissionRuleset` + `sideEffectScope` | 全量 grep 无命中；`core/src/permission/service.ts:696-724` |
| E4 | 中止 = 抛异常让上层处理 | 中止前**必须**为每个未完成 tool call 写 `ToolCancelled` 结果，保持 call↔result 配对，**再**抛 abort | `core/src/runtime/methods/turn-tools.ts:132-134`、`:262-267` |

> E1–E4 全部改变了 iOS 侧的实现要求，不是措辞问题。