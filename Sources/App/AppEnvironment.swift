import Foundation
import Observation

/// 组合根（对应 ZCode 的 `@zcode/bootstrap`：把 port 实现装配进 core）。
///
/// 依赖图：
///
///     AppEnvironment
///       ├─ WorkspaceScope        (actor，security scope 生命周期)
///       ├─ WorkspaceFileSystem   (actor，唯一真实文件 IO)
///       ├─ ConfirmationCenter    (MainActor，破坏性操作确认)
///       ├─ WorkspaceModel        (MainActor，UI 镜像)
///       ├─ ProviderStore         (MainActor，Provider 配置 + Keychain 句柄)
///       ├─ SessionStore          (actor，消息历史持久化)
///       ├─ ChatModel             (MainActor，对话状态机 + Agent 循环驱动)
///       └─ [AgentTool]           (薄壳，注入上面几个依赖)
///
/// 依赖方向单向：UI → ChatModel → AgentLoop（值类型）→ AgentTool → actor。
/// 没有任何回边，也没有跨隔离域的引用共享。
@MainActor
@Observable
public final class AppEnvironment {

    public let scope: WorkspaceScope
    public let fileSystem: WorkspaceFileSystem
    public let confirmations: ConfirmationCenter
    public let workspace: WorkspaceModel
    public let providers: ProviderStore
    public let sessions: SessionStore
    public let chat: ChatModel
    public let tools: [any AgentTool]

    // MARK: - 跨页面导航状态

    /// 当前 Tab。放在组合根里，是为了让「去选择工作区」这类引导能跨 Tab 生效。
    public var selectedTab: RootTab = .chat
    /// 请求设置页立刻弹出目录选择器（由引导按钮置 true，选择器关闭后复位）。
    public var wantsWorkspacePicker = false

    public init() {
        let scope = WorkspaceScope()
        let fileSystem = WorkspaceFileSystem(scope: scope)
        let confirmations = ConfirmationCenter()
        let providers = ProviderStore()
        let sessions = SessionStore()
        let dependencies = WorkspaceToolDependencies(
            fileSystem: fileSystem,
            confirmations: confirmations
        )
        let tools = WorkspaceToolFactory.makeAll(dependencies: dependencies)

        self.scope = scope
        self.fileSystem = fileSystem
        self.confirmations = confirmations
        self.workspace = WorkspaceModel(scope: scope)
        self.providers = providers
        self.sessions = sessions
        self.tools = tools
        self.chat = ChatModel(providers: providers, sessions: sessions, tools: tools)
    }

    /// 按名字查工具。Agent 循环执行 tool_call 时用（未知名字 → nil → 产出配对错误结果）。
    public func tool(named name: String) -> (any AgentTool)? {
        tools.first { $0.capability.name == name }
    }
}