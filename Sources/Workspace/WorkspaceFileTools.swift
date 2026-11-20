import Foundation

/// 工具与宿主之间的依赖集合。四个工具都只拿到这个结构，不直接摸 UserDefaults / UI。
public struct WorkspaceToolDependencies: Sendable {
    public let fileSystem: WorkspaceFileSystem
    public let confirmations: ConfirmationCenter

    public init(fileSystem: WorkspaceFileSystem, confirmations: ConfirmationCenter) {
        self.fileSystem = fileSystem
        self.confirmations = confirmations
    }
}

/// 把任意错误翻译成模型能读懂的 `ToolResult`。
///
/// 这是不变量 I2 的落点：工具**永不**抛出门外，永远返回一条结果。
/// 模型收到的是「为什么失败」，而不是整个回合崩掉。
func toolFailure(_ error: Error) -> ToolResult {
    if let workspaceError = error as? WorkspaceError {
        return .error(workspaceError.errorDescription ?? "工作区操作失败。")
    }
    if let argumentError = error as? ToolArgumentError {
        return .error(argumentError.errorDescription ?? "参数不合法。")
    }
    return .error(error.localizedDescription)
}

// MARK: - schema 构造助手

/// 参数 schema 构造，避免四处手写重复的 `{"type":"object"}` 外壳。
private func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
    .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map { .string($0) }),
        "additionalProperties": .bool(false)
    ])
}

private func prop(_ type: String, _ description: String) -> JSONValue {
    .object([
        "type": .string(type),
        "description": .string(description)
    ])
}

// MARK: - list_files

/// 列出工作区内目录。对标 ZCode 的 Glob / ls 能力，但只作用于工作区。
public struct ListFilesTool: AgentTool {
    public let dependencies: WorkspaceToolDependencies

    public init(dependencies: WorkspaceToolDependencies) {
        self.dependencies = dependencies
    }

    public var capability: ToolCapability {
        ToolCapability(
            name: "list_files",
            summary: "列出工作区中某个目录的文件与子目录。",
            readOnly: true,
            destructive: false,
            sideEffectScope: .none,
            riskLevel: .low,
            needsApproval: false,
            parameters: schema([
                "relativePath": prop("string", "相对工作区根的目录路径，省略表示根目录"),
                "recursive": prop("boolean", "是否递归列出子目录（最多 3 层）"),
                "maxEntries": prop("integer", "最多返回条目数，默认 200，上限 1000")
            ], required: [])
        )
    }

    public func execute(arguments: ToolArguments) async -> ToolResult {
        let relativePath = arguments.optionalString("relativePath") ?? "."
        let recursive = arguments.bool("recursive", default: false)
        let maxEntries = arguments.int(
            "maxEntries",
            default: WorkspaceFileSystem.defaultListEntries,
            clamped: 1...1000
        )

        if Task.isCancelled {
            return .cancelled("任务已取消")
        }

        do {
            let output = try await dependencies.fileSystem.list(
                relativePath: relativePath,
                recursive: recursive,
                maxEntries: maxEntries
            )
            // 取消发生在 IO 过程中：结果已产出，仍按取消上报（配对仍完整）。
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            return .ok(output)
        } catch {
            return toolFailure(error)
        }
    }
}

// MARK: - read_file

public struct ReadFileTool: AgentTool {
    public let dependencies: WorkspaceToolDependencies

    public init(dependencies: WorkspaceToolDependencies) {
        self.dependencies = dependencies
    }

    public var capability: ToolCapability {
        ToolCapability(
            name: "read_file",
            summary: "读取工作区内某个文本文件的内容（按字节上限截断）。",
            readOnly: true,
            destructive: false,
            sideEffectScope: .none,
            riskLevel: .low,
            needsApproval: false,
            parameters: schema([
                "path": prop("string", "相对工作区根的文件路径，例如 \"src/main.swift\""),
                "maxBytes": prop("integer", "最多读取的字节数，默认 65536，上限 1000000")
            ], required: ["path"])
        )
    }

    public func execute(arguments: ToolArguments) async -> ToolResult {
        do {
            let path = try arguments.string("path")
            let maxBytes = arguments.int(
                "maxBytes",
                default: WorkspaceFileSystem.defaultReadBytes,
                clamped: 1...1_000_000
            )

            if Task.isCancelled {
                return .cancelled("任务已取消")
            }

            let output = try await dependencies.fileSystem.read(path: path, maxBytes: maxBytes)
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            return .ok(output)
        } catch {
            return toolFailure(error)
        }
    }
}

// MARK: - write_file

public struct WriteFileTool: AgentTool {
    public let dependencies: WorkspaceToolDependencies

