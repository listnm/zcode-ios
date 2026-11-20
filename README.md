# ZCode iOS

把 [zai-org/ZCode](https://github.com/zai-org/ZCode) 的 Agent 客户端移植到 iOS 的一个实现：用户选择一个文件夹作为**工作区**，Agent 只能在该工作区内读写文件、调用工具完成任务。支持自带模型（自己的 API Key / Base URL / Model ID）。

- 最低系统版本：**iOS 17.0**（`@Observable` 与 Swift Concurrency 的隔离模型）
- 语言 / 工具链：Swift 5.9+，Xcode 15.4+，工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成
- 无第三方依赖：Keychain、URLSession、SwiftUI、Foundation 全部来自系统 SDK

## 仓库与构建

- 源码仓库：<https://github.com/listnm/zcode-ios>
- 构建流水线：GitHub Actions（`macos-15`）→ `xcodegen generate` → `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO` → 打包 `Payload/` 成 `ZCode-unsigned.ipa`
- 最近一次成功构建：run #3。产出的 `ZCode-unsigned.ipa` 是 **arm64 设备包、未签名**，可直接用在自签工具里，但**不能直接装到 iPhone 上**——iOS 要求每个 App 都有有效签名。
- 本地（macOS）构建：`xcodegen generate && open ZCodeiOS.xcodeproj`，在 Xcode 里选真机 + 自己的开发者账号即可正常签名安装。

## 它做什么

1. 选择工作区（`UIDocumentPicker` 的文件夹模式），拿到 security-scoped 访问权；
2. 在设置里添加模型服务（任意 OpenAI 兼容端点，或 Anthropic 协议），API Key 存 Keychain；
3. 对话：模型返回 `tool_calls` → App 在工作区内执行 `list_files` / `read_file` / `write_file` / `delete_file` → 结果回传给模型 → 直到模型给出最终文本或达到最大轮次。

## 架构

移植时保留的是 ZCode 的**语义**，不是它的 Node 代码结构。对照表：

| ZCode（`apps/zcode-cli/packages/*`） | iOS 实现 | 语义 |
| --- | --- | --- |
| `core/src/runtime/methods/turn-loop.ts` | `Sources/Agent/AgentLoop.swift` | 回合制主循环：请求 → 工具 → 结果 → 再请求 |
| `core/src/agent/turn-machine.ts` | `AgentLoop` 的 while + `TurnOutcome` | 终止态：`success / cancelled / maxTurns / failed` |
| `core/src/tool/registry.ts` + `handlers/*` | `Sources/Workspace/WorkspaceFileTools.swift` | 工具能力元数据 + 执行入口校验 |
| `core/src/tool/executor/permission-flow.ts` | `Sources/App/ConfirmationCenter.swift` | 破坏性操作需用户当场确认 |
| `core/src/permission/service.ts` | `ToolCapability` 的 `readOnly` / `destructive` / `sideEffectScope` / `riskLevel` / `needsApproval` | 权限分级随工具声明走 |
| `adapters/src/model/*` | `Sources/Models/*Client.swift` | 按协议构造请求、流式解析、错误分类 |
| `contracts/src/interfaces/file-system.port.ts` | `Sources/Workspace/WorkspaceFileSystem.swift` | 唯一文件访问出口 |

### 目录

```
Sources/
  Contracts/     JSONValue、工具契约、对话消息契约（全 Sendable）
  Models/        Provider 配置、Keychain、LLM 客户端（OpenAI 兼容 / Anthropic）
  Agent/         Agent 循环、事件、会话持久化
  Workspace/     路径校验、security-scoped 授权、文件操作、9 个工具
  App/           组合根、确认中心、工作区状态
  UI/            对话页、设置页
scripts/         push_to_github.py（无 git 环境下推送源码）
.github/         build-ipa.yml（未签名 IPA）、build-signed-ipa.yml（签名 IPA）
docs/            架构锚点与各模块交付说明
```

### 几条不能破的规则

这些是从 ZCode 源码里读出来的不变量，移植时没有降级：

1. **配对性**：模型请求了 N 个 `tool_call`，历史里就必须有 N 条对应 `tool_call_id` 的结果。少一条，下次请求会被 OpenAI/Anthropic 直接判 400。**取消也照样补齐**（结果文本 `[cancelled] ...`）。
2. **失败即结果**：工具失败不终止回合，错误文本进历史，让模型自己修正。
3. **降级而非抛错**：工具名为空/未知、参数 JSON 畸形，一律降级为「工具产出错误结果」，不升级成整个请求失败。
4. **路径三重校验**：`standardizedFileURL` → `resolvingSymlinksInPath` → `pathComponents` 前缀比较（绝不用 `String.hasPrefix`，`/a/workspace-evil` 会骗过 `/a/workspace`）。
5. **Key 只在 Keychain**：`ModelProvider` 结构体里没有 apiKey 字段，编码进 UserDefaults 的只有非敏感配置。

## 构建

### 方式一：GitHub Actions（本仓库已配置，推荐）

推一次代码就会跑 `.github/workflows/build-ipa.yml`：

1. `xcodegen generate` 生成工程；
2. `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO` 编译 Release 包；
3. 把 `ZCodeiOS.app` 打成 `Payload/` 再 `zip` 成 `ZCode-unsigned.ipa`；
4. 作为 artifact 上传（保留 30 天）。

在 Actions 页面打开某次运行，底部 **Artifacts → ZCode-unsigned-ipa** 即可下载。

> **未签名 IPA 无法直接安装到 iPhone。** iOS 要求可执行文件带有效签名。未签名包只有三种用途：留档、给重签名工具（Sideloadly / AltStore / TrollStore / 企业重签）当输入、以及在越狱设备上使用。想直接装机请用下面的签名流程。

### 方式二：签名 IPA

配置以下仓库 secrets 后手动触发 **Build signed IPA (manual)**：

| secret | 内容 |
| --- | --- |
| `BUILD_CERT_P12_BASE64` | `.p12`（含证书 + 私钥）的 base64 |
| `BUILD_CERT_PASSWORD` | 该 `.p12` 的密码 |
| `PROVISIONING_PROFILE_BASE64` | 对应 `com.zcodeios.app` 的 `.mobileprovision` 的 base64 |
| `TEAM_ID` | 10 位 Apple Team ID |
| `BUNDLE_ID`（可选） | 覆盖默认 bundle id |

流程是 `xcodebuild archive` → `-exportArchive`（`method=development`）。个人开发者账号签出来的包需要设备 UDID 在描述文件里。

### 方式三：macOS 本地构建

```bash
brew install xcodegen
xcodegen generate
open ZCodeiOS.xcodeproj     # 选自己的 Team 后直接 Run
```

## 配置模型

设置 → 模型 → 添加模型服务：

| 字段 | 说明 |
| --- | --- |
| 显示名称 | 任意，用于对话页的模型选择器 |
| 协议 | `OpenAI 兼容`（`/chat/completions`）或 `Anthropic`（`/messages`） |
| Base URL | 需要带版本段，例如 `https://api.openai.com/v1`、`https://api.deepseek.com/v1`、`https://api.anthropic.com/v1`、Ollama 的 `http://127.0.0.1:11434/v1` |
| Model ID | 每行一个，第一个作为默认 |
| API Key | 存 Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`） |

对话页顶部胶囊可以在已启用的模型之间切换，**只影响当前会话**。

## iOS 平台限制（与 macOS 版 ZCode 的真实差异）

- **目录授权不能永久保存。** iOS 没有 `withSecurityScope` 书签。App 会把 security-scoped bookmark 存进 UserDefaults 尝试恢复，但系统在多数情况下会让它失效；失效时 UI 显示橙色提示并引导重新选择目录。这是平台限制，不是实现缺陷。
- **没有后台长驻。** App 进入后台后 Agent 任务会被挂起或终止；长任务需要保持前台。
- **iCloud / 外部存储的文件可能是占位符。** 读到的是 `NSFileCoordinator` 之外的原始字节，可能触发下载。一期不做协调读写。
- **模拟器与真机的权限行为不同。** 模拟器的 document picker 更容易“一直有效”，真机上更容易出现需要重新授权的情况，请以真机为准。

## 安全

- API Key：Keychain，`ThisDeviceOnly`，不进 UserDefaults、不进日志、不进构建产物。
- 文件：所有工具操作的路径都必须落在工作区内，越界直接拒绝并返回明确错误。
- 删除：必须弹确认框，用户拒绝时不执行且结果文本会劝阻模型重试。
- 网络：只连用户自己填的 Base URL；没有遥测、没有内置服务端。

## 开发状态

| 模块 | 内容 | 状态 |
| --- | --- | --- |
| 阶段 0 | ZCode 架构锚点（真实源码校正） | 完成 `docs/00-zcode-architecture-anchor.md` |
| 模块 A | 工作区（授权、路径边界、文件工具） | 完成 `docs/02-module-a-workspace.md` |
| 模块 B | 模型配置 + Keychain + 流式客户端 | 完成 |
| 模块 C | Agent 循环、执行卡片、取消、会话持久化 | 完成 |
| 模块 D | 对话 UI、设置页、空状态引导 | 完成 |
| 功能扩展 | 图标、多会话、Markdown、用量统计、计划模式、9 个工具 | 完成 |
| IPA | Actions 产出未签名包 / 可选签名包 | 已配置流水线 |

`docs/03-delivery.md` 里有每个模块的自检清单与手动验证步骤。

## 能力清单

**内置工具（9 个，全部限定在工作区内）**

| 工具 | 作用 | 只读 | 需要确认 |
| --- | --- | --- | --- |
| `list_files` | 列目录（可递归） | 是 | 否 |
| `glob` | 按 glob 找文件路径，如 `**/*.swift` | 是 | 否 |
| `grep` | 在文件内容里搜正则，输出 `文件:行: 文本` | 是 | 否 |
| `read_file` | 读文本（可按字节上限截断） | 是 | 否 |
| `write_file` | 写文件（覆盖已存在文件前确认） | 否 | 覆盖时 |
| `make_dir` | 建目录（含中间层） | 否 | 是 |
| `copy_file` | 复制文件 | 否 | 是 |
| `move_file` | 移动 / 重命名 | 否 | 是 |
| `delete_file` | 删除文件或目录 | 否 | 是 |

**模型配置**

- 只填 Base URL + API Key，点「从地址获取模型列表」即可自动请求 Base URL + /models，把返回的模型填进列表；地址填完、Key 打完后也会自动尝试一次（900ms 防抖）。
- 拉不到时仍可手打 Model ID，两种方式共存。解析兼容三种响应形状：{"data":[{"id":...}]}（OpenAI / Anthropic）、{"models":[{"name":...}]}（Ollama）、以及直接返回数组的简化网关。
- 协议按类型自动换鉴权头：OpenAI 兼容用 Authorization: Bearer，Anthropic 用 x-api-key + nthropic-version。

**对话能力**

- 多会话：任意新建、切换、重命名、删除；重启后从本地 JSON 恢复上一次会话。
- 计划模式：只把只读工具交给模型，并在系统提示词里说明「不要尝试写入或删除」。
- Markdown：代码围栏渲染成等宽块（可一键复制），正文走系统行内 Markdown 解析，不引入第三方库。
- 用量统计：读取服务端返回的 input/output tokens，在顶栏显示本轮累计。
- 执行卡片：每个 tool_call 一张卡，显示工具名、参数摘要、运行中 / 成功 / 失败 / 已取消，可展开看完整参数与结果。
- 随时停止：网络请求与工具执行都响应 `Task.isCancelled`；停止后为未完成的 tool_call 补齐 `[cancelled]` 结果，保证历史里的调用与结果始终配对。

**App 图标**：使用 ZCode 官方图标（白色 Z 字标 + 近黑底）。iOS 会自行加圆角遮罩，所以源图在 `Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` 里已经压平到不透明背景上。