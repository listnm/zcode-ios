# 交付说明：模块 B / C / D 与整体自检

本文覆盖「自定义模型配置」「Agent 循环与工具执行」「对话 UI 与串联」三个模块的交付内容、与 ZCode 的语义对应、手动验证步骤，以及交付前自检结论。模块 A（工作区）见 `docs/02-module-a-workspace.md`。

---

## 模块 B：自定义模型配置

### 文件

| 文件 | 作用 |
| --- | --- |
| `Sources/Models/ProviderConfig.swift` | `ProviderAPI`（openAICompatible / anthropic）、`ModelProvider`（**不含 apiKey**）、`ModelOption` |
| `Sources/Models/APIKeyStore.swift` | Keychain 读写删，`ThisDeviceOnly`，幂等删除 |
| `Sources/Models/LLMClient.swift` | `ModelClient` 协议、`StreamEvent`、`LLMError`（九类）、HTTP 状态映射 |
| `Sources/Models/OpenAICompatibleClient.swift` | `/chat/completions` + SSE |
| `Sources/Models/AnthropicClient.swift` | `/messages` + 事件流 + tool_use/input_json_delta 组装 |
| `Sources/Models/ProviderStore.swift` | 持久化（只存非敏感字段）、`makeClient(for:)`、默认选择 |
| `Sources/UI/ProviderSettingsView.swift` | 服务列表 / 编辑表单 / 首次保存的数据去向说明 |

### 三个决定

1. **模型层不含 Key。** `ModelProvider` 是 `Codable`，会被 `JSONEncoder` 写进 UserDefaults；把 apiKey 放进结构体是最常见的泄漏路径（任何一个 `print(provider)` 都会带出来）。Key 只在 `APIKeyStore` 里以 `providerID` 为键存放。
2. **两条协议走同一个 `ModelClient` 协议。** 上层（AgentLoop / ChatModel）只知道 `stream(provider:apiKey:model:messages:tools:systemPrompt:)`，协议差异被关在 `ProviderStore.makeClient` 一个 `switch` 里。
3. **错误必须可读。** `LLMError` 区分「Key 无效」「Base URL 不可达」「模型不存在」「限流」「请求体非法」「服务端错误」「流格式异常」「已取消」，每个都有中文 `errorDescription`，UI 直接显示，不静默失败也不无限转圈。

### 错误 → 提示对照

| 现象 | `LLMError` | 用户看到的文案（节选） |
| --- | --- | --- |
| 401 / 403 | `invalidAPIKey` | 「X」的 API Key 无效或已过期…请到设置里更新 Key。 |
| 404 | `modelNotFound` | 该服务上没有名为 … 的模型，请检查 Model ID。 |
| 429 | `rateLimited` | 触发限流，请稍后再试（服务端建议 N 秒后重试）。 |
| 5xx | `serverError` | 模型服务返回 NNN，稍后重试或换一个服务。 |
| DNS / TLS / 连接失败 | `unreachable` | 连不上 Base URL，检查网络与地址。 |
| 流中断、非 JSON 帧 | `malformedStream` | 流式响应异常中断。 |

---

## 模块 C：Agent 循环与工具执行

### 文件

| 文件 | 作用 |
| --- | --- |
| `Sources/Agent/AgentContracts.swift` | `ToolRun` / `ToolRunState` / `TurnOutcome` / `AgentEvent` / `ToolCallAccumulator` |
| `Sources/Agent/AgentLoop.swift` | 回合制主循环 + 工具执行 + 取消配对补齐 + 系统提示词 |
| `Sources/Agent/SessionStore.swift` | 会话 JSON 持久化（最多 200 条，按批次安全边界裁剪） |

### 循环与 ZCode 的对应

```
turns = 0
while true:
    if Task.isCancelled        → finished(.cancelled)      # 对应 TurnResultType.cancelled
    if turns >= maxTurns       → finished(.maxTurns(n))    # 对应 error_max_turns
    turns += 1
    stream(model)  → 累积文本 + 累积 tool_call 分片
    append(assistant)                                      # 即使只有 tool_calls、没有文本
    if tool_calls.isEmpty      → finished(.success)         # 终态
    for call in tool_calls:                                 # 串行（PROJECT.md D-01）
        yield(.toolStarted) → execute → yield(.toolFinished)
        append(tool result) → yield(.toolCommitted)         # 配对：一个 call 一条 result
    # 工具失败不 break（I2），继续下一轮
```

