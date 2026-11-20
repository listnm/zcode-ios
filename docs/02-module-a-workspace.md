# 模块 A：工作区（fileImporter + security scope + 路径边界 + 删除确认）

> 状态：代码完成，待真机验证
> 对应锚点：§4 权限分层、§7.1 iOS 无持久目录授权、不变量 I4

---

## 1. 交付文件

| 文件 | 职责 |
|---|---|
| `Sources/Workspace/WorkspaceError.swift` | 11 种可区分的失败原因（中文可读），工具层据此产出结构化错误 |
| `Sources/Workspace/WorkspacePathResolver.swift` | 纯函数路径解析：词法归一化 → 软链解析 → pathComponents 前缀比对 |
| `Sources/Workspace/WorkspaceScope.swift` | actor，security scope 的**唯一**持有者；bookmark 落盘与恢复 |
| `Sources/Workspace/WorkspaceFileSystem.swift` | actor，唯一真实 IO：list / read / write / delete / exists / describe |
| `Sources/Workspace/WorkspaceFileTools.swift` | 四个 `AgentTool` 薄壳 + 依赖结构 + 工厂 |
| `Sources/App/ConfirmationCenter.swift` | @MainActor 可 await 的确认点（破坏性操作） |
| `Sources/App/WorkspaceModel.swift` | @MainActor UI 镜像，只搬快照不做判断 |
| `Sources/App/AppEnvironment.swift` | 组合根（对标 `@zcode/bootstrap`） |
| `Sources/App/ZCodeApp.swift` | 入口，启动时尝试 restore |
| `Sources/UI/RootView.swift` | Tab 骨架 + 全局确认弹窗出口 |
| `Sources/UI/WorkspaceSettingsView.swift` | 设置页：选择/更换/移除工作区、限制说明、错误提示 |
| `Sources/Info.plist`、`project.yml` | 工程配置（XcodeGen，iOS 17.0，Swift 5.9，strict concurrency complete） |

---

## 2. 三个关键设计决策

### 2.1 security scope 只能有一个持有者

`.fileImporter` 的回调里**不**调用 `startAccessingSecurityScopedResource()`，只把 URL 交给
`WorkspaceScope.adopt(_:)`。理由：

- 回调里 start 之后没有任何安全的 stop 位置（UI 不持有生命周期），必然泄漏；
- 回调里 start 完立刻 stop，则后续工具全部失权；
- start 返回 `false` 表示"调用方本来就有权"（picker 刚返回的 URL 就是这种情况），
  此时若我们 stop，会把别人的授权关掉。所以在 actor 里记 `startedByUs`，只 stop 自己 start 的。

`adopt` 的顺序是：先 `release()` 旧的 → start → `probe()` 真实枚举一次 → 失败则回滚 stop 并抛
`accessDenied`。`startAccessing` 返回 true 不代表目录可读，必须实测。

### 2.2 路径校验三重，且拒绝"字符串前缀"

`WorkspacePathResolver.resolve` 的顺序：

1. 含 `\0` → `invalidPath`；以 `/` 或 `~` 开头 → `outsideWorkspace`（不给任何绝对路径的机会）；
2. 自写 `normalize` 按 `/` 切分消解 `.` 与 `..`，`..` 越过根立刻判越界（不留"待解析"空间）；
3. 逐段 `appendPathComponent` → `resolvingSymlinksInPath().standardizedFileURL`；
4. `contains` 用 `pathComponents` 数组前缀比较。

为什么不能用 `hasPrefix`：`/var/mobile/…/workspace-evil` 会骗过 `/var/mobile/…/workspace`。

软链在 `list` 里也处理了：解析后越界的条目输出 `[symlink → 工作区外，已忽略]` 而不跟随，
因此递归列表既不会逃逸也不会成环。

### 2.3 确认中心只有一个 pending

工具执行串行（PROJECT.md D-01），任何时刻最多一个待确认请求。若第二个人来要确认，
直接返回 `.denied` 而不是排队——排队会让两个 `CheckedContinuation` 交错，出现双 resume 崩溃或悬空 Task。

取消路径三条都覆盖：`withTaskCancellationHandler` 的 `onCancel`、注册后立刻复查
`Task.isCancelled`、以及 Agent 被整体停止时调用 `cancelPending()`。`finish` 返回布尔并清空
continuation，从根上防双 resume。

---

## 3. 与 ZCode 的语义对应

| ZCode | 本模块 |
|---|---|
| `ToolMetadata.readOnly` | `ToolCapability.readOnly`（list/read 为 true） |
| `ToolMetadata.destructive` | `delete_file.destructive = true` |
| `ToolMetadata.sideEffectScope` | 读工具 `.none`，读写工具 `.workspace` |
| `ToolMetadata.riskLevel` | low / medium / high 三档 |
| `ToolMetadata.needsApproval` | 读工具 false，写工具 true |
| `PermissionBrokerPort.requestPermission` | `ConfirmationCenter.request(...)` → approved / denied / cancelled |
| `approvalMode: "user-once"` | 一期不落任何 remember 规则（D-02） |

