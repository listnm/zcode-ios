import Foundation

/// 会话持久化：把消息历史写成 Application Support 里的 JSON，并维护一个索引文件。
///
/// 为什么是 JSON 文件而不是 SwiftData：
/// - 体积小（每个会话最近 200 条消息，几十 KB），不需要查询能力；
/// - tool_call 与 tool_result 的**顺序与配对**是语义核心，扁平数组最不容易被 ORM 打散；
/// - 出问题时用户能自己看到文件，便于排查。
///
/// 最低版本：FileManager / ApplicationSupport 目录自 iOS 2.0 起可用。
public actor SessionStore {

    public struct Payload: Codable, Sendable {
        public var messages: [ChatMessage]
        public var updatedAt: Date
    }

    /// 会话列表项。索引与正文分开存：列列表时不必把每个会话的全文都读进内存。
    public struct SessionSummary: Identifiable, Codable, Sendable, Equatable {
        public var id: UUID
        public var title: String
        public var updatedAt: Date
        public var messageCount: Int

        public init(id: UUID, title: String, updatedAt: Date, messageCount: Int) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
            self.messageCount = messageCount
        }
    }

    /// 保留的消息条数上限。裁剪遵守配对规则（见 `trim`）。
    public static let maxMessages = 200

    private let directory: URL
    private static let indexFileName = "index.json"

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("ZCodeSessions", isDirectory: true)
        }
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).json", isDirectory: false)
    }

    private var indexURL: URL {
        directory.appendingPathComponent(Self.indexFileName, isDirectory: false)
    }

    // MARK: - 索引

    private func readIndex() -> [SessionSummary] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SessionSummary].self, from: data)) ?? []
    }

    private func writeIndex(_ summaries: [SessionSummary]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(summaries).write(to: indexURL, options: .atomic)
        } catch {
            print("[SessionStore] 索引写入失败：\(error.localizedDescription)")
        }
    }

    /// 会话列表，最近更新的在前。
    /// 索引缺失或损坏时，从目录里的会话文件重建一次，避免"历史还在却看不到"。
    public func list() -> [SessionSummary] {
        var summaries = readIndex()
        if summaries.isEmpty {
            summaries = rebuildIndex()
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func rebuildIndex() -> [SessionSummary] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var summaries: [SessionSummary] = []
        for file in files where file.pathExtension == "json" && file.lastPathComponent != Self.indexFileName {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            guard let data = try? Data(contentsOf: file) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let payload = try? decoder.decode(Payload.self, from: data) else { continue }
            summaries.append(
                SessionSummary(
                    id: id,
                    title: Self.deriveTitle(from: payload.messages),
                    updatedAt: payload.updatedAt,
                    messageCount: payload.messages.count
                )
            )
        }
        if !summaries.isEmpty {
            writeIndex(summaries)
        }
        return summaries
    }

    // MARK: - 读写

    public func save(messages: [ChatMessage], sessionID: UUID) {
        guard !messages.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let trimmed = Self.trim(messages)
            let payload = Payload(messages: trimmed, updatedAt: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: fileURL(for: sessionID), options: .atomic)

            var summaries = readIndex()
            summaries.removeAll { $0.id == sessionID }
            summaries.append(
                SessionSummary(
                    id: sessionID,
                    title: Self.deriveTitle(from: trimmed),
                    updatedAt: payload.updatedAt,
                    messageCount: trimmed.count
                )
            )
            writeIndex(summaries)
        } catch {
            // 持久化失败不应打断对话：内存里的历史仍然可用。
            print("[SessionStore] 保存失败：\(error.localizedDescription)")
        }
    }

    public func load(sessionID: UUID) -> [ChatMessage] {
        do {
            let data = try Data(contentsOf: fileURL(for: sessionID))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Payload.self, from: data).messages
        } catch {
            return []
        }
    }

    public func clear(sessionID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionID))
        var summaries = readIndex()
        summaries.removeAll { $0.id == sessionID }
        writeIndex(summaries)
    }

    public func rename(sessionID: UUID, title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        var summaries = readIndex()
        guard let index = summaries.firstIndex(where: { $0.id == sessionID }) else { return }
        summaries[index].title = String(cleaned.prefix(60))
        writeIndex(summaries)
    }

    /// 会话标题取第一条用户消息的第一行，截断到 24 个字。没有用户消息时用时间兜底。
    static func deriveTitle(from messages: [ChatMessage]) -> String {
        if let first = messages.first(where: { $0.role == .user })?.content {
            let line = first.split(separator: "\n").first.map(String.init) ?? first
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                return String(clean.prefix(24))
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "会话 " + formatter.string(from: Date())
    }

    /// 裁剪掉最老的消息，但**绝不切出半截工具批次**。
    ///
    /// 一条 assistant 消息里的 `toolCalls` 与随后的 `.tool` 消息必须成对保留，
    /// 否则恢复出来的历史一发给模型就是 400（不变量 I1）。
    static func trim(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard messages.count > maxMessages else { return messages }

        // 先切成不可分割的单元：带 toolCalls 的 assistant 与紧随其后的 .tool 结果是一组，
        // 任何裁剪都不能落在组内部，否则恢复出来的历史一发给模型就是 400（不变量 I1）。
        var groupStarts: [Int] = []
        var index = 0
        while index < messages.count {
            groupStarts.append(index)
            if messages[index].role == .assistant && !messages[index].toolCalls.isEmpty {
                var next = index + 1
                while next < messages.count, messages[next].role == .tool {
                    next += 1
                }
                index = next
            } else {
                index += 1
            }
        }
        guard !groupStarts.isEmpty else { return messages }

        // 从最新一组往回累加，直到再加一组就超过上限；即使单组本身超限也会保留那一组，
        // 因为"丢掉一组但留下半组"比重启后历史短一点严重得多。
        var kept = 0
        var cut = groupStarts[groupStarts.count - 1]
        var cursor = groupStarts.count - 1
        while cursor >= 0 {
            let start = groupStarts[cursor]
            let end = cursor + 1 < groupStarts.count ? groupStarts[cursor + 1] : messages.count
            let size = end - start
            if kept > 0 && kept + size > maxMessages { break }
            kept += size
            cut = start
            cursor -= 1
        }
        return Array(messages[cut...])
    }
}