import Foundation

// MARK: - 检索类与结构变更类工具
//
// 与四个基础文件工具同样的两条硬规则：
// 1. 永不抛出到门外（不变量 I2），一切失败都变成 `ToolResult.error`；
// 2. 每个可能耗时的分支前后都检查 `Task.isCancelled`，取消也要产出结果（不变量 I5）。
//
// 权限分层沿用 ZCode 的 capability 语义：
// - glob / grep 只读、sideEffectScope = .none，多个只读工具可并行（iOS 一期仍串行执行，
//   见 PROJECT.md 偏离 D-01，但元数据必须保持真实，否则将来放开并行会立刻出错）；
// - make_dir / copy / move 写磁盘，sideEffectScope = .workspace、needsApproval = true。

private func searchSchema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
    .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map { .string($0) }),
        "additionalProperties": .bool(false)
    ])
}

private func searchProp(_ type: String, _ description: String) -> JSONValue {
    .object([
        "type": .string(type),
        "description": .string(description)
    ])
}

// MARK: - glob

public struct GlobTool: AgentTool {
    public let dependencies: WorkspaceToolDependencies

    public init(dependencies: WorkspaceToolDependencies) {
        self.dependencies = dependencies
    }

    public var capability: ToolCapability {
        ToolCapability(
            name: "glob",
            summary: "按通配模式查找工作区内的文件（支持 ** 与 *）。",
            readOnly: true,
            destructive: false,
            sideEffectScope: .none,
            riskLevel: .low,
            needsApproval: false,
            parameters: searchSchema([
                "pattern": searchProp("string", "通配模式，例如 \"**/*.swift\" 或 \"docs/*.md\""),
                "maxEntries": searchProp("integer", "最多返回多少个路径，默认 200，上限 2000")
            ], required: ["pattern"])
        )
    }

    public func execute(arguments: ToolArguments) async -> ToolResult {
        do {
            let pattern = try arguments.string("pattern")
            let maxEntries = arguments.int("maxEntries", default: 200, clamped: 1...2000)

            if Task.isCancelled {
                return .cancelled("任务已取消")
            }

            let matches = try await dependencies.fileSystem.glob(pattern: pattern, maxEntries: maxEntries)
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            guard !matches.isEmpty else {
                return .ok("没有文件匹配「\(pattern)」。可以用 list_files 看看实际结构。")
            }
            return .ok(matches.joined(separator: "\n"))
        } catch {
            return toolFailure(error)
        }
    }
}

// MARK: - grep

public struct GrepTool: AgentTool {
    public let dependencies: WorkspaceToolDependencies

    public init(dependencies: WorkspaceToolDependencies) {
        self.dependencies = dependencies
    }

    public var capability: ToolCapability {
        ToolCapability(
            name: "grep",
            summary: "在工作区文本文件里按正则搜索内容，返回「路径:行号: 文本」。",
            readOnly: true,
            destructive: false,
            sideEffectScope: .none,
            riskLevel: .low,
            needsApproval: false,
            parameters: searchSchema([
                "pattern": searchProp("string", "正则表达式，例如 \"class .*Model\" 或 \"TODO\""),
                "relativePath": searchProp("string", "搜索起点（相对工作区根），省略表示全工作区"),
                "maxMatches": searchProp("integer", "最多返回多少行，默认 100，上限 500")
            ], required: ["pattern"])
        )
    }

    public func execute(arguments: ToolArguments) async -> ToolResult {
        do {
            let pattern = try arguments.string("pattern")
            let relativePath = arguments.optionalString("relativePath") ?? "."
            let maxMatches = arguments.int("maxMatches", default: 100, clamped: 1...500)

            if Task.isCancelled {
                return .cancelled("任务已取消")
            }

            let output = try await dependencies.fileSystem.grep(
                pattern: pattern,
                relativePath: relativePath,
                maxMatches: maxMatches
            )
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            return .ok(output)
        } catch {
            // 正则语法错误也要变成可读结果：模型据此修 pattern，而不是整轮失败。
            if error is WorkspaceError {
                return toolFailure(error)
            }
            return .error("正则表达式无效：\(error.localizedDescription)。请检查括号与转义。")
        }
    }
}

// MARK: - make_dir

public struct MakeDirectoryTool: AgentTool {
    public let dependencies: WorkspaceToolDependencies

    public init(dependencies: WorkspaceToolDependencies) {
        self.dependencies = dependencies
    }

    public var capability: ToolCapability {
        ToolCapability(
            name: "make_dir",
            summary: "在工作区内创建目录（含中间层）。",
            readOnly: false,
            destructive: false,
            sideEffectScope: .workspace,
            riskLevel: .low,
            needsApproval: true,
            parameters: searchSchema([
                "path": searchProp("string", "要创建的目录，相对工作区根")
            ], required: ["path"])
        )
    }

    public func execute(arguments: ToolArguments) async -> ToolResult {
        do {
            let path = try arguments.string("path")
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            let summary = try await dependencies.fileSystem.makeDirectory(path: path)
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            return .ok(summary)
        } catch {
            return toolFailure(error)
        }
    }
}

// MARK: - move_file

public struct MoveFileTool: AgentTool {
    public let dependencies: WorkspaceToolDependencies

    public init(dependencies: WorkspaceToolDependencies) {
        self.dependencies = dependencies
    }

    public var capability: ToolCapability {
        ToolCapability(
            name: "move_file",
            summary: "在工作区内移动或重命名文件/目录。",
            readOnly: false,
            destructive: false,
            sideEffectScope: .workspace,
            riskLevel: .medium,
            needsApproval: true,
            parameters: searchSchema([
                "from": searchProp("string", "源路径，相对工作区根"),
                "to": searchProp("string", "目标路径；必须不存在，父目录会自动创建")
            ], required: ["from", "to"])
        )
    }

    public func execute(arguments: ToolArguments) async -> ToolResult {
        do {
            let source = try arguments.string("from")
            let destination = try arguments.string("to")
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            let summary = try await dependencies.fileSystem.move(from: source, to: destination)
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            return .ok(summary)
        } catch {
            return toolFailure(error)
        }
    }
}

// MARK: - copy_file

public struct CopyFileTool: AgentTool {
    public let dependencies: WorkspaceToolDependencies

    public init(dependencies: WorkspaceToolDependencies) {
        self.dependencies = dependencies
    }

    public var capability: ToolCapability {
        ToolCapability(
            name: "copy_file",
            summary: "在工作区内复制文件/目录。",
            readOnly: false,
            destructive: false,
            sideEffectScope: .workspace,
            riskLevel: .low,
            needsApproval: true,
            parameters: searchSchema([
                "from": searchProp("string", "源路径，相对工作区根"),
                "to": searchProp("string", "目标路径；必须不存在")
            ], required: ["from", "to"])
        )
    }

    public func execute(arguments: ToolArguments) async -> ToolResult {
        do {
            let source = try arguments.string("from")
            let destination = try arguments.string("to")
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            let summary = try await dependencies.fileSystem.copy(from: source, to: destination)
            if Task.isCancelled {
                return .cancelled("任务已取消")
            }
            return .ok(summary)
        } catch {
            return toolFailure(error)
        }
    }
}