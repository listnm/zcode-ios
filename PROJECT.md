# ZCode iOS — 项目章程

> 项目代号：`zcode-ios`（产品形态：类「百度搭子」的工作区 Agent）
> 建立：2026-11-20
> 当前状态：**模块 A–D 代码完成；CI 首次构建通过（run #2），未签名 arm64 IPA 已产出；等待真机安装验证**

---

## 1. 目标

把 `zai-org/ZCode` 的 Agent 客户端移植为 iOS 原生应用：

1. 用户选择一个**文件夹**作为工作区（workspace）。
2. Agent 在该工作区内 `list / read / write / delete` 文件，按回合调用工具完成任务。
3. 支持自定义模型：用户填入自己的 `Base URL` + `API Key` + `Model ID`，协议支持 OpenAI-compatible 与 Anthropic。
4. 执行可视化（工具卡片）、可随时取消、会话可持久化恢复。

## 2. 非目标（一期）

- `exec` / shell / 子进程
- 浏览器自动化（WKWebView 只作为 UI，不作为工具）
- MCP（无 stdio；远程 HTTP MCP 二期再看）
- PDF / 图像理解
- git 操作、系统级操作
- 多 Agent 编排、后台常驻任务

## 3. 四阶段看板

| 阶段 | 内容 | 状态 | 交付物 |
|---|---|---|---|
| 0 | ZCode 架构锚点（语义基准） | ✅ 完成（v2，已用源码校正 4 处） | `docs/00-zcode-architecture-anchor.md` |
| 1 | 审计现有 iOS 项目 + 架构决策（自研 vs SDK） | ✅ 定案为自研（无现成工程可审；SDK 无法核实） | — |
| 2A | 工作区（fileImporter + security scope + 路径边界 + 删除确认） | ✅ 代码完成，待验证 | `docs/02-module-a-workspace.md` |
| 2B | 自定义模型配置（Keychain + Provider 抽象 + 流式） | ✅ 代码完成 | `docs/03-delivery.md` |
| 2C | Agent 循环与工具执行（含取消、卡片、持久化） | ✅ 代码完成 | `docs/03-delivery.md` |
| 2D | 对话 UI 与整体串联 | ✅ 代码完成 | `docs/03-delivery.md` |
| 3 | 各模块自检清单 | ✅ 随交付文档产出 | `docs/03-delivery.md` §自检 |
| 4 | 构建流水线（Actions → 未签名 IPA / 签名 IPA） | ✅ 已配置，待首次运行验证 | `.github/workflows/build-ipa.yml`、`build-signed-ipa.yml` |

**推进规则变更：** 原定"每个模块结束即停、等用户确认"。用户于 2026-11-20 明确要求"一次性弄好、推 GitHub、生成 IPA"，因此 B/C/D 三个模块连续实现，一次交付；自检清单集中在 `docs/03-delivery.md`。

## 4. 硬约束

| ID | 约束 |
|---|---|
| C1 | 文件访问只发生在 security-scoped 工作区内。路径校验三重：`standardizedFileURL` → `resolvingSymlinksInPath` → `pathComponents` 前缀比较（禁止字符串 `hasPrefix` 裸比较）。 |
| C2 | API Key 只存在于 Keychain。禁止写入 UserDefaults / plist / 日志 / 崩溃上报 / 源码常量。 |
| C3 | UI 状态变更限定在 `@MainActor`；Agent 循环与工具执行在 `actor` 内。禁止后台线程触碰 `@Published` / `@Observable` 状态。 |
| C4 | 工具失败以**结构化 tool result**（`is_error: true`）回传模型，不 `throw` 到 UI 层。 |
| C5 | 取消必须传播到正在进行的网络请求与文件操作；终态必须是 `cancelled`，不允许"转圈到底"。 |
| C6 | 每个新增 iOS API 在代码注释里标注最低可用版本（如 `// iOS 16.0+`）。 |
| C7 | 不引入未经评估的第三方依赖；SDK 取舍在阶段 1 显式决策并留档。 |

## 5. 待决事项

