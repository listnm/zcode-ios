import Foundation
import Observation

/// Provider 配置仓库：配置进 UserDefaults，Key 进 Keychain（C2）。
///
/// 为什么不自动拉取模型列表：那会消耗用户的 Key、产生额外计费与隐私问题，
/// 且在代理网关下经常失败。一期让用户自己填 Model ID（可填多个）。
@MainActor
@Observable
public final class ProviderStore {

    private static let storageKey = "zcode.providers.v1"

    public private(set) var providers: [ModelProvider] = []
    /// provider id → 是否已存 Key。只存布尔，Key 本身只在 Keychain。
    public private(set) var keyStatus: [UUID: Bool] = [:]
    public private(set) var lastError: String?

    private let defaults: UserDefaults
    private let keyStore: APIKeyStore

    public init(defaults: UserDefaults = .standard, keyStore: APIKeyStore = APIKeyStore()) {
        self.defaults = defaults
        self.keyStore = keyStore
        load()
    }

    // MARK: - 持久化

    /// 上次读取配置是否失败。失败后禁止再写回，避免用空列表覆盖掉还能人工恢复的文件。
    private var loadFailed = false

    public func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            providers = []
            keyStatus = [:]
            return
        }
        do {
            providers = try JSONDecoder().decode([ModelProvider].self, from: data)
            loadFailed = false
        } catch {
            // 不能静默降级成"没有配置"：用户会以为是空列表，然后下一次保存
            // 就把原本还能恢复的文件覆盖掉。
            providers = []
            loadFailed = true
            lastError = "模型服务配置读取失败：\(error.localizedDescription)。为避免覆盖原始数据，本次不会写回配置；请重新添加模型服务。"
        }
        refreshKeyStatus()
    }

    private func persist() {
        guard !loadFailed else { return }
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func refreshKeyStatus() {
        var status: [UUID: Bool] = [:]
        for provider in providers {
            status[provider.id] = keyStore.hasKey(providerID: provider.id)
        }
        keyStatus = status
    }

    // MARK: - 增删改

    @discardableResult
    public func upsert(_ provider: ModelProvider) -> Bool {
        guard provider.isValid else {
            lastError = "请至少填写显示名称、合法的 Base URL，以及一个 Model ID。"
            return false
        }
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        persist()
        refreshKeyStatus()
        lastError = nil
        return true
    }

    public func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[index].isEnabled = enabled
        persist()
    }

    public func remove(id: UUID) {
        providers.removeAll { $0.id == id }
        // 删除配置的同时清掉 Keychain 里的 Key，避免留下无主凭据。
        keyStore.delete(providerID: id)
        persist()
        refreshKeyStatus()
    }

    public func clearError() {
        lastError = nil
    }

    // MARK: - Key

    public func hasKey(for id: UUID) -> Bool {
        keyStatus[id] ?? false
    }

    @discardableResult
    public func setAPIKey(_ key: String, for id: UUID) -> Bool {
        do {
            try keyStore.save(key, providerID: id)
            refreshKeyStatus()
            lastError = nil
            return true
        } catch {
            lastError = (error as? APIKeyStore.KeychainError)?.errorDescription
                ?? error.localizedDescription
            return false
        }
    }

    public func apiKey(for id: UUID) -> String? {
        keyStore.load(providerID: id)
    }

    // MARK: - 查询

    public var enabledProviders: [ModelProvider] {
        providers.filter { $0.isEnabled && !$0.selectableModels.isEmpty }
    }

    public var modelOptions: [ModelOption] {
        enabledProviders.flatMap { provider in
            provider.selectableModels.map { model in
                ModelOption(
                    providerID: provider.id,
                    providerName: provider.displayName,
                    api: provider.api,
                    modelID: model
                )
            }
        }
    }

    public func provider(for ref: ModelRef) -> ModelProvider? {
        providers.first { $0.id == ref.providerID }
    }

    public func option(for ref: ModelRef?) -> ModelOption? {
        guard let ref else { return nil }
        return modelOptions.first { $0.id == ref }
    }

    /// 默认选择：第一个启用 provider 的默认模型。
    public var defaultSelection: ModelRef? {
        modelOptions.first?.id
    }

    // MARK: - 客户端

    /// 按协议构造客户端。这是"统一 provider 抽象"唯一的分叉点。
    public func makeClient(for provider: ModelProvider) -> any ModelClient {
        switch provider.api {
        case .openAICompatible:
            return OpenAICompatibleClient()
        case .anthropic:
            return AnthropicClient()
        }
    }
}