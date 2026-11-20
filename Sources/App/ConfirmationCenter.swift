import Foundation
import Observation

/// 需要在执行工具**中途**向用户要一个答案的确认点。
///
/// ZCode 对应物：`PermissionBrokerPort.requestPermission(...)` 返回 `PermissionDecision`
/// （allow / deny / escalate / modify）。本工程一期只实现两个答案 + 取消，即
/// user-once 语义（`approvalMode: "user-once"`，不做持久 allow 规则，见 PROJECT.md D-02）。
///
/// 关键实现约束：
/// 1. **唯一 pending**。工具执行是串行的（D-01），任何时刻最多一个待确认请求；
///    若真的来了第二个，直接拒绝而不是排队，避免双 continuation 造成的悬空 Task。
/// 2. **可取消**。Agent 被 Stop 时，等待中的确认必须立刻以 `.cancelled` 结束，
///    否则 Task 会一直挂在这里（不变量 I5）。
/// 3. **只在 MainActor 上操作 UI 状态**，工具通过 `await` 调用它。
@MainActor
@Observable
public final class ConfirmationCenter {

    public enum Outcome: Sendable, Equatable {
        case approved
        case denied
        /// 不是因为用户点“取消”，而是上层任务被终止。
        case cancelled
    }

    public struct Request: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let title: String
        public let message: String
        public let confirmTitle: String

        public init(id: UUID = UUID(), title: String, message: String, confirmTitle: String) {
            self.id = id
            self.title = title
            self.message = message
            self.confirmTitle = confirmTitle
        }
    }

    /// UI 绑定：非 nil 时弹 alert。
    public private(set) var pending: Request?

    private var continuation: CheckedContinuation<Outcome, Never>?

    public init() {}

    /// 发起确认并等待用户作答。**必须**由工具在 MainActor 之外 `await` 调用。
    public func request(title: String, message: String, confirmTitle: String) async -> Outcome {
        if Task.isCancelled { return .cancelled }

        // 串行执行下不会发生；若发生，说明上层有并发 bug，宁可拒绝也不要挂起。
        if pending != nil {
            return .denied
        }

        let request = Request(title: title, message: message, confirmTitle: confirmTitle)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                self.continuation = continuation
                self.pending = request
                // 注册后立刻复查：取消可能发生在上面的两次赋值之间。
                if Task.isCancelled {
                    _ = self.finish(.cancelled)
                }
            }
        } onCancel: {
            Task { @MainActor in
                _ = self.finish(.cancelled)
            }
        }
    }

    /// UI 按钮回调。带 id 是为了防止关闭旧的 alert 后误答新请求。
    public func resolve(id: UUID, approved: Bool) {
        guard pending?.id == id else { return }
        _ = finish(approved ? .approved : .denied)
    }

    /// Agent 被整体取消时调用，保证没有悬挂的 continuation。
    public func cancelPending() {
        _ = finish(.cancelled)
    }

    // MARK: - 私有

    /// 返回是否真正完成了这次结束（防双 resume）。
    @discardableResult
    private func finish(_ outcome: Outcome) -> Bool {
        guard let continuation else {
            pending = nil
            return false
        }
        self.continuation = nil
        self.pending = nil
        continuation.resume(returning: outcome)
        return true
    }
}