import Foundation

/// 工作区文件系统。所有真实 IO 都在这一个 actor 里，路径校验统一走 `WorkspacePathResolver`。
///
/// 设计要点：
/// - 这个 actor **不认识** Agent 循环，只提供能力；工具是薄壳（见 `WorkspaceFileTools.swift`）。
/// - 所有错误都是 `WorkspaceError`，由工具层转成 `ToolResult.error`，不会冒泡到 UI（不变量 I2）。
/// - 每个 public 方法开头都重新取一次 resolver，所以工作区被换掉/释放后不会用到陈旧根。
public actor WorkspaceFileSystem {

    private let scope: WorkspaceScope
    private let fileManager = FileManager()

    /// 列表默认上限，防止模型一个 list 把上下文灌满。
    public static let defaultListEntries = 200
    /// 单次读取默认上限（字节）。与 ZCode 的 `maxOutputBytes` 同一思路。
    public static let defaultReadBytes = 64 * 1024
    /// 递归列表的最大深度（相对起点）。
    private static let maxRecursiveDepth = 3

    public init(scope: WorkspaceScope) {
        self.scope = scope
    }

    // MARK: - 解析

    private func requireResolver() async throws -> WorkspacePathResolver {
        guard let resolver = await scope.currentResolver() else {
            throw WorkspaceError.notSelected
        }
        return resolver
    }

    /// 把相对路径解析成工作区内的绝对 URL，并做存在性/类型检查。
    private func locate(
        _ raw: String,
        expectingDirectory: Bool?
    ) async throws -> (resolver: WorkspacePathResolver, url: URL) {
        let resolver = try await requireResolver()
        let url = try resolver.resolve(raw)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceError.notFound(raw: raw)
        }
        if let expectingDirectory {
            if expectingDirectory, !isDirectory.boolValue {
                throw WorkspaceError.notDirectory(raw: raw)
            }
            if !expectingDirectory, isDirectory.boolValue {
                throw WorkspaceError.isDirectory(raw: raw)
            }
        }
        return (resolver, url)
    }

    // MARK: - list

    public func list(
        relativePath: String,
        recursive: Bool,
        maxEntries: Int
    ) async throws -> String {
        let (resolver, start) = try await locate(relativePath, expectingDirectory: true)
        let limit = min(max(maxEntries, 1), 1000)
        let depthLimit = recursive ? Self.maxRecursiveDepth : 0

        var lines: [String] = []
        var truncated = false
        // 用队列做广度优先，深度受限；不跟随符号链接（避免环和逃逸）。
        var queue: [(url: URL, depth: Int)] = [(start, 0)]
        var cursor = 0

        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1

            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: current.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: []
                )
            } catch {
                let reason = error.localizedDescription
                throw WorkspaceError.ioFailed(raw: resolver.relativePath(of: current.url), reason: reason)
            }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if lines.count >= limit {
                    truncated = true
                    break
                }

                // relativePath 解析后再做一次边界校验：防止“软链指向外部”被列进结果。
                // 越界分支只报文件名、不拼接路径：越界目标的绝对路径不该被放进模型上下文。
                guard resolver.contains(child.resolvingSymlinksInPath().standardizedFileURL) else {
                    let indent = String(repeating: "  ", count: current.depth)
                    lines.append("\(indent)\(child.lastPathComponent)  [软链指向工作区外，已忽略]")
                    continue
                }
                let relative = resolver.relativePath(of: child)

                let values = try? child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                let isSymlink = values?.isSymbolicLink ?? false
                let isDirectory = values?.isDirectory ?? false
                let indent = String(repeating: "  ", count: current.depth)

                if isDirectory && !isSymlink {
                    lines.append("\(indent)\(relative)/")
                    if recursive, current.depth < depthLimit {
                        queue.append((child, current.depth + 1))
                    }
                } else if isSymlink {
                    lines.append("\(indent)\(relative)  [symlink]")
                } else {
                    let size = values?.fileSize ?? 0
                    lines.append("\(indent)\(relative)  (\(size) bytes)")
                }
            }

            if truncated { break }
        }

        if lines.isEmpty {
            return "（目录为空）\(resolver.relativePath(of: start))"
        }
        var output = lines.joined(separator: "\n")
        if truncated {
            output += "\n[已截断：条目数超过上限 \(limit)]"
        }
        return output
    }

    // MARK: - read

    public func read(path: String, maxBytes: Int) async throws -> String {
        let (resolver, url) = try await locate(path, expectingDirectory: false)
        let limit = min(max(maxBytes, 1), 1_000_000)

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WorkspaceError.ioFailed(raw: path, reason: error.localizedDescription)
        }
        defer { try? handle.close() }

        var data: Data
        do {
            data = try handle.read(upToCount: limit) ?? Data()
        } catch {
            throw WorkspaceError.ioFailed(raw: path, reason: error.localizedDescription)
        }

        // 再读 1 字节判断是否截断——比查文件大小更准确（文件可能正在增长）。
        let hasMore = ((try? handle.read(upToCount: 1)) ?? Data()).isEmpty == false

        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.notText(raw: path)
        }

        var output = text
        if hasMore {
            output += "\n\n[已截断：仅返回前 \(limit) 字节，文件更大。可用更小的范围分段读取]"
        }
        let _ = resolver // 保留解析结果，便于将来加“读取日志”
        return output
    }

    // MARK: - write

    /// 目标是否已存在且是普通文件（用于判断“覆盖写”是否需要二次确认）。
    public func existingFileExists(path: String) async throws -> Bool {
        let resolver = try await requireResolver()
        let url = try resolver.resolve(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            throw WorkspaceError.isDirectory(raw: path)
        }
        return true
    }

    public func write(path: String, content: String) async throws -> String {
        let resolver = try await requireResolver()
        let url = try resolver.resolve(path)
        if resolver.isRoot(url) {
            throw WorkspaceError.isDirectory(raw: path)
        }

        let parent = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceError.ioFailed(raw: path, reason: error.localizedDescription)
        }

        let data = Data(content.utf8)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw WorkspaceError.ioFailed(raw: path, reason: error.localizedDescription)
        }
        return "已写入 \(resolver.relativePath(of: url))（\(data.count) 字节）"
    }

    // MARK: - delete

    public func delete(path: String, recursive: Bool) async throws -> String {
        let resolver = try await requireResolver()
        let url = try resolver.resolve(path)

        if resolver.isRoot(url) {
            throw WorkspaceError.rootCannotBeDeleted
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceError.notFound(raw: path)
        }
        if isDirectory.boolValue, !recursive {
            throw WorkspaceError.directoryRequiresRecursive(raw: path)
        }

        let relative = resolver.relativePath(of: url)
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw WorkspaceError.ioFailed(raw: path, reason: error.localizedDescription)
        }
        return "已删除 \(relative)"
    }

    // MARK: - 工具用：文件信息

    public func describe(path: String) async throws -> String {
        let resolver = try await requireResolver()
        let url = try resolver.resolve(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceError.notFound(raw: path)
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let kind = isDirectory.boolValue ? "directory" : "file"
        let size = values?.fileSize.map(String.init) ?? "?"
        let modified = values?.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        return "\(resolver.relativePath(of: url)) | \(kind) | \(size) bytes | modified \(modified)"
    }
}