### 取消语义

- `ChatModel.stop()` → `runTask.cancel()` → `AgentLoop` 的流 `onTermination` 也会取消内部 Task；
- 网络侧：`URLSession.AsyncBytes` 迭代在任务取消时抛 `URLError.cancelled` / `CancellationError`，被映射成 `LLMError.cancelled` 与 `finished(.cancelled)`；
- 工具侧：每个工具执行前后都检查 `Task.isCancelled`，被中断的工具返回 `[cancelled] ...`；
- **配对补齐**：批次中途取消时，尚未执行的 call 由 `commitCancelled` 逐条补出 `toolStarted` + `toolFinished` + `toolCommitted`，保证历史里 call 与 result 一一对应；
- UI：`cancelled` 是独立终态，显示橙色「已停止」，不渲染成错误，也不会转圈到底。

### 执行卡片

`ToolRun` 携带工具名、参数摘要（单行、超长截断）、完整参数 JSON、状态、结果文本、耗时。卡片折叠时显示状态图标 + 工具名 + 参数摘要；展开后显示完整参数与结果（失败时结果文本保留，供模型自我修正，也供用户判断）。

---

## 模块 D：对话 UI 与串联

| 文件 | 作用 |
| --- | --- |
| `Sources/UI/ChatModel.swift` | 会话状态：消息、卡片、流式文本、终态、错误；`send` / `stop` / 持久化 |
| `Sources/UI/ChatView.swift` | 消息列表、执行卡片、输入区、模型选择器、空状态三步引导 |
| `Sources/UI/SettingsView.swift` | 设置入口、关于页（权限与数据说明） |
| `Sources/UI/RootView.swift` | TabView + 全局删除确认 alert |

- 三类气泡：用户（右侧蓝）、助手（左侧）、工具（`ToolRunCard`，随所属助手消息渲染）。
- 顶部显示工作区短路径（`…/最后两层`）与当前模型胶囊。
- 空状态三步：选择工作区 → 配置模型 → 开始对话；未完成前置条件时输入框禁用并给出原因。
- 导航：对话页 ⇄ 设置页（工作区管理 / 模型管理），`selectedTab` + `wantsWorkspacePicker` 支持从空状态一键跳到选择器。

---

## 交付前自检（六条）

### 1. 所有文件操作是否被限制在用户授权的工作区内？

是。所有路径先经 `WorkspacePathResolver.resolve`：

1. 拒绝空串、含 `\0`、`/` 或 `~` 开头的绝对/主目录路径；
2. 逐段消解 `.` / `..`，`..` 越过根即拒绝；
3. 拼成 URL 后 `resolvingSymlinksInPath().standardizedFileURL`；
4. 用 `pathComponents` 前缀比较确认仍在根内（不用 `String.hasPrefix`，避免 `/a/w-evil` 骗过 `/a/w`）；
5. 列表遍历不跟随软链，指向工作区外的软链只标注「已忽略」。

**手动验证**：新建文件夹 `ws`，在其中放 `a.txt`；再建同级的 `ws-evil/secret.txt`。让模型 `read_file ../ws-evil/secret.txt`、`read_file /etc/passwd`、`list_files ..`——三次都应返回「超出工作区范围」类错误，且 `secret.txt` 未被读取。

### 2. API Key 是否只存在于 Keychain？

是。`ModelProvider` 无 Key 字段；`ProviderStore.persist()` 只编码 `[ModelProvider]`；Key 仅经 `APIKeyStore`（`kSecClassGenericPassword` + `WhenUnlockedThisDeviceOnly`）读写；日志与错误文案中只出现 provider 显示名与 HTTP 状态，不打印请求头。

**手动验证**：配置一个 provider 后，用 Xcode → Devices 导出 App 容器，检查 `Library/Preferences/*.plist` 中无 Key 字段；再在 Keychain Access（模拟器）确认存在 `com.zcodeios.apikey` 条目。

