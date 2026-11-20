import Foundation

/// 会话持久化：把消息历史写成 Application Support 里的 JSON。
///
/// 为什么是 JSON 文件而不是 SwiftData：
/// - 体积小（最近 200 条消息，几十 KB），不需要查询能力；
/// - tool_call 与 tool_result 的**顺序与配对**是语义核心，扁平数组最不容易被 ORM 打散；
/// - 出问题时用户能自己看到文件，便于排查。
///
/// 最低版本：FileManager/ApplicationSupport 目录自 iOS 2.0 起可用。
public actor SessionStore {

    public struct Payload: Codable, Sendable {
        public var messages: [ChatMessage]
        public var updatedAt: Date
    }

    /// 保留的消息条数上限。裁剪遵守配对规则（见 `trim`）。
    public static let maxMessages = 200

    private let directory: URL

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

    public func save(messages: [ChatMessage], sessionID: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = Payload(messages: Self.trim(messages), updatedAt: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: fileURL(for: sessionID), options: .atomic)
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