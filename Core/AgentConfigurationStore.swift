import Foundation
import Security

/// 智能体 API Key 的存储抽象（FR-AI-01）。
///
/// 单独抽一层的原因有二：① 密钥只应进系统钥匙串，而钥匙串在单测环境里不可靠，
/// 用协议隔离才能让上层逻辑（闸门、请求构造）在无钥匙串时也被完整覆盖；
/// ② 将来要换存储（如企业密钥管理）时不必改调用方。
public protocol AgentKeyStore: Sendable {
    func setAPIKey(_ key: String) throws
    func apiKey() throws -> String?
    func deleteAPIKey() throws
}

/// 钥匙串实现：**API Key 不落配置文件**（FR-AI-01）。
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
            throw AppError.keychain(status)
        }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw AppError.keychain(errSecInternalError)
        }
        return key
    }

    public func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychain(status)
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

/// 智能体配置的持久化（FR-AI-01）。
///
/// 写到 `~/Library/Application Support/DoyahStudio/agent.json`。
/// 文件里**只有非敏感项**：总开关、端点、模型名、超时、配额。
/// API Key 在钥匙串里（`AgentKeyStore`），类型层面就没有可写入的字段。
public actor AgentConfigurationStore {
    public static let shared = AgentConfigurationStore()

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL? = nil) {
        let baseURL: URL
        if let directoryURL {
            baseURL = directoryURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            baseURL = applicationSupport.appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
        }

        self.fileURL = baseURL.appendingPathComponent("agent.json", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 读取配置；文件不存在时返回**关闭状态的默认配置**（安全默认，NFR-AI-02）。
    public func load() throws -> AgentConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .default
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(AgentConfiguration.self, from: data)
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    public func save(_ configuration: AgentConfiguration) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(configuration)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    public func fileLocation() -> URL {
        fileURL
    }
}
