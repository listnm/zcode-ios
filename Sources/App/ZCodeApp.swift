import SwiftUI

/// 应用入口。
///
/// 启动序列（顺序有意义）：
/// 1. 恢复工作区授权——跨启动多半失败，属预期行为（锚点 §7.1），UI 会提示重新授权；
/// 2. 恢复上次会话的消息历史——与工作区授权无关，即使没授权也应该能看到历史。
@main
struct ZCodeApp: App {

    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    await environment.workspace.restore()
                    await environment.chat.restoreSession()
                }
        }
    }
}