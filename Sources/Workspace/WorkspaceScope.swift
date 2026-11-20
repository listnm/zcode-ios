import Foundation

/// 工作区状态快照（供 UI 显示）。不可变、可跨 actor 传递。
public struct WorkspaceSnapshot: Sendable, Equatable {
    /// 用户看到的目录名。
    public var displayName: String
    /// 目录的展示路径（真机上通常是 `/private/var/mobile/...`，因此 UI 只显示尾部）。
    public var path: String
    /// security scope 当前是否处于活跃状态。
    public var isActive: Bool
    /// 曾经选过、但当前无法续用，需要用户重新选择。
    public var needsReauthorization: Bool

    public static let none = WorkspaceSnapshot(
        displayName: "",
        path: "",
        isActive: false,
        needsReauthorization: false
    )

    /// UI 用的缩短路径：只保留最后两段，前面用 `…/`。
    public var shortPath: String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return path }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }
}

/// security-scoped 目录授权的作用域管理。
///
/// ## 为什么必须有这个 actor
/// iOS 的 `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`
/// 必须**成对**出现（硬约束 C1）。把这对调用放进一个 actor，是为了让“当前是否持有授权”
/// 只有一个权威答案——UI 层不允许自己再调一次。
///
/// ## iOS 的真实限制（锚点 §7.1）
/// macOS 可以用 `URL.BookmarkCreationOptions.withSecurityScope` 生成跨启动的持久书签；
/// **iOS 上这个选项不存在**。iOS 的 security scope 只在本次运行内有效，
/// 冷启动后 `startAccessingSecurityScopedResource()` 通常返回 false。
/// 因此本类的策略是：
///   - 尽力保存 bookmark（同一会话内、甚至同一进程重建时可以恢复）；
///   - 恢复失败时**不伪造成功**，而是返回 `needsReauthorization = true`，由 UI 请用户重选。
public actor WorkspaceScope {

    /// UserDefaults 键。改键名等于丢弃用户已选的工作区，不要随意改。
    private static let storageKey = "zcode.workspace.v1"

    private struct Persisted: Codable {
        var bookmark: Data
        var displayName: String
    }

    private let defaults: UserDefaults
    private let fileManager = FileManager()

    private var root: URL?
    /// 只记录“是我们启动的”那一次授权。若 `start...` 返回 false，
    /// 说明调用方本来就有访问权（例如刚由 document picker 返回的 URL），
    /// 此时我们**不能**去 stop，否则会把别人的授权关掉。
    private var startedByUs = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 查询

    public func snapshot() -> WorkspaceSnapshot {
        guard let root else { return .none }
        return WorkspaceSnapshot(
            displayName: root.lastPathComponent,
            path: root.path,
            isActive: true,
            needsReauthorization: false
        )
    }

    /// 供文件工具使用的根 URL。未激活时返回 nil，工具据此产出 `notSelected` 错误结果。
    public func currentRoot() -> URL? {
        guard startedByUs || root != nil else { return nil }
        return root
    }

    /// 当前活跃根 + 解析器。工具层唯一入口。
    public func currentResolver() -> WorkspacePathResolver? {
        guard let root else { return nil }
        return WorkspacePathResolver(root: root)
    }

    // MARK: - 授权生命周期

    /// 采纳用户新选的目录：开启 security scope、探测可读性、落盘 bookmark。
    ///
    /// - Throws: `WorkspaceError.accessDenied` 当目录实际不可读时。
    @discardableResult
    public func adopt(_ url: URL) throws -> WorkspaceSnapshot {
        // 换目录前先把上一次的授权还回去，避免 scope 泄漏。
        release()

        // iOS 8.0+
        let didStart = url.startAccessingSecurityScopedResource()
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL

        do {
            try probe(canonical)
        } catch {
            if didStart { url.stopAccessingSecurityScopedResource() }
            throw WorkspaceError.accessDenied(name: canonical.lastPathComponent)
        }

        root = canonical
        startedByUs = didStart
        persist(canonical)
        return snapshot()
    }

    /// 冷启动恢复。失败时返回 `needsReauthorization = true`，**不会**静默降级。
    public func restore() -> WorkspaceSnapshot {
        guard let data = defaults.data(forKey: Self.storageKey),
              let record = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return .none
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: record.bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            defaults.removeObject(forKey: Self.storageKey)
            return WorkspaceSnapshot(
                displayName: record.displayName,
                path: "",
                isActive: false,
                needsReauthorization: true
            )
        }

        let didStart = url.startAccessingSecurityScopedResource()
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL

        do {
            try probe(canonical)
        } catch {
            if didStart { url.stopAccessingSecurityScopedResource() }
            return WorkspaceSnapshot(
                displayName: record.displayName,
                path: canonical.path,
                isActive: false,
                needsReauthorization: true
            )
        }

        root = canonical
        startedByUs = didStart
        // bookmark 变陈旧时重写一次，延长可用性（仍不保证跨启动）。
        if isStale { persist(canonical) }

        return WorkspaceSnapshot(
            displayName: canonical.lastPathComponent,
            path: canonical.path,
            isActive: true,
            needsReauthorization: false
        )
    }

    /// 只释放授权，保留用户的选择记录（下次启动还能尝试恢复）。
    public func release() {
        if startedByUs, let root {
            root.stopAccessingSecurityScopedResource()
        }
        startedByUs = false
        root = nil
    }

    /// 释放授权并彻底忘记这个工作区。
    public func forget() {
        release()
        defaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: - 私有

    /// 真正验证“能不能读”：`startAccessing` 返回 true 不代表目录存在且可枚举。
    private func probe(_ url: URL) throws {
        _ = try fileManager.contentsOfDirectory(atPath: url.path)
    }

    private func persist(_ url: URL) {
        // 默认选项（不是 .minimalBookmark）：尽量保留 sandbox 扩展信息。
        guard let bookmark = try? url.bookmarkData(
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            // 生成失败不致命：本次会话仍可用，只是重启后必需要重选。
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        let record = Persisted(bookmark: bookmark, displayName: url.lastPathComponent)
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}