### 3. 达到 maxTurns 或用户取消时是否干净终止、没有遗留 Task？

- `maxTurns`：循环在请求模型之前判断，直接 `finished(.maxTurns(n))` 并 `continuation.finish()`；
- 取消：`Task.isCancelled` 检查点覆盖「每轮开始 / 每个流事件 / 每个工具执行前后」；流的 `onTermination` 兜底取消内部 Task；`ChatModel` 结束后必定清 `runTask`、复位 `isRunning`；
- 兜底：`ChatModel` 在 `for await` 结束后若 `outcome == nil`（例如流被外部提前结束）统一补 `finish(.cancelled)`。

**手动验证**：把一个 provider 的 Base URL 指向不可达地址并开始发送，点「停止」→ 立刻回到「已停止」，输入框恢复可用；再发一条新消息，历史里不应出现上一轮缺失的工具结果。

### 4. 流式断开或 API 报错时 UI 是否给可读反馈？

是。所有 `LLMError` 都带中文 `errorDescription`，`ChatModel` 把它放进 `errorText` 并 `finish(.failed(...))`；`ChatView` 在输入区上方显示红色错误条，终态横幅显示失败原因。不存在「转圈到底」的分支：`isRunning` 只由终态事件或 `stop()` 复位。

**手动验证**：① Key 改错 → 401 文案；② Base URL 改成不存在的域名 → 不可达文案；③ Model ID 改成不存在的 → 模型不存在文案；④ 飞行模式中途断网 → 流异常/不可达文案。

### 5. 新增的 iOS API 是否标注了最低可用版本？

| API | 最低版本 | 说明 |
| --- | --- | --- |
| `@Observable` / `Observation` | iOS 17.0 | 工程 deployment target 即 17.0，无需 `@available` 分支 |
| `AsyncThrowingStream` / `AsyncSequence` | iOS 15.0 | 低于目标版本 |
| `URLSession.AsyncBytes`、`.lines` | iOS 15.0 | 低于目标版本 |
| `TextField(axis:)` | iOS 16.0 | 低于目标版本 |
| `ContentUnavailableView` | iOS 17.0 | 与目标版本一致 |
| `onChange(of:initial:_:)` 两参数形式 | iOS 17.0 | 与目标版本一致 |
| `.fileImporter(allowedContentTypes:)` | iOS 14.0 | 低于目标版本 |
| Keychain `SecItem*` | iOS 2.0 | 系统框架 |

因此整个工程无需版本分支；若将来降级到 iOS 16，需要替换 `@Observable`、`onChange` 两参数形式与 `ContentUnavailableView`。

### 6. 权限与文件路径逻辑的手动验证步骤

1. 首次启动 → 对话页空状态 → 点「选择工作区」→ 自动跳到设置页并弹文件夹选择器；
2. 选一个含中文名的文件夹 → 返回设置页 → 显示目录名、完整路径、「授权有效」；
3. 让模型 `list_files .` → 返回文件名列表（含中文名不出现乱码）；
4. `write_file notes/摘要.txt` → 在「文件」App 里打开该文件夹确认文件存在；
5. `delete_file notes/摘要.txt` → 弹确认框；点「取消」→ 结果文本为「用户拒绝删除…」，文件仍在；再执行一次点「确认」→ 文件消失；
6. 杀进程重启 → 设置页出现「需要重新授权」橙色提示（真机大概率如此，模拟器可能仍有效）→ 重新选择目录后恢复；
7. 工程内 `read_file ../../etc/hosts` → 拒绝并给出明确错误。

---

## 已知未做（一期范围外）

- 目录的持久授权（平台限制，只能重新授权）
- 工具并行执行（`PROJECT.md` D-01，串行是有意选择）
- 持久化的 allow/deny 规则编辑（D-02，一期只有「当场确认」与「本次会话始终允许」）
- 工具名沿用 ZCode 的 `Read`/`Write`/`Glob` 风格（D-03，改为 `read_file` 等更贴近文件语义的名字）
- iCloud 占位符文件的 `NSFileCoordinator` 协调读
- 图片 / PDF / 浏览器 / MCP 工具（ZCode 有，iOS 一期不需要）