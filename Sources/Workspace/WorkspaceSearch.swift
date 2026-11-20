import Foundation

// MARK: - 工作区检索与结构变更
//
// 这一组能力对标 ZCode 的 Glob / Grep / mkdir / mv / cp，是本项目从"四个工具"
// 走向"能干活的 Agent"的关键增量。所有入口的第一件事仍然是路径归类：
// 目标必须落在工作区根之下（不变量 I4），越界直接抛 outsideWorkspace。
//
// 放在扩展里而不是原文件里，是为了让 WorkspaceFileSystem 的主体保持"读写删"的
// 最小闭环，检索类能力可以独立演进。

extension WorkspaceFileSystem {

    /// 单次检索的遍历上限，防止用户把工作区指向一个巨大的目录后把手机拖死。
    static let maxScanDepth = 6
    /// 单文件参与 grep 的字节上限：超过就跳过并计数，不静默当作"没匹配"。
    static let maxGrepFileBytes = 262_144
    /// 遍历时直接跳过的目录名：版本控制与构建产物对 Agent 没有价值，只会拖慢。
    static let skippedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "build", "Build", "DerivedData",
        ".build", "Pods", "vendor", "__pycache__", ".venv", "venv"
    ]

    // MARK: - glob

    /// 按 glob 模式匹配工作区内的文件，返回相对路径（字典序）。
    ///
    /// 支持的语法只有四种：`**`（任意层目录）、`*`（单层内任意字符）、`?`（单字符）、
    /// 以及字面量。**不支持** `{a,b}`、`[abc]`、`!` 取反——它们会让"看到什么就匹配什么"
    /// 变得不可预测，而模型对不可预测的行为只会乱试。
    public func glob(pattern: String, maxEntries: Int = 200) async throws -> [String] {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw WorkspaceError.invalidPath(raw: pattern)
        }
        // 允许 `**/*.swift` 这种写法以 `/` 开头吗？不允许：绝对路径在这里没有意义。
        guard !trimmed.hasPrefix("/") else {
            throw WorkspaceError.outsideWorkspace(raw: pattern)
        }

        guard let resolver = await scope.currentResolver() else {
            throw WorkspaceError.notSelected
        }

        let limit = min(max(maxEntries, 1), 2000)
        let regex = try NSRegularExpression(pattern: Self.globToRegex(trimmed))
        let root = resolver.root

        var results: [String] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var head = 0

        while head < queue.count {
            if Task.isCancelled {
                throw CancellationError()
            }
            let (current, depth) = queue[head]
            head += 1
            guard depth <= Self.maxScanDepth else { continue }

            let children = (try? FileManager.default.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )) ?? []

            for child in children {
                let name = child.lastPathComponent
                if name.hasPrefix(".") { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                // 软链一律不跟随：跟随会让 `/etc` 之类从工作区侧漏进来。
                if values?.isSymbolicLink == true { continue }
                let isDirectory = values?.isDirectory == true

                if isDirectory {
                    if !Self.skippedDirectoryNames.contains(name) {
                        queue.append((child, depth + 1))
                    }
                    // 目录也可能被模式命中（例如 `src*`），但只有以 `/` 结尾的模式才返回目录，
                    // 这里保持"只返回文件"，语义更窄也更好预测。
                } else {
                    let relative = resolver.relativePath(of: child)
                    let range = NSRange(relative.startIndex..., in: relative)
                    if regex.firstMatch(in: relative, options: [], range: range) != nil {
                        results.append(relative)
                        if results.count >= limit { break }
                    }
                }
            }
            if results.count >= limit { break }
        }

        return results.sorted()
    }

    /// glob → 正则。逐字符扫描而不是连续 replace，避免 `**` 被拆成两个 `*`。
    static func globToRegex(_ pattern: String) -> String {
        var output = "^"
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                let isDoubleStar = index + 1 < characters.count && characters[index + 1] == "*"
                if isDoubleStar {
                    // `**/` 吞掉零到多层目录；单独的 `**` 等价于"任意字符（含 /）"。
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        output += "(?:[^/]+/)*"
                        index += 3
                        continue
                    }
                    output += ".*"
                    index += 2
                    continue
                }
                output += "[^/]*"
            case "?":
                output += "[^/]"
            case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
                output += "\\\(character)"
            default:
                output.append(character)
            }
            index += 1
        }
        output += "$"
        return output
    }

    // MARK: - grep

    /// 在工作区内按正则搜索文本文件的内容，返回 `相对路径:行号: 文本`。
    public func grep(
        pattern: String,
        relativePath: String = ".",
        maxMatches: Int = 100
    ) async throws -> String {
        guard !pattern.isEmpty else {
            throw WorkspaceError.invalidPath(raw: pattern)
        }
        guard let resolver = await scope.currentResolver() else {
            throw WorkspaceError.notSelected
        }
        let regex = try NSRegularExpression(pattern: pattern)

        let start = try resolver.resolve(relativePath.isEmpty ? "." : relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: start.path, isDirectory: &isDirectory) else {
            throw WorkspaceError.notFound(raw: relativePath)
        }

        var files: [URL] = []
        if isDirectory.boolValue {
            files = collectFiles(from: start, resolver: resolver)
        } else {
            files = [start]
        }

        let limit = min(max(maxMatches, 1), 500)
        var lines: [String] = []
        var skippedLarge = 0
        var skippedBinary = 0
        var truncated = false

        for file in files {
            if Task.isCancelled {
                throw CancellationError()
            }
            if lines.count >= limit { truncated = true; break }

            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if size > Self.maxGrepFileBytes {
                skippedLarge += 1
                continue
            }
            guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { continue }
            // 前 512 字节含 NUL 视为二进制：二进制文件在手机上只会产生乱码噪音。
            if data.prefix(512).contains(0) {
                skippedBinary += 1
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else {
                skippedBinary += 1
                continue
            }

            let relative = resolver.relativePath(of: file)
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let string = String(line)
                let range = NSRange(string.startIndex..., in: string)
                guard regex.firstMatch(in: string, options: [], range: range) != nil else { continue }
                let display = string.count > 200 ? String(string.prefix(200)) + "…" : string
                lines.append("\(relative):\(offset + 1): \(display)")
                if lines.count >= limit { truncated = true; break }
            }
        }

        var output = lines.isEmpty ? "没有匹配的行。" : lines.joined(separator: "\n")
        if truncated {
            output += "\n[已截断：匹配数达到上限 \(limit)]"
        }
        if skippedLarge > 0 {
            output += "\n[跳过 \(skippedLarge) 个超过 \(Self.maxGrepFileBytes / 1024)KB 的文件]"
        }
        if skippedBinary > 0 {
            output += "\n[跳过 \(skippedBinary) 个二进制或非 UTF-8 文件]"
        }
        return output
    }

    /// 收集用于 grep 的文件列表（受深度与条目上限约束）。
    private func collectFiles(from root: URL, resolver: WorkspacePathResolver) -> [URL] {
        var files: [URL] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var head = 0
        while head < queue.count && files.count < 2000 {
            let (current, depth) = queue[head]
            head += 1
            guard depth <= Self.maxScanDepth else { continue }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )) ?? []
            for child in children {
                let name = child.lastPathComponent
                if name.hasPrefix(".") { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if !Self.skippedDirectoryNames.contains(name) {
                        queue.append((child, depth + 1))
                    }
                } else if resolver.contains(child) {
                    files.append(child)
                }
            }
        }
        return files
    }

    // MARK: - 结构变更

    public func makeDirectory(path: String) async throws -> String {
        let resolver = try await requireResolverForMutation()
        do {
            let target = try resolver.resolve(path)
            if FileManager.default.fileExists(atPath: target.path) {
                return "目录已存在：\(resolver.relativePath(of: target))"
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return "已创建目录 \(resolver.relativePath(of: target))"
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.ioFailed(raw: path, reason: error.localizedDescription)
        }
    }

    public func move(from source: String, to destination: String) async throws -> String {
        let resolver = try await requireResolverForMutation()
        do {
            let sourceURL = try resolver.resolve(source)
            let destinationURL = try resolver.resolve(destination)
            guard resolver.contains(sourceURL), resolver.contains(destinationURL) else {
                throw WorkspaceError.outsideWorkspace(raw: destination)
            }
            guard resolver.isRoot(sourceURL) == false else {
                throw WorkspaceError.rootCannotBeDeleted
            }
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw WorkspaceError.notFound(raw: source)
            }
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw WorkspaceError.ioFailed(
                    raw: destination,
                    reason: "目标已存在，请换一个名字或先删除它"
                )
            }
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return "已移动 \(resolver.relativePath(of: sourceURL)) → \(resolver.relativePath(of: destinationURL))"
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.ioFailed(raw: source, reason: error.localizedDescription)
        }
    }

    public func copy(from source: String, to destination: String) async throws -> String {
        let resolver = try await requireResolverForMutation()
        do {
            let sourceURL = try resolver.resolve(source)
            let destinationURL = try resolver.resolve(destination)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw WorkspaceError.notFound(raw: source)
            }
            guard !resolver.isRoot(destinationURL) else {
                throw WorkspaceError.isDirectory(raw: destination)
            }
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw WorkspaceError.ioFailed(
                    raw: destination,
                    reason: "目标已存在，请换一个名字或先删除它"
                )
            }
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return "已复制 \(resolver.relativePath(of: sourceURL)) → \(resolver.relativePath(of: destinationURL))"
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.ioFailed(raw: source, reason: error.localizedDescription)
        }
    }

    /// 结构变更共用的前置检查：没有工作区就没有"工作区内"这回事。
    private func requireResolverForMutation() async throws -> WorkspacePathResolver {
        guard let resolver = await scope.currentResolver() else {
            throw WorkspaceError.notSelected
        }
        return resolver
    }
}