| ID | 事项 | 决定时机 |
|---|---|---|
| D1 | 继续自研 Agent 循环 vs 引入 Swift Agent SDK 作执行层 | ✅ 已定：自研（候选 SDK 无法核实，C7 不允许引入未评估依赖） |
| D2 | 工程形态：手写 `.xcodeproj` / XcodeGen `project.yml` / Swift Package + 薄壳 App | ✅ 已定：XcodeGen（`project.yml`），便于 CI 生成与评审 |
| D3 | 会话持久化：JSON 文件（Application Support） vs SwiftData | ✅ 已定：JSON 文件，按批次安全边界裁剪到 200 条 |
| D4 | 最低支持版本（建议 iOS 17，换取 Observation/SwiftData 与更稳的 fileImporter 语义） | ✅ 已定：iOS 17.0 |

## 6. 文档索引

- `docs/00-zcode-architecture-anchor.md` — 阶段 0 语义基准。**后续任何实现与之冲突，需在此文档记录变更理由。**
- `docs/02-module-a-workspace.md` — 模块 A 交付说明（工作区授权、路径边界、四个工具）。
- `docs/03-delivery.md` — 模块 B/C/D 交付说明、错误对照表、六条自检与手动验证步骤。
- `README.md` — 对外说明（能力、架构对照、构建与 IPA、限制）。
- `scripts/push_to_github.py` — 无 git 环境下的源码推送脚本（Git Data API）。
- `docs/01-audit.md` — 阶段 1 问题清单与架构决策（未产出：无现成工程可审，决策直接记在 §5）

## 7. 变更日志

- 2026-11-20：建立项目；完成阶段 0；确定硬约束 C1–C7 与待决项 D1–D4。
- 2026-11-20：**阶段 0 校正为 v2**。依据 `github.com/zai-org/ZCode@main` 真实源码修正 E1–E4：
  E1 主循环是 `runtime/methods/turn-loop.ts`（`memory-agent-loop.ts` 只是 Memory 子 Agent 循环）；
  E2 工具调度是"拓扑分层 + 最多 10 并发"，不是纯串行；
  E3 `orchestrationReadOnly`/`effectiveReadOnly` 在源码中不存在，真实机制是 `CollaborationMode` + per-call capability + `PermissionRuleset` + `sideEffectScope`；
  E4 取消必须先为每个未完成 call 写 `ToolCancelled` 结果再抛 abort（配对性优先于中止速度）。
  新增 §2.5 工具调用解析容错（空工具名 / 畸形 JSON 一律降级到工具层，不升级为请求失败）与不变量 I9–I11。
- 2026-11-20：**模块 B/C/D 与交付流水线落地**。新增 `Sources/Contracts/ChatContracts.swift`、`Sources/Models/*`（6 个文件）、`Sources/Agent/*`（3 个文件）、`Sources/UI/*`（5 个文件）；`ToolCapability` 增加 `parameters`（JSON Schema），`ChatMessage`/`ToolCall` 支持配对历史；`.github/workflows/build-ipa.yml` 产出未签名 IPA，`build-signed-ipa.yml` 在提供 secrets 时产出可安装 IPA；`scripts/push_to_github.py` 在无 git 的 Windows 环境下用 Git Data API 推送源码。
- 2026-11-20：**无编译器静态审查 + 13 项缺陷修复**（宿主无 Swift 工具链，由 subagent 逐行复核 27 个 `.swift`，必改 0 项编译错误；语义缺陷另修）：
  R1 两个客户端把错误 body 的 `await` 写进 `if let` 条件，成功路径也会先消费单遍 SSE 流 → 先判状态码再读 body；
  R2 `sessionID` 每次启动都是新 UUID，历史永远读空 → 落 UserDefaults 并在重置时轮换；
  R3 用户点停止后历史留下"有 tool_calls、无结果" → `stop()` 补 `[cancelled]` 结果并持久化；
  R4 回合间 `runs` 不清空导致兜底 id 撞键 → `send` 开头 `runs.removeAll()`；
  R5 重启后卡片状态无法判定 → 新增 `ToolRunState.unknown`，不再冒充成功；
  R6 保存失败仍写 Key 会留孤立 Keychain 条目 → Key 只在配置落盘成功后写入；
  R7 配置解码失败静默变空表并允许覆盖 → `loadFailed` 时禁止写回；
  R8 `setAPIKey` 失败无返回 → 返回 Bool 并透出原因；
  R9 越界软链在列表里输出**绝对路径** → 只输出文件名；
  R10 OpenAI 兼容客户端重复投递 `x-api-key` → 只发 `Authorization`；
  R12 `SessionStore.trim` 可能裁成空数组 → 改为按"不可分割批次"从尾部倒装；
  R13 报告误判（actor 内 `await` 冗余）→ 不采纳；
  R14 「用户停止」与「流自然断开」混为一谈 → `didUserStop` 区分终态。
  结构检查 `scripts/lint_structure.py`：27 文件 0 问题；三个 YAML 均通过 `yaml.safe_load`。

