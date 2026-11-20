import Foundation

/// 工作区路径解析器（纯函数，无 IO，可单测）。
///
/// 三重校验（硬约束 C1，对应锚点不变量 I4）：
///   1. 词法归一化：自己按 `/` 切分并消解 `.` 与 `..`，不依赖 Foundation 对 `..` 的处理细节；
///   2. 符号链接解析：`resolvingSymlinksInPath()`，防止工作区内的软链指向外部；
///   3. 组件前缀比对：用 `pathComponents` 数组比较，**禁止** `String.hasPrefix`
///      （`/a/workspace-evil` 会骗过 `/a/workspace` 的前缀检查）。
public struct WorkspacePathResolver: Sendable {

    /// 已解析符号链接、已标准化的工作区根。所有比较都以它为准。
    public let root: URL

    public init(root: URL) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    /// 把模型给的相对路径解析成工作区内的绝对 URL。
    /// - Parameter raw: 相对工作区根的路径。空串表示工作区根自身。
    /// - Throws: `WorkspaceError.outsideWorkspace` / `.invalidPath`
    public func resolve(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("\0") {
            throw WorkspaceError.invalidPath(raw: raw)
        }
        // 绝对路径一律拒绝：模型没有任何理由需要访问 /tmp 或 /var。
        if trimmed.hasPrefix("/") {
            throw WorkspaceError.outsideWorkspace(raw: raw)
        }
        // `~` 展开会直接逃出工作区。
        if trimmed.hasPrefix("~") {
            throw WorkspaceError.outsideWorkspace(raw: raw)
        }

        let components = try normalize(trimmed, raw: raw)

        if components.isEmpty {
            return root
        }

        var candidate = root
        for component in components {
            candidate.appendPathComponent(component, isDirectory: false)
        }

        // 符号链接可以指向任意位置，必须解析后再校验一次。
        let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard contains(canonical) else {
            throw WorkspaceError.outsideWorkspace(raw: raw)
        }
        return canonical
    }

    /// 目标是否就是工作区根。
    public func isRoot(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents == root.pathComponents
    }

    /// 目标是否在工作区内（含根本身）。
    public func contains(_ url: URL) -> Bool {
        let rootComponents = root.pathComponents
        let targetComponents = url.pathComponents
        guard targetComponents.count >= rootComponents.count else { return false }
        return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// 计算相对工作区根的展示路径（用于错误信息与 UI）。
    public func relativePath(of url: URL) -> String {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = root.pathComponents
        let targetComponents = canonical.pathComponents
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
            return canonical.path
        }
        return targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    // MARK: - 词法归一化

    private func normalize(_ raw: String, raw original: String) throws -> [String] {
        var output: [String] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                // 已经到工作区根还想往上跳 → 直接判越界，不留任何“待解析”空间。
                guard !output.isEmpty else {
                    throw WorkspaceError.outsideWorkspace(raw: original)
                }
                output.removeLast()
            default:
                output.append(String(part))
            }
        }
        return output
    }
}