import Foundation

/// 智能体 API Key 的存储抽象（FR-AI-01）。
///
/// 单独抽一层的原因有三：① 密钥只应进**系统凭据存储**，而它在单测环境里不可靠，
/// 用协议隔离才能让上层逻辑（闸门、请求构造）在无凭据存储时也被完整覆盖；
/// ② Core 必须在两个平台上都能编译，而凭据存储是平台专属的，实现放平台模块
/// （macOS → `Platform/macOS/KeychainAgentKeyStore.swift`）；
/// ③ 将来要换存储（如企业密钥管理）时不必改调用方。
///
/// 契约（两侧一致）：**API Key 不落配置文件**，可被明确清除，不进日志与审计。
public protocol AgentKeyStore: Sendable {
    func setAPIKey(_ key: String) throws
    func apiKey() throws -> String?
    func deleteAPIKey() throws
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
