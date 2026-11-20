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
            if let workspaceError = error as? WorkspaceError, case .accessDenied = workspaceError {
                // 真机上这一步最常见：iCloud 目录还是占位符，或选择器只是「进去」而没「打开」。
                lastError = message + "\n如果这个文件夹在 iCloud 云盘里，请先在「文件」App 里打开它一次，让它下载到本地再重试。"
            } else {
                lastError = message
            }
            snapshot = await scope.snapshot()
        }
    }

    /// 把 App 自己的容器目录（或其下的子目录）直接设为工作区，绕开系统选择器。
    ///
    /// 为什么需要这条捷径：iOS 的文件夹选择器是「进入目录 → 点右上角『打开』」的交互，
    /// 折叠起来看很像「这一行点不动」，很多用户会卡在这一步放弃；
    /// 而 App 容器（文件 App 里的「我的 iPhone → ZCode」）对自己的文件本来就不需要授权，
    /// 所以这条路径既最短也最不容易出错。
    ///
    /// - Parameter subdirectory: 容器内的工作区子目录名。传 nil 表示直接用 Documents 根。
    public func adoptAppContainer(subdirectory: String = "ZCode 工作区") async {
        isBusy = true
        defer { isBusy = false }
        do {
            let fileManager = FileManager()
            let documents = try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let target: URL
            if !subdirectory.isEmpty {
                target = documents.appendingPathComponent(subdirectory, isDirectory: true)
                var isDirectory: ObjCBool = false
                if !fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } else if !isDirectory.boolValue {
                    lastError = "容器里已有同名文件「\(subdirectory)」，无法作为工作区目录。"
                    return
                }
            } else {
                target = documents
            }
            snapshot = try await scope.adopt(target)
            lastError = nil
        } catch {
            lastError = (error as? WorkspaceError)?.errorDescription
                ?? error.localizedDescription
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