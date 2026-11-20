import SwiftUI
import UIKit

/// 轻量 Markdown 渲染：只区分「围栏代码块」与「其余文本」。
///
/// 为什么不用完整的 Markdown 库：
/// - 引入第三方解析器就多一个我们没评估过的依赖（PROJECT.md C7）；
/// - Agent 输出里真正需要差别化渲染的只有代码——其余都是段落，
///   用 `AttributedString(markdown:)` 的行内语法（粗体、斜体、行内代码、链接）就够。
///
/// 也**不做**表格与嵌套列表的布局：它们会显著增加排版代码量，而收益只在长文档里体现。
struct MarkdownText: View {
    let text: String
    var isStreaming: Bool = false

    var body: some View {
        // 预先算好分段：ForEach 直接遍历下标而不是 (offset, segment) 元组——
        // Swift 不支持对元组元素取 keyPath（`\.offset` 会编译失败）。
        let segments = Self.segments(of: text)

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(segments.indices, id: \.self) { index in
                switch segments[index] {
                case .prose(let content):
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(Self.attributed(content))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }

            if isStreaming {
                Text("▍")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 分段

    enum Segment: Equatable {
        case prose(String)
        case code(String?, String)
    }

    /// 按 ``` 围栏切分。未闭合的围栏（流式输出中途）整段当作代码块处理——
    /// 这样正在输出的代码会立刻变成等宽块，而不是先闪一下正文再跳变。
    static func segments(of text: String) -> [Segment] {
        var result: [Segment] = []
        var buffer = ""
        var insideFence = false
        var language: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if insideFence {
                    if !buffer.isEmpty || result.isEmpty {
                        result.append(.code(language, stripTrailingNewline(buffer)))
                    } else {
                        result.append(.code(language, ""))
                    }
                    buffer = ""
                    language = nil
                    insideFence = false
                } else {
                    if !buffer.isEmpty {
                        result.append(.prose(stripTrailingNewline(buffer)))
                    }
                    buffer = ""
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    insideFence = true
                }
                continue
            }
            buffer += line
            buffer += "\n"
        }

        if insideFence {
            result.append(.code(language, stripTrailingNewline(buffer)))
        } else if !buffer.isEmpty {
            result.append(.prose(stripTrailingNewline(buffer)))
        }
        return result
    }

    private static func stripTrailingNewline(_ value: String) -> String {
        value.hasSuffix("\n") ? String(value.dropLast()) : value
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        // 解析失败就退化成纯文本：宁可少几个粗体，不要整条消息消失。
        return AttributedString(text)
    }
}

/// 围栏代码块：等宽字体 + 横向滚动 + 复制按钮。
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "代码").uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().opacity(0.4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}