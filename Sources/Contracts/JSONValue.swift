import Foundation

/// 模型输出的 JSON 值。
///
/// 为什么不用 `Any`：`Any` 不是 `Sendable`，会污染整条并发链路；
/// 而且 import 回来的 tool_call 参数必须是可判等、可编码、可跨 actor 传递的。
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - 取值助手

public extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            // 模型偶尔把整数发成 "3"。这里不做隐式字符串解析，
            // 保持与 ZCode 的“严格类型、失败降级到工具层”一致。
            guard value.rounded() == value, value.magnitude < Double(Int.max) else { return nil }
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// 单行摘要：用于执行卡片上展示参数，不追求可逆。
    var compactDescription: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, value.magnitude < Double(Int.max) {
                return String(Int(value))
            }
            return String(value)
        case .string(let value):
            let single = value.replacingOccurrences(of: "\n", with: "\\n")
            let clipped = single.count > 60 ? String(single.prefix(60)) + "…" : single
            return "\"\(clipped)\""
        case .array(let items):
            return "[\(items.count) 项]"
        case .object(let dict):
            return "{\(dict.count) 个字段}"
        }
    }

    /// 序列化为紧凑 JSON 文本（键排序，便于稳定比较）。
    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }
}