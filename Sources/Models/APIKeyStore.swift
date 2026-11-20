import Foundation
import Security

/// API Key 的唯一存放地：系统 Keychain。
///
/// 硬约束 C2：Key 不写 UserDefaults、不写 plist、不进日志、不进崩溃上报、
/// 不作为源码常量。本文件是唯一接触 Key 明文的代码路径，其余位置只拿 `hasKey` 布尔。
///
/// 最低版本：Keychain 全部 API 自 iOS 2.0 起可用。
public struct APIKeyStore: Sendable {

    public enum KeychainError: Error, LocalizedError, Sendable {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "Keychain 操作失败（\(status)）：\(message)"
            }
        }
    }

    private let service: String

    public init(service: String = "com.zcodeios.apikey") {
        self.service = service
    }

    public func save(_ key: String, providerID: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(providerID: providerID)
            return
        }
        // 先删后加，避免 kSecItemAdd 在已存在时返回 errSecDuplicateItem。
        delete(providerID: providerID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
            kSecValueData as String: Data(trimmed.utf8),
            // 只在设备解锁后可读，且不随备份迁移到其他设备。
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func load(providerID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    public func hasKey(providerID: UUID) -> Bool {
        load(providerID: providerID)?.isEmpty == false
    }

    /// 幂等删除。
    public func delete(providerID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}