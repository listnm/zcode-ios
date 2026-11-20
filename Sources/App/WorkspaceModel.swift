import Foundation
import Observation

/// 工作区在 UI 层的镜像。
///
/// 为什么需要这一层：`WorkspaceScope` 是 actor（后台隔离），而 SwiftUI 必须在 MainActor
/// 上读状态。这个类只做「快照搬运」，不持有任何业务判断——授权是否有效始终以 actor 为准。
@MainActor
@Observable
public final class WorkspaceModel {

    public private(set) var snapshot: WorkspaceSnapshot = .none
    public private(set) var isBusy = false
    /// 最近一次失败的可读原因（用于设置页提示条）。
    public private(set) var lastError: String?

    private let scope: WorkspaceScope

    public init(scope: WorkspaceScope) {
        self.scope = scope
    }

    public var isReady: Bool { snapshot.isActive }

    /// 冷启动：尝试用上次保存的书签恢复授权。
    public func restore() async {
        isBusy = true
        defer { isBusy = false }
        snapshot = await scope.restore()
        if snapshot.needsReauthorization {
            lastError = "上次选择的工作区在这台设备上无法自动恢复访问权限，请重新选择。"
        } else if snapshot.isActive {
            lastError = nil
        }
    }

    /// 用户在 .fileImporter 里选定目录后调用。
    public func adopt(_ url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            snapshot = try await scope.adopt(url)
            lastError = nil
        } catch {
            let message = (error as? WorkspaceError)?.errorDescription
                ?? error.localizedDescription
            lastError = message
            snapshot = await scope.snapshot()
        }
    }

    /// 只在本次运行内断开授权，保留选择记录。
    public func releaseAccess() async {
        await scope.release()
        snapshot = await scope.snapshot()
    }

    /// 彻底忘记这个工作区（设置页「移除工作区」）。
    public func forget() async {
        await scope.forget()
        snapshot = .none
        lastError = nil
    }

    public func clearError() {
        lastError = nil
    }

    /// 由 UI 层报告一次可读错误（例如系统选择器自身失败）。
    public func reportError(_ message: String) {
        lastError = message
    }
}