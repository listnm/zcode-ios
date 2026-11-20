import Foundation
import Observation

/// 一条技能：可复用的提示词指令片段。
///
/// 语义对齐 ZCode 的 skills：技能不是工具，不执行代码，只在系统提示词里注入一段
/// 「怎么做这件事」的说明。因此它天然安全——最坏情况是一段没用的话占上下文。
public struct SkillDefinition: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// 一句话说明，用于列表和给模型看「有哪些技能可用」。
    public var summary: String
    /// 技能正文：真正的行为约束。
    public var instructions: String
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        instructions: String = "",
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 注入系统提示词时的标题行：`### 技能：提交信息规范`。
    public var promptTitle: String { "### 技能：\(name)" }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 技能的存储与解析。
///
/// 落盘在 `Application Support/ZCodeSkills/skills.json`：技能只是文本，不需要 Keychain，
/// 也不需要 SwiftData——一个 JSON 足够，出问题时用户可以自己打开看。
@MainActor
@Observable
public final class SkillStore {

    public private(set) var skills: [SkillDefinition] = []
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
            base = support.appendingPathComponent("ZCodeSkills", isDirectory: true)
        }
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("skills.json")
        load()
    }

    public var enabledSkills: [SkillDefinition] {
        skills.filter { $0.isEnabled && $0.isValid }
    }

    // MARK: - 读写

    public func load() {
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            skills = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([SkillDefinition].self, from: data)
            skills = decoded.sorted { $0.updatedAt > $1.updatedAt }
            loadFailed = false
        } catch {
            // 读失败时不要清空文件：宁可本次没有技能，也不能覆盖用户数据。
            skills = []
            loadFailed = true
            lastError = "技能配置读取失败：\(error.localizedDescription)。为避免覆盖原数据，本次不会写回。"
        }
    }

    private func persist() {
        guard !loadFailed else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(skills)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "技能保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 增改删

    @discardableResult
    public func upsert(_ skill: SkillDefinition) -> Bool {
        guard skill.isValid else {
            lastError = "技能需要名称和正文，正文不能为空。"
            return false
        }
        var copy = skill
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.updatedAt = Date()
        if let index = skills.firstIndex(where: { $0.id == copy.id }) {
            copy.createdAt = skills[index].createdAt
            skills[index] = copy
        } else {
            skills.insert(copy, at: 0)
        }
        persist()
        return lastError == nil
    }

    public func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[index].isEnabled = enabled
        skills[index].updatedAt = Date()
        persist()
    }

    public func remove(id: UUID) {
        skills.removeAll { $0.id == id }
        persist()
    }

    public func clearError() { lastError = nil }

    /// 由 UI 侧（文件导入等）写入一条可读错误，复用同一条展示条。
    public func reportError(_ message: String) { lastError = message }

    // MARK: - 拼进提示词

    /// 所有启用技能拼接成一段。没有启用技能时返回空串，调用方不要拼空标题。
    public var promptFragment: String {
        let active = enabledSkills
        guard !active.isEmpty else { return "" }
        return active
            .map { "\($0.promptTitle)\n\($0.instructions.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
    }

    // MARK: - 解析（导入用）

    /// 从 Markdown 文本解析一条技能。
    ///
    /// 支持最简 front matter：
    /// ```
    /// ---
    /// name: 提交信息规范
    /// description: 生成符合 Conventional Commits 的提交信息
    /// ---
    /// 正文……
    /// ```
    /// 没有 front matter 时，用第一个 `# 标题` 当名字、第一段非空行当摘要。
    public static func parse(markdown text: String) -> SkillDefinition? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")

        var name = ""
        var summary = ""

        if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[firstIndex].trimmingCharacters(in: .whitespaces) == "---" {
            // 找到闭合的 ---
            if let closing = lines[(firstIndex + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "---"
            }) {
                for line in lines[(firstIndex + 1)..<closing] {
                    let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2 else { continue }
                    let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = pair[1].trimmingCharacters(in: .whitespaces)
                    if key == "name" || key == "title" { name = value }
                    if key == "description" || key == "summary" { summary = value }
                }
                lines = Array(lines[(closing + 1)...])
            }
        }

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        if name.isEmpty {
            if let heading = lines.first(where: { $0.hasPrefix("# ") }) {
                name = String(heading.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if let firstContent = lines.first(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#")
            }) {
                name = String(firstContent.trimmingCharacters(in: .whitespaces).prefix(24))
            }
        }
        if summary.isEmpty {
            summary = String(body.components(separatedBy: "\n").first { !$0.isEmpty }.map {
                $0.trimmingCharacters(in: .whitespaces)
            }?.prefix(80) ?? "")
        }
        guard !name.isEmpty else { return nil }

        return SkillDefinition(name: name, summary: summary, instructions: body)
    }
}