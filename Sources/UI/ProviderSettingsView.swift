import SwiftUI

/// Provider 列表 + 编辑。API Key 只以 SecureField 输入、只写 Keychain。
///
/// 最低版本：全部为 iOS 16+ SwiftUI API（`Form`/`Section`/`sheet`），本工程以 iOS 17.0 为基线。
public struct ProviderSettingsView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var editing: ModelProvider?
    @State private var isCreating = false

    private var store: ProviderStore { environment.providers }

    public init() {}

    public var body: some View {
        List {
            Section {
                if store.providers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有配置模型服务").font(.subheadline.weight(.semibold))
                        Text("填入自己的 API Key、Base URL 和 Model ID 后即可开始对话。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(store.providers) { provider in
                        Button {
                            editing = provider
                        } label: {
                            ProviderRow(provider: provider, hasKey: store.hasKey(for: provider.id))
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) {
                                store.remove(id: provider.id)
                            }
                        }
                    }
                }
            } header: {
                Text("模型服务")
            } footer: {
                Text("API Key 只保存在系统 Keychain（设备解锁后才可读），不会写入配置、日志或备份。")
            }

            if let error = store.lastError {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.caption)
                        Spacer()
                        Button("知道了") { store.clearError() }.font(.caption)
                    }
                }
            }

            Section {
                Button {
                    isCreating = true
                } label: {
                    Label("添加模型服务", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("模型管理")
        .sheet(item: $editing) { provider in
            ProviderEditorView(provider: provider, isNew: false)
        }
        .sheet(isPresented: $isCreating) {
            ProviderEditorView(
                provider: ModelProvider(
                    displayName: "",
                    api: .openAICompatible,
                    baseURL: ProviderAPI.openAICompatible.defaultBaseURL
                ),
                isNew: true
            )
        }
    }
}

private struct ProviderRow: View {
    let provider: ModelProvider
    let hasKey: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.api == .anthropic ? "a.circle.fill" : "o.circle.fill")
                .foregroundStyle(provider.isEnabled ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName.isEmpty ? "（未命名）" : provider.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(provider.normalizedBaseURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(provider.selectableModels.count) 个模型")
                    if hasKey {
                        Label("Key 已保存", systemImage: "lock.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("缺 Key", systemImage: "lock.open")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 编辑页

struct ProviderEditorView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ModelProvider
    @State private var modelsText: String
    @State private var apiKey: String = ""
    @State private var showDataNotice = false
    @State private var pendingSave = false
    @State private var validationError: String?

    let isNew: Bool

    init(provider: ModelProvider, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: provider)
        _modelsText = State(initialValue: provider.models.joined(separator: "\n"))
    }

    private var store: ProviderStore { environment.providers }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("显示名称，例如 DeepSeek", text: $draft.displayName)
                    Picker("协议", selection: $draft.api) {
                        ForEach(ProviderAPI.allCases) { api in
                            Text(api.displayName).tag(api)
                        }
                    }
                    Text(draft.api.hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("接入地址") {
                    TextField("Base URL", text: $draft.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("例如 \(draft.api.defaultBaseURL)。只填到 /v1，路径由 App 补全。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("模型") {
                    TextEditor(text: $modelsText)
                        .frame(minHeight: 88)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("每行一个 Model ID，例如 gpt-4o-mini / deepseek-chat / claude-sonnet-4-5。第一行会作为默认模型。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("凭据") {
                    SecureField(store.hasKey(for: draft.id) ? "已保存，留空表示不修改" : "API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if store.hasKey(for: draft.id) {
                        Button("删除已保存的 Key", role: .destructive) {
                            store.setAPIKey("", for: draft.id)
                        }
                    }
                    Text("Key 只写入 Keychain，不进入 UserDefaults、不落盘明文、不打印日志。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("启用", isOn: $draft.isEnabled)
                }

                if let error = store.lastError {
                    Section {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                if let validationError {
                    Section {
                        Text(validationError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "添加模型服务" : "编辑模型服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear {
                if apiKey.isEmpty, !isNew {
                    // 回填 Key 会让它出现在内存里的 SwiftUI State 中；
                    // 这里刻意不回填，避免误以为"能看见的就是安全的"。
                    apiKey = ""
                }
            }
            .alert("API Key 会发往哪里？", isPresented: $showDataNotice) {
                Button("继续保存") { performSave() }
                Button("取消", role: .cancel) { pendingSave = false }
            } message: {
                Text("你的 API Key 与对话内容会直接发送到「\(draft.displayName.isEmpty ? draft.normalizedBaseURL : draft.displayName)」的服务器（\(draft.normalizedBaseURL)）。ZCode 不经过任何中转服务器，也不会上传你的文件内容到除该模型服务以外的地方。请确认你信任这个服务提供方。")
            }
        }
    }

    private func save() {
        // 解析模型列表：每行一个，去空行。
        let models = modelsText
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        draft.models = models
        if draft.defaultModel.isEmpty || !models.contains(draft.defaultModel) {
            draft.defaultModel = models.first ?? ""
        }

        guard draft.isValid else {
            // 校验失败时**绝不**触碰 Keychain：否则填错 Base URL 会顺手把已保存的 Key 删掉。
            validationError = "请检查：显示名称非空、Base URL 含 http(s)://、至少一个 Model ID。"
            return
        }

        if isNew && !pendingSave {
            // 首次保存先讲清楚数据去向，同意之后才落盘（含 Key）。
            pendingSave = true
            showDataNotice = true
            return
        }
        performSave()
    }

    private func performSave() {
        pendingSave = false
        guard store.upsert(draft) else {
            validationError = store.lastError ?? "保存失败，请重试。"
            return
        }
        // Key 只在配置成功落盘之后才写：保存失败不会在 Keychain 里留下
        // 一条永远不会被任何 provider 引用的孤立条目。
        if !apiKey.isEmpty {
            guard store.setAPIKey(apiKey, for: draft.id) else {
                validationError = "配置已保存，但 API Key 写入钥匙串失败。请重试；若反复失败，检查设备是否设置了锁屏密码。"
                return
            }
            apiKey = ""
        }
        dismiss()
    }
}