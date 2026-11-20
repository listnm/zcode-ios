import SwiftUI

/// 历史会话抽屉。
///
/// 设计取舍：不做侧边栏（iPad 上才自然的形态），用一个 sheet 覆盖——
/// iPhone 是主要目标设备，sheet 的"打开-选-关"路径比手势侧滑更不容易误触。
///
/// 最低版本：`NavigationStack` 与 `swipeActions` 均需 iOS 16.0；
/// 本 App 的 deploymentTarget 是 iOS 17.0，因此无需额外标注。
struct SessionsView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var renaming: SessionStore.SessionSummary?
    @State private var renameText = ""
    @State private var pendingDelete: SessionStore.SessionSummary?

    private var chat: ChatModel { environment.chat }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task {
                            await chat.newSession()
                            dismiss()
                        }
                    } label: {
                        Label("新建会话", systemImage: "square.and.pencil")
                    }
                }

                Section("历史会话") {
                    if chat.sessionsList.isEmpty {
                        Text("还没有历史会话。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(chat.sessionsList) { item in
                            Button {
                                Task {
                                    await chat.switchTo(session: item.id)
                                    dismiss()
                                }
                            } label: {
                                row(item)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = item
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    renameText = item.title
                                    renaming = item
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await chat.refreshSessions() }
            .alert(
                "重命名会话",
                isPresented: Binding(
                    get: { renaming != nil },
                    set: { if !$0 { renaming = nil } }
                )
            ) {
                TextField("标题", text: $renameText)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    guard let target = renaming else { return }
                    let title = renameText
                    renaming = nil
                    Task { await chat.renameSession(target.id, to: title) }
                }
            }
            .alert(
                "删除这个会话？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { target in
                Button("删除", role: .destructive) {
                    pendingDelete = nil
                    Task { await chat.deleteSession(target.id) }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { target in
                Text("「\(target.title)」的全部对话与工具记录都会被移除，无法恢复。")
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SessionStore.SessionSummary) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(Self.subtitle(item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.id == chat.sessionID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private static func subtitle(_ item: SessionStore.SessionSummary) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "\(formatter.string(from: item.updatedAt)) · \(item.messageCount) 条消息"
    }
}