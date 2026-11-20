import Foundation

/// 模型发现：向服务端 `/models` 拉一份可用模型列表。
///
/// 为什么要这个：手打 Model ID 是自定义模型配置里最容易出错的一步——
/// 拼错一个字母，请求就会以 404 model_not_found 收场，而用户根本看不出区别。
/// 所以设置页提供「填完地址和 Key 自动拉列表」，把这一步变成点按选择。
///
/// 两个协议的差异都在这一层吃掉：
/// - OpenAI 兼容：`GET {base}/models`，头 `Authorization: Bearer <key>`；
/// - Anthropic：同样是 `GET {base}/models`，但头是 `x-api-key` + `anthropic-version`。
///
/// 最低版本：URLSession 的 `data(for:)` 是 iOS 15+；本工程基线 iOS 17.0。
public enum ModelCatalogService {

    /// 请求超时。拉列表比对话请求短命得多，用户站在设置页等不了 2 分钟。
    static let timeout: TimeInterval = 30

    /// 拉取模型列表。
    ///
    /// - Parameters:
    ///   - api: 协议类型，决定鉴权头。
    ///   - baseURL: 用户填的接入地址（可带可不带 `/v1`，本方法会补全）。
    ///   - apiKey: 可为空——本地推理服务通常不校验。
    public static func fetchModels(
        api: ProviderAPI,
        baseURL: String,
        apiKey: String
    ) async throws -> [String] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMError.badRequest(provider: "", detail: "请先填写 Base URL。")
        }

        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            throw LLMError.badRequest(provider: "", detail: "Base URL 不是合法的 http(s) 地址。")
        }

        // 允许用户填 `https://api.openai.com`（无 /v1）或 `https://api.openai.com/v1`。
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty {
            path = "/v1"
        } else if !path.hasSuffix("/v1") && !path.hasSuffix("/v1beta") {
            // 只填了域名、或者填了个不带版本号的路径时，按主流约定补 /v1。
            path += "/v1"
        }
        components.path = path + "/models"
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw LLMError.badRequest(provider: "", detail: "无法拼出模型列表地址。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch api {
        case .openAICompatible:
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            if !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        let session = URLSession(configuration: configuration)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw LLMError.cancelled
        } catch let error as URLError {
            throw LLMError.unreachable(provider: host, detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedStream(provider: host, detail: "服务端没有返回 HTTP 响应。")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data.prefix(4096), encoding: .utf8) ?? ""
            throw mapStatus(http.statusCode, host: host, body: body, keyProvided: !key.isEmpty)
        }

        let models = decodeModelIDs(from: data)
        guard !models.isEmpty else {
            throw LLMError.malformedStream(
                provider: host,
                detail: "响应里没有找到模型 ID。期望形如 {\"data\":[{\"id\":\"gpt-4o-mini\"}]}。"
            )
        }
        return models
    }

    /// 把 `/models` 的响应解析成模型 ID 列表。
    ///
    /// 兼容三种常见形状：
    /// - OpenAI 兼容 / Anthropic：`{"data": [{"id": "..."}]}`
    /// - Ollama 原生：`{"models": [{"name": "llama3:8b"}]}`
    /// - 简化网关：`{"models": ["gpt-4o"]}` 或直接是数组
    public static func decodeModelIDs(from data: Data) -> [String] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return []
        }

        var ids: [String] = []

        if let array = value.arrayValue {
            ids = array.compactMap { $0.stringValue ?? $0["id"]?.stringValue }
        } else if let data = value["data"]?.arrayValue {
            ids = data.compactMap { $0["id"]?.stringValue ?? $0.stringValue }
        } else if let models = value["models"]?.arrayValue {
            ids = models.compactMap { $0["id"]?.stringValue ?? $0["name"]?.stringValue ?? $0.stringValue }
        }

        // 去空、去重、保持服务端顺序（很多服务把最新的排在前面）。
        var seen = Set<String>()
        return ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 模型列表接口的错误映射。
    ///
    /// 与对话请求的错误映射分开，因为同一个状态码在这里含义不同：
    /// 对话里的 404 是「模型不存在」，而拉列表时的 404 通常意味着
    /// Base URL 少了或多了 `/v1`，直接告诉用户改地址比让他猜有用得多。
    static func mapStatus(_ status: Int, host: String, body: String, keyProvided: Bool) -> LLMError {
        let snippet = Self.snippet(body)
        switch status {
        case 401, 403:
            if !keyProvided {
                return .invalidAPIKey(provider: host, detail: "这个地址要求鉴权，请先填写 API Key。")
            }
            return .invalidAPIKey(provider: host, detail: snippet)
        case 404:
            return .badRequest(provider: host, detail: "地址可能不对：模型列表在 Base URL 后加 /models，请确认是否该填 .../v1。服务端说：\(snippet)")
        case 429:
            return .rateLimited(provider: host, retryAfter: nil)
        case 400...499:
            return .badRequest(provider: host, detail: snippet)
        case 500...599:
            return .serverError(provider: host, status: status, detail: snippet)
        default:
            return .serverError(provider: host, status: status, detail: "HTTP \(status) \(snippet)")
        }
    }

    static func snippet(_ body: String) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return "（空响应）" }
        return String(collapsed.prefix(300))
    }
}