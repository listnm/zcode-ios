import Foundation

/// 工作区相关错误。
///
/// 设计要求：**每一种越界/失权都必须有可读的、可区分的中文原因**。
/// 不能把权限失败糊成一句 "操作失败"，否则模型无法自我修正、用户也无法排查。
public enum WorkspaceError: Error, LocalizedError, Sendable, Equatable {
    /// 还没选工作区。
    case notSelected
    /// 目录授权失败或已失效（security scope 未激活）。
    case accessDenied(name: String)
    /// 目标路径解析后落在工作区之外（含 symlink 逃逸、`..` 穿越、绝对路径）。
    case outsideWorkspace(raw: String)
    /// 目标不存在。
    case notFound(raw: String)
    /// 期望文件但拿到目录。
    case isDirectory(raw: String)
    /// 期望目录但拿到文件。
    case notDirectory(raw: String)
    /// 工作区根目录不允许被删除。
    case rootCannotBeDeleted
    /// 目录删除必须显式声明 recursive。
    case directoryRequiresRecursive(raw: String)
    /// 文件不是 UTF-8 文本。
    case notText(raw: String)
    /// 读写失败（底层 errno 文案）。
    case ioFailed(raw: String, reason: String)
    /// 路径包含非法字符（NUL）。
    case invalidPath(raw: String)

    public var errorDescription: String? {
        switch self {
        case .notSelected:
            return "尚未选择工作区。请先在设置中选择一个文件夹。"
        case .accessDenied(let name):
            return "无法访问工作区「\(name)」：授权已失效，请重新选择该文件夹。"
        case .outsideWorkspace(let raw):
            return "路径 `\(raw)` 超出工作区范围，已拒绝。所有文件操作只能发生在工作区内。"
        case .notFound(let raw):
            return "路径 `\(raw)` 不存在。"
        case .isDirectory(let raw):
            return "`\(raw)` 是目录，不是文件。"
        case .notDirectory(let raw):
            return "`\(raw)` 不是目录。"
        case .rootCannotBeDeleted:
            return "不能删除工作区根目录。"
        case .directoryRequiresRecursive(let raw):
            return "`\(raw)` 是目录。删除目录必须显式设置 recursive = true。"
        case .notText(let raw):
            return "`\(raw)` 不是 UTF-8 文本文件（可能是二进制或图片），一期不支持读取。"
        case .ioFailed(let raw, let reason):
            return "操作 `\(raw)` 失败：\(reason)"
        case .invalidPath(let raw):
            return "路径 `\(raw)` 包含非法字符。"
        }
    }
}