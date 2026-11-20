import Foundation
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
    @State private var isFetchingModels = false
    @State private var fetchMessage: String?
    @State private var fetchFailed = false
    /// 自动拉取的防抖任务：用户还在打字时不要每敲一个字符就打一次网络请求。
    @State private var autoFetchTask: Task<Void, Never>?

    let isNew: Bool

    init(provider: ModelProvider, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: provider)
        _modelsText = State(initialValue: provider.models.joined(separator: "\n"))
    }

    private var store: ProviderStore { environment.providers }

    /// 温度用文本框而不是 Slider：Slider 无法表达"留空 = 用服务端默认"，
    /// 而"留空"恰恰是跨厂商最安全的默认行为。
    private var temperatureText: Binding<String> {
        Binding(
            get: {
                guard let value = draft.temperature else { return "" }
                return String(format: "%g", value)
            },
            set: { newValue in
                let trimmed = newValue
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "，", with: ".")
                    .replacingOccurrences(of: ",", with: ".")
                draft.temperature = trimmed.isEmpty ? nil : Double(trimmed)
            }
        )
    }

    private var maxTokensText: Binding<String> {
        Binding(
            get: { draft.maxOutputTokens.map(String.init) ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                draft.maxOutputTokens = trimmed.isEmpty ? nil : Int(trimmed)
            }
        )
    }

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
                        .onSubmit { fetchModels() }
                        .onChange(of: draft.baseURL) { _, _ in scheduleAutoFetch() }
                    Text("例如 \(draft.api.defaultBaseURL)。只填到 /v1，路径由 App 补全。填完地址和 Key 会自动尝试拉取模型列表。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("模型") {
                    Button {
                        fetchModels()
                    } label: {
                        HStack(spacing: 8) {
                            Label(isFetchingModels ? "正在获取模型列表…" : "从地址获取模型列表",
                                  systemImage: isFetchingModels ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                            Spacer()
                            if isFetchingModels {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isFetchingModels)

                    if let fetchMessage {
                        Text(fetchMessage)
                            .font(.caption2)
                            .foregroundStyle(fetchFailed ? Color.red : Color.secondary)
                    }

                    TextEditor(text: $modelsText)
                        .frame(minHeight: 88)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("点上面的按钮会自动请求 `Base URL + /models`；拉不到时也可以手打，每行一个 Model ID。第一行会作为默认模型。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("生成参数（可选）") {
                    HStack {
                        Text("温度")
                        Spacer()
                        TextField("默认", text: temperatureText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                    }
                    HStack {
                        Text("最大输出")
                        Spacer()
                        TextField("默认", text: maxTokensText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                        Text("tokens").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("留空表示不发送该参数，由服务端决定。温度范围 0–2；Anthropic 协议必须给 max_tokens，未填时用 4096。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("凭据") {
                    SecureField(store.hasKey(for: draft.id) ? "已保存，留空表示不修改" : "API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { maybeAutoFetch() }
                        .onChange(of: apiKey) { _, _ in scheduleAutoFetch() }
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

    /// 主动拉取模型列表。用「输入框里刚打的 Key」，没有就用已存到 Keychain 的那把。
    private func fetchModels() {
        guard !isFetchingModels else { return }
        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespaces)
        guard !baseURL.isEmpty else {
            fetchFailed = true
            fetchMessage = "请先填写 Base URL，例如 https://api.deepseek.com/v1。"
            return
        }

        let typedKey = apiKey.trimmingCharacters(in: .whitespaces)
        let storedKey = store.apiKey(for: draft.id) ?? ""
        let key = typedKey.isEmpty ? storedKey : typedKey

        fetchFailed = false
        fetchMessage = nil
        isFetchingModels = true

        Task {
            do {
                let models = try await ModelCatalogService.fetchModels(
                    api: draft.api,
                    baseURL: baseURL,
                    apiKey: key
                )
                isFetchingModels = false
                fetchFailed = false
                modelsText = models.joined(separator: "\n")
                draft.models = models
                if draft.defaultModel.isEmpty || !models.contains(draft.defaultModel) {
                    draft.defaultModel = models.first ?? ""
                }
                fetchMessage = key.isEmpty
                    ? "已获取 \(models.count) 个模型（该地址不要求 API Key）。"
                    : "已获取 \(models.count) 个模型，第一行已设为默认。"
            } catch {
                isFetchingModels = false
                fetchFailed = true
                fetchMessage = (error as? LocalizedError)?.errorDescription
                    ?? "获取模型列表失败：\(error.localizedDescription)"
            }
        }
    }

    /// 地址填完整、且手上已有一把 Key 时自动拉一次。
    ///
    /// 只在「模型列表还空着、上次也没失败」时触发：否则每次改地址都会打一次请求，
    /// 而拉失败通常意味着地址或 Key 不对，用户改字的过程中反复失败只是噪音。
    private func maybeAutoFetch() {
        guard modelsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isFetchingModels,
              !fetchFailed
        else { return }

        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: baseURL), url.host != nil else { return }

        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let hasKey = !key.isEmpty || store.hasKey(for: draft.id)
        guard hasKey else { return }

        fetchModels()
    }

    private func scheduleAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            maybeAutoFetch()
        }
    }

    private func save() {
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

        if let temperature = draft.temperature, !(0...2).contains(temperature) {
            validationError = "温度需要在 0 到 2 之间；留空表示使用服务端默认值。"
            return
        }
        if let maxTokens = draft.maxOutputTokens, maxTokens <= 0 {
            validationError = "最大输出 token 需要是正整数；留空表示使用默认值。"
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