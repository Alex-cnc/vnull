import Foundation
import Security

import DoyahCore

/// macOS 侧的智能体 API Key 存储实现：系统钥匙串。
///
/// 与 `KeychainSecretStore` 同一个理由放在平台模块：`import Security` 不是跨平台的。
/// 契约（两侧一致）：**API Key 不落配置文件**，可被明确清除，不进日志与审计。
public struct KeychainAgentKeyStore: AgentKeyStore {
    /// 默认账号名；同一台机器上所有端点共用一条记录（配置里只保留一个活动端点）。
    public static let defaultAccount = "agent.api-key"

    private let service: String
    private let account: String

    public init(
        service: String = DoyahIdentity.keychainServiceName,
        account: String = KeychainAgentKeyStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func setAPIKey(_ key: String) throws {
        let query = baseQuery()
        let data = Data(key.utf8)

        let existingStatus = SecItemCopyMatching(query as CFDictionary, nil)
        if existingStatus == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AppError.credentialStore(code: updateStatus)
            }
            return
        }

        guard existingStatus == errSecItemNotFound else {
            throw AppError.credentialStore(code: existingStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AppError.credentialStore(code: addStatus)
        }
    }

    public func apiKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AppError.credentialStore(code: status)
        }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw AppError.credentialStore(code: errSecInternalError)
        }
        return key
    }

    public func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.credentialStore(code: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
