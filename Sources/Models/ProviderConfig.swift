import Foundation

/// 协议类型。一期只支持两种，其余走 OpenAI 兼容。
public enum ProviderAPI: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAICompatible
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        }
    }

    public var hint: String {
        switch self {
        case .openAICompatible:
            return "适用于 OpenAI、DeepSeek、Moonshot、通义、OpenRouter、硅基流动、Ollama 等 /chat/completions 接口。"
        case .anthropic:
            return "适用于 Anthropic 官方 API 及兼容 /v1/messages 的网关。"
        }
    }
}

/// 一个用户自定义的模型服务商。**不包含 API Key**（Key 只在 Keychain）。
public struct ModelProvider: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var api: ProviderAPI
    /// 不含尾斜杠的 Base URL，例如 `https://api.deepseek.com/v1`。
    public var baseURL: String
    /// 用户手动维护的模型 ID 列表（不自动拉取，避免多余的 Key 使用与网络请求）。
    public var models: [String]
    public var defaultModel: String
    public var isEnabled: Bool
    /// 采样温度。nil = 不发给服务端，用服务端默认值。
    ///
    /// 为什么不给一个"合理默认"：不同厂商的默认值差异很大（有的 1.0，有的 0.7，
    /// 推理模型甚至不接受这个参数）。留 nil 让服务端决定，才是真正可移植的做法。
    public var temperature: Double?
    /// 单次回复的最大输出 token 数。nil = 用协议默认值（Anthropic 必须给，见客户端）。
    public var maxOutputTokens: Int?

    public init(
        id: UUID = UUID(),
        displayName: String,
        api: ProviderAPI,
        baseURL: String,
        models: [String] = [],
        defaultModel: String = "",
        isEnabled: Bool = true,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.api = api
        self.baseURL = baseURL
        self.models = models
        self.defaultModel = defaultModel
        self.isEnabled = isEnabled
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
    }

    /// 规范化后的 Base URL：去空白、去尾斜杠。
    public var normalizedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    public var isValid: Bool {
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let url = URL(string: normalizedBaseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return false }
        return !models.isEmpty
    }

    /// 供选择器展示的模型列表：过滤空白与重复，默认模型排在最前。
    public var selectableModels: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in models {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            result.append(value)
        }
        if !defaultModel.isEmpty, let index = result.firstIndex(of: defaultModel), index != 0 {
            result.remove(at: index)
            result.insert(defaultModel, at: 0)
        }
        return result
    }
}

/// 选择器里的一行。
public struct ModelOption: Identifiable, Hashable, Sendable {
    public let providerID: UUID
    public let providerName: String
    public let api: ProviderAPI
    public let modelID: String

    public var id: ModelRef { ModelRef(providerID: providerID, modelID: modelID) }

    public var displayName: String { "\(providerName) · \(modelID)" }
}