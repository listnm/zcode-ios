import SwiftUI

/// 设置页：工作区管理 + 模型管理两级入口。
public struct SettingsView: View {

    @Environment(AppEnvironment.self) private var environment

    public init() {}

    public var body: some View {
        List {
            Section("工作区") {
                NavigationLink {
                    WorkspaceSettingsView()
                } label: {
                    SettingsRow(
                        icon: "folder",
                        title: "工作区",
                        subtitle: environment.workspace.snapshot.isActive
                            ? environment.workspace.snapshot.shortPath
                            : "未选择",
                        tint: environment.workspace.snapshot.isActive ? .accentColor : .orange,
                        showWarning: environment.workspace.snapshot.needsReauthorization
                    )
                }
            }

            Section("模型") {
                NavigationLink {
                    ProviderSettingsView()
                } label: {
                    SettingsRow(
                        icon: "cpu",
                        title: "模型管理",
                        subtitle: environment.providers.modelOptions.isEmpty
                            ? "未配置"
                            : "\(environment.providers.enabledProviders.count) 个服务 · \(environment.providers.modelOptions.count) 个模型",
                        tint: environment.providers.modelOptions.isEmpty ? .orange : .accentColor,
                        showWarning: false
                    )
                }
            }

            Section("扩展") {
                NavigationLink {
                    SkillsView()
                } label: {
                    SettingsRow(
                        icon: "lightbulb",
                        title: "技能",
                        subtitle: environment.skills.enabledSkills.isEmpty
                            ? "未启用（可添加可复用做法）"
                            : "\(environment.skills.enabledSkills.count) 个已启用 / 共 \(environment.skills.skills.count) 个",
                        tint: environment.skills.enabledSkills.isEmpty ? .secondary : .accentColor,
                        showWarning: false
                    )
                }

                NavigationLink {
                    PluginsView()
                } label: {
                    SettingsRow(
                        icon: "puzzlepiece.extension",
                        title: "插件",
                        subtitle: environment.plugins.enabledPlugins.isEmpty
                            ? "未启用（提示词扩展 + 工具白名单）"
                            : "\(environment.plugins.enabledPlugins.count) 个已启用",
                        tint: environment.plugins.enabledPlugins.isEmpty ? .secondary : .accentColor,
                        showWarning: false
                    )
                }
            }

            Section("关于") {
                LabeledContent("版本", value: Self.versionText)
                LabeledContent("Agent 循环", value: "回合制，最多 \(environment.chat.maxTurnsLimit) 轮")
                LabeledContent("内置工具", value: environment.tools.map { $0.capability.name }.joined(separator: "、"))
                NavigationLink {
                    AboutView()
                } label: {
                    Label("权限与数据说明", systemImage: "lock.shield")
                }
            }
        }
        .navigationTitle("设置")
    }

    static var versionText: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let showWarning: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if showWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 权限与数据说明。放在 App 内，而不是只写在 README 里。
struct AboutView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        List {
            Section("文件访问") {
                Text("ZCode 只能访问你通过系统文件选择器授权的那个文件夹。每次读写前都会校验目标路径是否在该文件夹内，越界的路径会被直接拒绝。")
                    .font(.callout)
            }

            Section("文件夹授权的限制") {
                Text("iOS 与 macOS 不同：没有可以在重启后长期使用的 security-scoped bookmark。App 会尽力保存书签并尝试恢复，但系统可能拒绝，因此重启后可能提示重新授权。重新选择同一个文件夹即可，文件本身不会被移动或复制。")
                    .font(.callout)
            }

            Section("API Key") {
                Text("Key 只保存在系统 Keychain，访问级别为「设备解锁后可读，且不随备份迁移」。App 不把 Key 写入配置、日志或任何上传通道。")
                    .font(.callout)
                Text("对话内容与工具结果会发送给你选择的模型服务商，直接连接、不经过中转服务器。是否上传文件内容取决于你让 Agent 执行的操作——read_file 的结果会作为工具结果进入请求。")
                    .font(.callout)
            }

            Section("取消与终止") {
                Text("随时可以点停止。取消会同时中断网络请求与正在执行的工具；已经请求的工具调用仍会各自得到一条「已取消」的结果，保证下一次请求的历史是完整的。")
                    .font(.callout)
            }

            Section("内置工具") {
                ForEach(environment.tools.map { $0.capability }, id: \.name) { capability in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(capability.name)
                                .font(.caption.monospaced())
                            Spacer()
                            Text(capability.readOnly ? "只读" : "写入")
                                .font(.caption2)
                                .foregroundStyle(capability.readOnly ? .green : .orange)
                        }
                        Text(capability.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("权限与数据")
        .navigationBarTitleDisplayMode(.inline)
    }
}