- 2026-11-20：**首次上云构建**。源码推送到 <https://github.com/listnm/zcode-ios>（无 git 环境，走 Git Data API 的 `scripts/push_to_github.py`）。
  run #1 失败并暴露一个真实编译错误：`AppEnvironment.swift:36:16 property cannot be declared public because its type uses an internal type`（`selectedTab: RootTab` 而 `RootTab` 是 internal）→ 把 `RootTab` 改为 `public`，提交 `346378aab9`。
  run #2 **成功**：`xcodebuild -sdk iphoneos` 产出 `ZCodeiOS.app`（arm64，二进制 1.74 MB）并打包为 `ZCode-unsigned.ipa`（454 526 字节），artifact 名 `ZCode-unsigned-ipa`，已由 `scripts/download_ipa.py` 取回到 `dist/`。
  附带修掉脚本侧两处平台问题：空仓库上 Git Data API 返回 409（不是 404）需先做引导提交；artifact 的 SAS 重定向不能带 `Authorization` 头。

## 8. 有意偏离登记（相对 ZCode）

| ID | 偏离 | 理由 | 影响 |
|---|---|---|---|
| D-01 | iOS 一期**串行**执行本批工具，不做并行调度 | 四个工具里 write/delete 触碰 workspace 域，本来就不满足并行条件；串行让取消检查点与卡片状态机简单一个量级 | 仅吞吐，不改语义。二期加 `grep` 等只读工具再按 ZCode 规则分组 |
| D-02 | 权限规则集一期只做 `user-once` / `session-always-allow`，不做持久 `allow/deny` 编辑 | 真机上持久授权价值低、UI 成本高 | 用户每次删除仍需确认（更严，不会更松） |
| D-03 | 工具名用 `list_files/read_file/write_file/delete_file`，不用 ZCode 的 `Read/Write/Glob` | 对模型更直观，且一期只有四个工具不会有歧义 | capability 元数据必须与 ZCode 等价（见锚点 §3.2 表） |

### 2026-11-20 功能扩展（v3）

- 图标：接入 ZCode 官方 Z 字标，压平为不透明 1024x1024，通过 Assets.xcassets + ASSETCATALOG_COMPILER_APPICON_NAME 生效。
- 会话：SessionStore 增加 index.json 索引，支持新建/切换/重命名/删除；ChatModel 的 sessionID 持久化到 UserDefaults。
- Markdown：新增 MarkdownText（围栏代码块 + 行内 Markdown + 复制按钮），替换纯 Text 气泡。
- 用量：AgentEvent 增加 usage，顶栏显示累计 tokens。
- 计划模式：只在只读工具集合里调度，并在系统提示词里说明。
- 工具：4 个扩展到 9 个（新增 glob / grep / make_dir / copy_file / move_file），只读在前、写在后。
- 模型参数：Provider 增加可选 temperature / maxOutputTokens，客户端按需注入。


### 技能与插件（m01065）

- 工作区选择「选不到文件夹」：不是授权逻辑问题，是系统选择器的交互（点一行=进入，需点右上角「打开」才选中）与个别提供方只声明 public.directory。ileImporter 的 llowedContentTypes 扩为 [.folder, .directory]，并在未选择状态提供「使用 App 内文件夹」直连 App 容器；WorkspaceModel.adoptAppContainer() 新增；ccessDenied 追加 iCloud 未下载的提示。
- 技能（Sources/Skills/SkillStore.swift）：SkillDefinition + SkillStore，落盘 Application Support/ZCodeSkills/skills.json，支持 Markdown（含最简 front matter）解析、启停、二次确认删除。
- 插件（Sources/Plugins/PluginStore.swift）：声明式的「系统提示词追加 + 工具白名单」，落盘 ZCodePlugins/plugins.json；白名单多插件取并集；JSON 导入支持单对象与数组。
- 接入 Agent：ChatModel 在计划模式过滤之后再按插件白名单收窄工具；系统提示词顺序为 基础 → 计划模式 → 插件 → 技能。
- UI：SkillsView / PluginsView 与各自编辑器、导入器；设置页新增「扩展」分区。
