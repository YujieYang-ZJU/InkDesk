import Foundation
import Security

enum KeychainStore {
    static let serviceName = "fan.api.InkDesk"
    private static let account = "api-key"

    static func read(serviceName: String = KeychainStore.serviceName) throws -> String? {
        var query = identity(serviceName)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status, action: "读取") }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw InkError.message("钥匙串中的 API Key 格式无效。请重新保存。")
        }
        return value
    }

    static func save(_ value: String, serviceName: String = KeychainStore.serviceName) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 4096,
              !clean.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw InkError.message("API Key 不能为空，也不能包含空格或换行。")
        }
        let data = Data(clean.utf8)
        let query = identity(serviceName)
        let changes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, changes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw failure(status, action: "保存") }
    }

    static func delete(serviceName: String = KeychainStore.serviceName) throws {
        let status = SecItemDelete(identity(serviceName) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status, action: "删除") }
    }

    private static func identity(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private static func failure(_ status: OSStatus, action: String) -> InkError {
        let explanation: String
        switch status {
        case errSecInteractionNotAllowed: explanation = "钥匙串当前已锁定或不允许交互，请解锁 Mac 后重试。"
        case errSecAuthFailed, errSecUserCanceled: explanation = "钥匙串授权未完成，请重新授权。"
        case errSecMissingEntitlement: explanation = "应用签名或钥匙串权限不正确，请重新安装应用。"
        default: explanation = (SecCopyErrorMessageString(status, nil) as String?) ?? "未知的钥匙串错误。"
        }
        return InkError.message("无法\(action) API Key（钥匙串错误 \(status)）：\(explanation)")
    }
}