工具名按 D-03 用了 `list_files / read_file / write_file / delete_file`，
capability 元数据保持与 ZCode 等价（不是"简化成没有"）。

---

## 4. 真机 / 模拟器差异（必须知道）

| 行为 | 模拟器 | 真机 |
|---|---|---|
| 冷启动后 `restore()` 成功 | 经常成功（sandbox 弱化） | **通常失败**，返回 `needsReauthorization` |
| iCloud Drive / "我的 iPhone" 目录 | 大多正常 | 云端文件可能未下载，`contentsOfDirectory` 会触发 Download |
| `startAccessingSecurityScopedResource()` 返回 true 但不可读 | 少见 | 更常见（授权已失效的陈旧 URL） |

因此 `restore()` 失败是**预期行为**，不是 bug；UI 会显示提示条引导重选。
跨启动可靠访问目录，iOS 上唯一可行的产品方案就是"每次任务开始前请用户确认工作区"。

---

## 5. 手动验证步骤

前置：`brew install xcodegen` → 在工程根目录 `xcodegen generate` → 用 Xcode 打开 `ZCodeiOS.xcodeproj`。

1. **选择工作区**：设置页 → 选择工作区 → 选一个文件夹 → 返回后应显示目录名、完整路径、绿色"授权有效"。
2. **越界拒绝**：临时在 `WorkspaceSettingsView` 之外的地方调用一次
   `try WorkspacePathResolver(root: workspaceURL).resolve("../etc/passwd")`，
   必须抛 `outsideWorkspace`；`resolve("/etc/passwd")` 同样抛 `outsideWorkspace`。
3. **软链逃逸**：在工作区里 `ln -s /etc/hosts ./escape`，执行 `list_files`，
   该条目必须显示 `[symlink → 工作区外，已忽略]`，且 `read_file("escape")` 必须报 `outsideWorkspace`。
4. **删除确认**：让 Agent 调 `delete_file`（模块 C 完成后可真实触发；现在可临时在设置页加调试按钮直接调工具），
   必须弹 alert；点"取消"→ 工具结果为 `用户拒绝删除…`；点"删除"→ 文件消失。
5. **根目录保护**：`delete_file(path: ".")` 必须报 `不能删除工作区根目录`。
6. **授权失效**：选中工作区后，去「文件」App 把该目录改名 → 回到应用执行 `list_files`，
   应得到 `无法访问工作区…请重新选择`，而不是闪退或空白。
7. **冷启动**：彻底杀掉 App 再启动 → 设置页应出现橙色"已无法自动恢复访问权限"提示（真机上），
   或正常恢复（模拟器上常见）——两者都算通过。

---

## 6. 自检清单（阶段 3）

| # | 检查项 | 结论 |
|---|---|---|
| 1 | 所有文件操作是否被限制在用户授权的工作区内？ | ✅ 所有 IO 经 `WorkspaceFileSystem` → `WorkspacePathResolver.resolve`，三重校验；`list` 额外过滤越界软链；`delete` 禁止删根。UI 层与工具层都不持有 `FileManager`。 |
| 2 | API Key 是否只在 Keychain，无明文泄漏路径？ | N/A（本模块不涉及 Key）。模块 B 落地时统一核对。 |
| 3 | maxTurns / 取消是否干净终止，没有遗留 Task？ | 本模块无循环；确认点的取消路径已覆盖（onCancel + 复查 + cancelPending，`finish` 防双 resume）。 |
| 4 | 流式断开或 API 报错时 UI 是否有可读反馈？ | N/A（本模块无网络）。文件错误的可读反馈已覆盖：11 种 `WorkspaceError` 均有中文 `errorDescription`，UI 与模型都能读到具体原因。 |
| 5 | 新增 iOS API 是否标注最低版本？ | ✅ `startAccessingSecurityScopedResource`（iOS 8+）、`bookmarkData/resolvingBookmarkData`（iOS 4+/8+）、`fileImporter`（iOS 14+）、`ContentUnavailableView` / `onChange(of:_:)` 双参（iOS 17+）、`@Observable`（iOS 17+）。代码注释已标。 |
| 6 | 权限与路径逻辑是否附手动验证步骤？ | ✅ 见 §5 七步。 |

---

## 7. 已知未做（有意为之）

- 不做持久 allow/deny 规则编辑（D-02），每次破坏性操作都问；
- 不做并行工具执行（D-01）；
- `read_file` 不支持二进制 / 图片（报 `notText`），二期配合 PDF/Image 工具一起做；
- 不做文件监听（`NSFileCoordinator` / `DispatchSource`），一期靠模型主动 `list_files`。