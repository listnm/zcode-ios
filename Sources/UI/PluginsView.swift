import SwiftUI

/// 插件管理页。
///
/// 这里必须对用户诚实：iOS 上的「插件」不是插件进程，而是**声明式配置**——
/// 一段追加的系统提示词，加一个工具白名单。没有动态库、没有下载执行、没有隐藏行为，
/// 用户打开 JSON 就能看见它到底改了什么。
public struct PluginsView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var editing: PluginDefinition?
    @State private var isCreating = false
    @State private var showJSONImporter = false
    @State private var pendingDelete: PluginDefinition?

    public init() {}

    public var body: some View {
        List {
            if let error = environment.plugins.lastError {
                Section {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                    Button("知道了") { environment.plugins.clearError() }
                        .font(.callout)
                }
            }

            Section {
                if environment.plugins.plugins.isEmpty {
                    ContentUnavailableView {
                        Label("还没有插件", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("插件可以追加一段工作规则，或者把可用工具收窄成只读。")
                    }
                } else {
                    ForEach(environment.plugins.plugins) { plugin in
                        row(for: plugin)
                    }
                    .onDelete { offsets in
                        guard let index = offsets.first else { return }
                        pendingDelete = environment.plugins.plugins[index]
                    }
                }
            } header: {
                Text("插件")
            } footer: {
                Text("能力边界：只能追加系统提示词、收窄工具白名单。不能新增工具、访问网络或执行代码——这是 iOS 平台的限制，也是这里唯一可能的实现方式。")
            }

            Section {
                Label("当前可用工具：\(toolNamesText)", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("插件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isCreating = true
                    } label: {
                        Label("新建插件", systemImage: "square.and.pencil")
                    }
                    Button {
                        showJSONImporter = true
                    } label: {
                        Label("从 JSON 导入", systemImage: "curlybraces")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            PluginEditorView(plugin: PluginDefinition(name: ""), isNew: true)
        }
        .sheet(item: $editing) { plugin in
            PluginEditorView(plugin: plugin, isNew: false)
        }
        .sheet(isPresented: $showJSONImporter) {
            PluginJSONImporter()
        }
        .alert("删除这个插件？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let plugin = pendingDelete {
                    environment.plugins.remove(id: plugin.id)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.name ?? "")
        }
    }

    private var toolNamesText: String {
        environment.tools.map { $0.capability.name }.joined(separator: "、")
    }

    private func row(for plugin: PluginDefinition) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                editing = plugin
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(plugin.name).font(.body).foregroundStyle(.primary)
                        Text(plugin.version)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                    if !plugin.summary.isEmpty {
                        Text(plugin.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(plugin.allowedToolNames.isEmpty
                         ? "工具：不限制"
                         : "工具：\(plugin.allowedToolNames.count) 个白名单")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { plugin.isEnabled },
                set: { environment.plugins.setEnabled($0, id: plugin.id) }
            ))
            .labelsHidden()
        }
    }
}

// MARK: - 编辑

struct PluginEditorView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PluginDefinition
    @State private var allowedToolsText: String
    @State private var validationError: String?

    let isNew: Bool

    init(plugin: PluginDefinition, isNew: Bool) {
        _draft = State(initialValue: plugin)
        _allowedToolsText = State(initialValue: plugin.allowedToolNames.joined(separator: "\n"))
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称，例如 只读巡检", text: $draft.name)
                    TextField("一句话说明（可留空）", text: $draft.summary)
                    TextField("版本，例如 1.0", text: $draft.version)
                }

                Section {
                    TextEditor(text: $draft.systemPromptAddon)
                        .frame(minHeight: 160)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("追加到系统提示词的规则")
                } footer: {
                    Text("启用后会被拼到系统提示词末尾。适合放「工作方式」约束，例如：改动前先读完整文件、不要动 .git 目录。")
                }

                Section {
                    TextEditor(text: $allowedToolsText)
                        .frame(minHeight: 120)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("工具白名单（每行一个）")
                } footer: {
                    Text("留空表示不限制。填写后模型只能看到列出的工具。可用工具：\(environment.tools.map { $0.capability.name }.joined(separator: "、"))")
                }

                Section {
                    Toggle("启用", isOn: $draft.isEnabled)
                }

                if let validationError {
                    Section {
                        Text(validationError).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "新建插件" : "编辑插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        guard draft.isValid else {
            validationError = "插件需要名称。"
            return
        }
        var candidate = draft
        candidate.allowedToolNames = allowedToolsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 白名单里写了不存在的工具时，不要静默丢弃：明确告诉用户，避免「以为收窄了其实没生效」。
        let known = Set(environment.tools.map { $0.capability.name })
        let unknown = candidate.allowedToolNames.filter { !known.contains($0) }
        if !unknown.isEmpty {
            validationError = "这些工具不存在：\(unknown.joined(separator: "、"))。可用工具见上方说明。"
            return
        }

        if environment.plugins.upsert(candidate) {
            dismiss()
        } else {
            validationError = environment.plugins.lastError ?? "保存失败，请重试。"
        }
    }
}

// MARK: - JSON 导入

struct PluginJSONImporter: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var text = PluginStore.template
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 240)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("插件 JSON")
                } footer: {
                    Text("接受单个对象或数组。字段：name（必填）、summary、version、systemPromptAddon、allowedToolNames、isEnabled。")
                }

                if let message {
                    Section {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("恢复为模板") { text = PluginStore.template }
                }
            }
            .navigationTitle("导入插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        let count = environment.plugins.importJSON(text)
                        if count > 0 {
                            dismiss()
                        } else {
                            message = environment.plugins.lastError ?? "没有导入任何插件。"
                        }
                    }
                }
            }
        }
    }
}