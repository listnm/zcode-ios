import SwiftUI
import UniformTypeIdentifiers

/// 设置页：工作区管理。
///
/// 这一页是 iOS 权限模型的全部可见面：用户在这里授权一次，
/// 之后所有文件操作都在那个安全作用域里发生（越界由 `WorkspacePathResolver` 拒绝）。
struct WorkspaceSettingsView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var showImporter = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        Form {
            statusSection
            limitationSection
            removalSection
        }
        .navigationTitle("工作区")
        .navigationBarTitleDisplayMode(.inline)
        // iOS 14+。只允许选文件夹：Agent 的工作区语义是「一个目录」，不是单个文件。
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .onChange(of: environment.wantsWorkspacePicker) { _, wants in
            guard wants else { return }
            environment.wantsWorkspacePicker = false
            showImporter = true
        }
        .alert("移除工作区？", isPresented: $showRemoveConfirmation) {
            Button("移除", role: .destructive) {
                Task { await environment.workspace.forget() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会清除本应用记录的授权，不会删除文件夹中的任何文件。")
        }
    }

    // MARK: - 状态

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if environment.workspace.isReady {
                LabeledContent("目录名", value: environment.workspace.snapshot.displayName)
                VStack(alignment: .leading, spacing: 4) {
                    Text("完整路径")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(environment.workspace.snapshot.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Label("授权有效，可以开始对话", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout)

                Button("更换工作区") { showImporter = true }
            } else {
                ContentUnavailableView {
                    Label("未选择工作区", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("选择一个文件夹后，Agent 才能在其中读写文件。")
                }
                Button("选择工作区") { showImporter = true }
                    .buttonStyle(.borderedProminent)
            }

            if environment.workspace.snapshot.needsReauthorization {
                Label(
                    "上次选择的工作区已无法自动恢复访问权限，请重新选择同一个文件夹。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if let error = environment.workspace.lastError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                Button("知道了") { environment.workspace.clearError() }
                    .font(.callout)
            }

            if environment.workspace.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在获取访问权限…").font(.callout)
                }
            }
        } header: {
            Text("当前工作区")
        } footer: {
            Text("Agent 的所有文件操作都限制在这个目录内；指向目录之外的请求会被直接拒绝。")
        }
    }

    // MARK: - 限制说明

    private var limitationSection: some View {
        Section {
            Text("""
            iOS 与 macOS 不同：系统不允许应用把「文件夹访问授权」永久保存。\
            因此每次冷启动后，应用可能无法继续访问上次选的目录，需要你重新选择一次（选同一个文件夹即可，文件不会被移动或修改）。

            这个限制来自 iOS 的安全沙盒机制，任何第三方 App 都无法绕过。
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("关于权限的说明")
        }
    }

    // MARK: - 移除

    @ViewBuilder
    private var removalSection: some View {
        if environment.workspace.isReady || environment.workspace.snapshot.needsReauthorization {
            Section {
                Button("移除工作区", role: .destructive) {
                    showRemoveConfirmation = true
                }
            } footer: {
                Text("移除后需要重新选择目录才能继续使用文件工具。")
            }
        }
    }

    // MARK: - 导入回调

    /// `.fileImporter` 回调。
    ///
    /// 安全作用域的 `start/stop` **不在这里**做——统一交给 `WorkspaceScope.adopt`。
    /// 理由：回调返回后 UI 不再持有这次授权，若在这里 start 而不 stop 会造成泄漏；
    /// 若在这里 start 又立刻 stop，后续工具就没有权限。让 actor 成为唯一持有者。
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await environment.workspace.adopt(url) }
        case .failure(let error):
            // 用户点“取消”通常也会走到 failure，用 NSUserCancelledError 区分。
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSUserCancelledError {
                return
            }
            environment.workspace.reportError("打开目录选择器失败：\(error.localizedDescription)")
        }
    }
}