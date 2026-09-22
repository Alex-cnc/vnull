import Foundation
import Security

public protocol SecretStore: Sendable {
    func setPassword(_ password: String, for connectionID: UUID) throws
    func password(for connectionID: UUID) throws -> String?
    func deletePassword(for connectionID: UUID) throws
}

public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = DoyahIdentity.keychainServiceName) {
        self.service = service
    }

    public func setPassword(_ password: String, for connectionID: UUID) throws {
        let query = baseQuery(connectionID: connectionID)
        let data = Data(password.utf8)

        let existingStatus = SecItemCopyMatching(query as CFDictionary, nil)
        if existingStatus == errSecSuccess {
            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AppError.keychain(updateStatus)
            }
            return
        }

        guard existingStatus == errSecItemNotFound else {
            throw AppError.keychain(existingStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AppError.keychain(addStatus)
        }
    }

    public func password(for connectionID: UUID) throws -> String? {
        var query = baseQuery(connectionID: connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AppError.keychain(status)
        }
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw AppError.keychain(errSecInternalError)
        }
        return password
    }

    public func deletePassword(for connectionID: UUID) throws {
        let status = SecItemDelete(baseQuery(connectionID: connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychain(status)
        }
    }

    private func baseQuery(connectionID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString
        ]
    }
}
