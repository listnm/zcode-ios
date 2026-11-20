import SwiftUI
import UIKit

/// 对话主界面。三类内容共用一条时间线：user 气泡、assistant 气泡、tool_call 卡片。
///
/// 最低版本：`ContenthUnavailableView` 与两参数 `onChange` 需要 iOS 17.0
/// （与 project.yml 的 deploymentTarget 一致）。
public struct ChatView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var draft: String = ""
    @State private var expandedToolIDs: Set<String> = []
    @State private var showingSessions = false

    public init() {}

    private var chat: ChatModel { environment.chat }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                Divider()
                content
                Divider()
                composer
            }
            .navigationTitle("ZCode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ModelPickerMenu(chat: chat, options: chat.availableOptions)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSessions = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("历史会话")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("新会话") {
                            Task { await chat.newSession() }
                        }
                        Button("清空当前会话", role: .destructive) {
                            Task { await chat.resetSession() }
                        }
                        Button("设置") { environment.selectedTab = .settings }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingSessions) {
                SessionsView()
            }
        }
    }

    // MARK: - 顶部信息条

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: environment.workspace.snapshot.isActive ? "folder.fill" : "folder.badge.questionmark")
                .foregroundStyle(environment.workspace.snapshot.isActive ? Color.accentColor : .orange)
            Text(environment.workspace.snapshot.isActive
                 ? environment.workspace.snapshot.shortPath
                 : "未选择工作区")
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if chat.totalTokens > 0 {
                Text(Self.formatTokens(chat.totalTokens))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                    .accessibilityLabel("本会话已用 \(chat.totalTokens) tokens")
            }
            if chat.isPlanMode {
                Text("计划")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            }
            if let option = chat.currentOption {
                Text(option.modelID)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// 12_345 → "12.3k"。超过一万才缩写，少于一千保持原样，避免小数字变形。
    static func formatTokens(_ value: Int) -> String {
        if value < 1_000 { return "\(value) tok" }
        if value < 10_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return String(format: "%.0fk", Double(value) / 1_000)
    }

    // MARK: - 消息列表

    private var content: some View {
        Group {
            if chat.messages.isEmpty && chat.streamingText.isEmpty && !chat.isRunning {
                emptyState
            } else {
                messageList
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "terminal")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text("ZCode")
                    .font(.title2.bold())
                Text("在你的 iPhone 上，让 Agent 直接读写工作区里的文件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 14) {
                    stepRow(
                        index: 1,
                        title: "选择工作区",
                        detail: environment.workspace.snapshot.isActive
                            ? environment.workspace.snapshot.displayName
                            : "授权一个文件夹，Agent 只能在这个文件夹内操作。",
                        done: environment.workspace.snapshot.isActive,
                        actionTitle: "去选择"
                    ) {
                        environment.selectedTab = .settings
                        environment.wantsWorkspacePicker = true
                    }

                    stepRow(
                        index: 2,
                        title: "配置模型",
                        detail: chat.availableOptions.isEmpty
                            ? "填入你自己的 API Key、Base URL 与 Model ID。"
                            : "已配置 \(chat.availableOptions.count) 个可用模型。",
                        done: !chat.availableOptions.isEmpty,
                        actionTitle: "去配置"
                    ) {
                        environment.selectedTab = .settings
                    }

                    stepRow(
                        index: 3,
                        title: "开始对话",
                        detail: "例如：「看看这个文件夹里有什么，帮我整理一份 README」。",
                        done: false,
                        actionTitle: nil,
                        action: nil
                    )
                }
                .padding(16)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                Text("提示：iOS 不允许应用永久保存文件夹授权。重启 App 后如果提示「需要重新授权」，重新选一次同一个文件夹即可。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    private func stepRow(
        index: Int,
        title: String,
        detail: String,
        done: Bool,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.green)
                } else {
                    Text("\(index)").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action, !done {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.messages) { message in
                        row(for: message)
                            .id(message.id)
                            .contextMenu { contextMenu(for: message) }
                    }

                    if !chat.streamingText.isEmpty {
                        AssistantBubble(text: chat.streamingText, isStreaming: true)
                            .id("streaming")
                    }

                    if chat.isRunning && chat.streamingText.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在思考…").font(.caption).foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }

                    if let outcome = chat.outcome {
                        OutcomeBanner(outcome: outcome)
                            .id("outcome-\(String(describing: outcome))")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(lastAnchor, anchor: .bottom)
                }
            }
            .onChange(of: chat.streamingText) { _, _ in
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: chat.isRunning) { _, running in
                if running { proxy.scrollTo("thinking", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for message: ChatMessage) -> some View {
        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("复制内容", systemImage: "doc.on.doc")
        }
        .disabled(message.content.isEmpty)

        if message.role == .assistant {
            Button {
                chat.regenerate(workspaceName: environment.workspace.snapshot.displayName)
            } label: {
                Label("重新生成", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(chat.isRunning)
        }
    }

    private var lastAnchor: AnyHashable {
        if let last = chat.messages.last { return AnyHashable(last.id) }
        return AnyHashable("thinking")
    }

    @ViewBuilder
    private func row(for message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            UserBubble(text: message.content)

        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if !message.content.isEmpty {
                    AssistantBubble(text: message.content, isStreaming: false)
                }
                ForEach(chat.runs(for: message)) { run in
                    ToolRunCard(
                        run: run,
                        isExpanded: expandedToolIDs.contains(run.id),
                        onToggle: {
                            if expandedToolIDs.contains(run.id) {
                                expandedToolIDs.remove(run.id)
                            } else {
                                expandedToolIDs.insert(run.id)
                            }
                        }
                    )
                }
            }

        case .tool:
            // 工具结果已经渲染在对应卡片里；这里只兜底显示"孤儿结果"（不应出现）。
            EmptyView()

        case .system:
            EmptyView()
        }
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: 8) {
            if let errorText = chat.errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(errorText).font(.caption).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Button {
                        chat.clearError()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { chat.isPlanMode },
                    set: { chat.isPlanMode = $0 }
                )) {
                    Label("计划模式（只读）", systemImage: "doc.text.magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(chat.isRunning)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("让 Agent 做点什么…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    .disabled(chat.isRunning)

                if chat.isRunning {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("停止")
                } else {
                    Button {
                        sendDraft()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("发送")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }

    private var canSend: Bool {
        // 工作区没就绪时不放行：否则模型会先请求工具、再由工具层返回
        // 「还没有选择工作区」，白白烧掉一轮上下文。
        environment.workspace.isReady
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chat.canSend
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        chat.send(text, workspaceName: environment.workspace.snapshot.displayName)
    }
}

// MARK: - 气泡

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
    }
}

struct AssistantBubble: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            MarkdownText(text: text, isStreaming: isStreaming)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

struct OutcomeBanner: View {
    let outcome: TurnOutcome

    private var tint: Color {
        switch outcome {
        case .success: return .green
        case .cancelled: return .orange
        case .maxTurns: return .blue
        case .failed: return .red
        }
    }

    private var icon: String {
        switch outcome {
        case .success: return "checkmark.circle"
        case .cancelled: return "stop.circle"
        case .maxTurns: return "clock.arrow.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(outcome.displayText).font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.vertical, 2)
    }
}

// MARK: - 工具执行卡片

struct ToolRunCard: View {
    let run: ToolRun
    let isExpanded: Bool
    let onToggle: () -> Void

    private var statusColor: Color {
        switch run.state {
        case .running: return .blue
        case .success: return .green
        case .failure: return .red
        case .cancelled: return .orange
        case .unknown: return .secondary
        }
    }

    private var statusIcon: String {
        switch run.state {
        case .running: return "hourglass"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusText: String {
        switch run.state {
        case .running: return "执行中"
        case .success: return "成功"
        case .failure: return "失败"
        case .cancelled: return "已取消"
        case .unknown: return "无记录"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    if run.state == .running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: statusIcon).foregroundStyle(statusColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(run.argumentsSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? 6 : 1)
                    }
                    Spacer(minLength: 4)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("参数")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(run.argumentsJSON)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)

                    if !run.resultText.isEmpty {
                        Text("结果")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(run.resultText)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(run.state == .failure ? Color.red : .primary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 3)
        }
    }
}

// MARK: - 模型选择器

struct ModelPickerMenu: View {
    let chat: ChatModel
    let options: [ModelOption]

    var body: some View {
        Menu {
            if options.isEmpty {
                Text("尚未配置可用模型")
            } else {
                ForEach(options) { option in
                    Button {
                        chat.selection = option.id
                    } label: {
                        if chat.resolvedSelection == option.id {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(chat.currentOption?.modelID ?? "选择模型")
                    .lineLimit(1)
            }
            .font(.caption)
        }
    }
}