import Foundation

public struct ConnectionConfig: Codable, Identifiable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var name: String
    public var dbType: DatabaseType
    public var host: String
    public var port: Int
    public var database: String
    public var username: String
    public var sslMode: SSLMode
    public var timeout: Int
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        name: String = "",
        dbType: DatabaseType = .postgresql,
        host: String = "127.0.0.1",
        port: Int? = nil,
        database: String = "",
        username: String = "",
        sslMode: SSLMode? = nil,
        timeout: Int = 5,
        schemaVersion: Int = ConnectionConfig.currentSchemaVersion
    ) {
        self.id = id
        self.name = name
        self.dbType = dbType
        self.host = host
        self.port = port ?? dbType.defaultPort
        self.database = database
        self.username = username
        self.sslMode = sslMode ?? dbType.defaultSSLMode
        self.timeout = timeout
        self.schemaVersion = schemaVersion
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        port > 0 && port <= 65535 &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var endpointDescription: String {
        "\(host):\(port)"
    }

    /// 界面上展示的连接标题：`名称 (登录用户名)`。
    ///
    /// 需求 FR-CONN-14：连接名后括注登录用户名，便于一眼区分
    /// 「同一台主机上的不同账号」以及「同名但账号不同的连接」。
    /// - 名称为空时使用调用方给的占位文案（本地化由 UI 层负责，Core 不硬编码语言）；
    /// - 用户名为空时只返回名称，不产生空括号。
    public func displayTitle(untitled: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedName.isEmpty ? untitled : trimmedName

        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else { return title }
        return "\(title) (\(trimmedUser))"
    }
}

public struct QueryHistory: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var connectionID: UUID
    public var sql: String
    public var executedAt: Date
    public var duration: TimeInterval
    public var succeeded: Bool

    public init(
        id: UUID = UUID(),
        connectionID: UUID,
        sql: String,
        executedAt: Date = Date(),
        duration: TimeInterval = 0,
        succeeded: Bool
    ) {
        self.id = id
        self.connectionID = connectionID
        self.sql = sql
        self.executedAt = executedAt
        self.duration = duration
        self.succeeded = succeeded
    }
}