    public init(dependencies: WorkspaceToolDependencies) {
        self.dependencies = dependencies
    }

    public var capability: ToolCapability {
        ToolCapability(
            name: "write_file",
            summary: "在工作区内创建或覆盖写入一个文本文件。",
            readOnly: false,
            destructive: false,
            sideEffectScope: .workspace,
            riskLevel: .medium,
            needsApproval: true,
            parameters: schema([
                "path": prop("string", "相对工作区根的文件路径；父目录会自动创建"),
                "content": prop("string", "要写入的完整文本内容（UTF-8）")
            ], required: ["path", "content"])
        )
    }

    public func execute(arguments: ToolArguments) async -> ToolResult {
        let path: String
        let content: String
        do {
            path = try arguments.string("path")
            content = try arguments.string("content")
        } catch {
            return toolFailure(error)
        }

        if Task.isCancelled {
            return .cancelled("任务已取消")
        }

        do {
            // 覆盖已有文件是不可逆的，比新建更危险，单独确认。
            let exists = try await dependencies.fileSystem.existingFileExists(path: path)
            if exists {
                let outcome = await dependencies.confirmations.request(
                    title: "覆盖已有文件？",
                    message: "Agent 将用新内容覆盖「\(path)」，原内容无法恢复。",
                    confirmTitle: "覆盖"
                )
                switch outcome {
                case .approved:
                    break
                case .denied:
                    return .error("用户拒绝覆盖「\(path)」。可以改用新的文件名，或先执行 delete_file。")
                case .cancelled:
                    return .cancelled("用户取消了确认")
                }
            }

            let summary = try await dependencies.fileSystem.write(path: path, content: content)
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            return .ok(summary)
        } catch {
            return toolFailure(error)
        }
    }
}

// MARK: - delete_file

public struct DeleteFileTool: AgentTool {
    public let dependencies: WorkspaceToolDependencies

    public init(dependencies: WorkspaceToolDependencies) {
        self.dependencies = dependencies
    }

    public var capability: ToolCapability {
        ToolCapability(
            name: "delete_file",
            summary: "删除工作区内的文件或目录（破坏性操作，必须用户确认）。",
            readOnly: false,
            destructive: true,
            sideEffectScope: .workspace,
            riskLevel: .high,
            needsApproval: true,
            parameters: schema([
                "path": prop("string", "要删除的相对路径；不能是工作区根"),
                "recursive": prop("boolean", "删除目录时必须为 true（含其中全部内容）")
            ], required: ["path"])
        )
    }

    public func execute(arguments: ToolArguments) async -> ToolResult {
        let path: String
        do {
            path = try arguments.string("path")
        } catch {
            return toolFailure(error)
        }
        let recursive = arguments.bool("recursive", default: false)

        if Task.isCancelled {
            return .cancelled("任务已取消")
        }

        // 破坏性操作无条件二次确认（对应 ZCode 的 destructive → needsApproval: true）。
        let outcome = await dependencies.confirmations.request(
            title: "确认删除？",
            message: "将永久删除工作区内的「\(path)」\(recursive ? "（含其中全部内容）" : "")，此操作不可撤销。",
            confirmTitle: "删除"
        )
        switch outcome {
        case .approved:
            break
        case .denied:
            return .error("用户拒绝删除「\(path)」。不要重试同一路径，请先向用户确认意图。")
        case .cancelled:
            return .cancelled("用户取消了确认")
        }

        do {
            let summary = try await dependencies.fileSystem.delete(path: path, recursive: recursive)
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            return .ok(summary)
        } catch {
            return toolFailure(error)
        }
    }
}

// MARK: - registry

/// 一期工具集。故意保持极简：只覆盖「工作区文件操作」，
/// 不移植 exec / http / browser / mcp / image / pdf（锚点 §8 非目标）。
///
/// 九个工具：4 个基础读写删 + 5 个检索/结构变更。
/// 顺序有意义：只读工具排在前面，写工具在后面——系统提示词按这个顺序给模型列能力，
/// 先读后写是我们在提示里反复强调的行为约束，工具表顺序与它保持一致。
public enum WorkspaceToolFactory {
    public static func makeAll(dependencies: WorkspaceToolDependencies) -> [any AgentTool] {
        [
            ListFilesTool(dependencies: dependencies),
            GlobTool(dependencies: dependencies),
            GrepTool(dependencies: dependencies),
            ReadFileTool(dependencies: dependencies),
            WriteFileTool(dependencies: dependencies),
            MakeDirectoryTool(dependencies: dependencies),
            CopyFileTool(dependencies: dependencies),
            MoveFileTool(dependencies: dependencies),
            DeleteFileTool(dependencies: dependencies)
        ]
    }
}