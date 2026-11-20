import Foundation
import Observation

/// 一个插件：声明式的「提示词扩展 + 工具白名单」。
///
/// 为什么不支持可执行代码：iOS 不允许加载动态库，也不允许下载后执行脚本
/// （App Store 规则 2.5.2）。所以这里的插件与 ZCode 桌面版不是同一类东西，
/// 必须说清楚——
/// - **能做的**：往系统提示词里加一段规则（例如"提交信息必须用 Conventional Commits"）、
///   把可用工具收窄到某个子集（例如"只允许读，不允许写"）。
/// - **不能做的**：新增工具、访问网络、执行任意代码。
///
/// 这样定义的好处是插件完全可审计：用户打开 JSON 就能看到它到底会改什么。
public struct PluginDefinition: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var version: String
    /// 启用后追加到系统提示词末尾的规则。
    public var systemPromptAddon: String
    /// 非空时，只把名字在这个列表里的工具交给模型。空数组表示不限制。
    public var allowedToolNames: [String]
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        version: String = "1.0",
        systemPromptAddon: String = "",
        allowedToolNames: [String] = [],
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.version = version
        self.systemPromptAddon = systemPromptAddon
        self.allowedToolNames = allowedToolNames
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var promptTitle: String { "## 插件：\(name)" }
}

@MainActor
@Observable
public final class PluginStore {

    public private(set) var plugins: [PluginDefinition] = []
    public private(set) var lastError: String?

    private let fileURL: URL
    private var loadFailed = false

    public init(directory: URL? = nil) {
        let fileManager = FileManager()
        let base: URL
        if let directory {
            base = directory
        } else {
            let support = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
            base = support.appendingPathComponent("ZCodePlugins", isDirectory: true)
        }
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("plugins.json")
        load()
    }

    public var enabledPlugins: [PluginDefinition] {
        plugins.filter { $0.isEnabled && $0.isValid }
    }

    // MARK: - 读写

    public func load() {
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            plugins = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([PluginDefinition].self, from: data)
            plugins = decoded.sorted { $0.updatedAt > $1.updatedAt }
            loadFailed = false
        } catch {
            plugins = []
            loadFailed = true
            lastError = "插件配置读取失败：\(error.localizedDescription)。为避免覆盖原数据，本次不会写回。"
        }
    }

    private func persist() {
        guard !loadFailed else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(plugins)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "插件保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 增改删

    @discardableResult
    public func upsert(_ plugin: PluginDefinition) -> Bool {
        guard plugin.isValid else {
            lastError = "插件需要名称。"
            return false
        }
        var copy = plugin
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.allowedToolNames = copy.allowedToolNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        copy.updatedAt = Date()
        if let index = plugins.firstIndex(where: { $0.id == copy.id }) {
            copy.createdAt = plugins[index].createdAt
            plugins[index] = copy
        } else {
            plugins.insert(copy, at: 0)
        }
        persist()
        return lastError == nil
    }

    public func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[index].isEnabled = enabled
        plugins[index].updatedAt = Date()
        persist()
    }

    public func remove(id: UUID) {
        plugins.removeAll { $0.id == id }
        persist()
    }

    public func clearError() { lastError = nil }

    /// 由 UI 侧（编辑器 / 导入）写入一条可读错误，复用同一条展示条。
    public func reportError(_ message: String) { lastError = message }

    // MARK: - 作用于 Agent

    /// 追加到系统提示词的片段。多个插件按名字排序拼接，保证同样的配置得到同样的提示词（可复现）。
    public var promptFragment: String {
        let active = enabledPlugins.sorted { $0.name < $1.name }
        guard !active.isEmpty else { return "" }
        return active
            .filter { !$0.systemPromptAddon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.promptTitle)\n\($0.systemPromptAddon.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
    }

    /// 工具白名单的合并结果。
    ///
    /// 规则：只要有一个启用插件声明了白名单，就取这些白名单的**并集**作为允许集合
    /// （两个插件各要一个工具，结果应该两个都能用）。全都没声明时返回 nil，表示不限制。
    public var allowedToolNames: Set<String>? {
        let lists = enabledPlugins
            .map { Set($0.allowedToolNames) }
            .filter { !$0.isEmpty }
        guard !lists.isEmpty else { return nil }
        return lists.reduce(into: Set<String>()) { partial, next in
            partial.formUnion(next)
        }
    }

    // MARK: - 导入

    /// 从 JSON 文本导入插件。
    ///
    /// 接受单个对象或数组；`id` / 时间戳缺省时会自动补。返回成功导入的条数。
    @discardableResult
    public func importJSON(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            lastError = "导入失败：文本无法编码为 UTF-8。"
            return 0
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var incoming: [PluginDefinition] = []
        if let array = try? decoder.decode([PluginDefinition].self, from: data) {
            incoming = array
        } else if let single = try? decoder.decode(PluginDefinition.self, from: data) {
            incoming = [single]
        } else {
            lastError = "导入失败：不是合法的插件 JSON。需要字段至少包含 name。"
            return 0
        }

        var imported = 0
        for var plugin in incoming {
            plugin.id = UUID()
            plugin.createdAt = Date()
            plugin.updatedAt = Date()
            if upsert(plugin) { imported += 1 }
        }
        return imported
    }

    /// 一个可以直接粘贴的模板，降低手写 JSON 的门槛。
    public static let template = """
    {
      "name": "只读巡检",
      "summary": "禁止一切写操作，只让 Agent 读代码并给出建议",
      "version": "1.0",
      "systemPromptAddon": "你处于只读巡检模式：只允许分析和给出建议，绝不修改文件。发现需要改动时，把改动写成建议而不是直接写文件。",
      "allowedToolNames": ["list_files", "glob", "grep", "read_file"],
      "isEnabled": true
    }
    """
}