import SwiftUI

/// 根导航：对话页 + 设置页。
///
/// 设置页是 `NavigationStack` 的根，两级：设置 → （工作区 | 模型管理）。
/// 全局确认弹窗仍挂在这里，保证任何工具在执行中需要用户拍板都只有一个出口。
struct RootView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment

        TabView(selection: $environment.selectedTab) {
            ChatView()
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                .tag(RootTab.chat)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(RootTab.settings)
        }
        .alert(
            environment.confirmations.pending?.title ?? "",
            isPresented: confirmationBinding,
            presenting: environment.confirmations.pending
        ) { request in
            Button(request.confirmTitle, role: .destructive) {
                environment.confirmations.resolve(id: request.id, approved: true)
            }
            Button("取消", role: .cancel) {
                environment.confirmations.resolve(id: request.id, approved: false)
            }
        } message: { request in
            Text(request.message)
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { environment.confirmations.pending != nil },
            set: { isPresented in
                if !isPresented {
                    environment.confirmations.cancelPending()
                }
            }
        )
    }
}

/// 顶部 Tab 的标识。定义在文件作用域，因为组合根也要用它记录选中项；
/// 组合根是 public，所以这个类型也必须是 public，否则会报
/// "property cannot be declared public because its type uses an internal type"。
public enum RootTab: Hashable {
    case chat
    case settings
}