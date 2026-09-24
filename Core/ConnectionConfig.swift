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
    /// 环境标签（FR-CONN-16）。`nil` = 没标 —— 不硬塞默认值：没标就是没标，
    /// 假装"默认是生产"会让每个连接都变成红色警告，反而失去意义。
    public var environment: ConnectionEnvironment?
    /// 用户自选颜色（FR-CONN-16）。环境标签的语义色优先于它。
    public var colorTag: CategoricalTone?

    /// 只读连接（FR-CONN-17）：客户端**拒绝执行写语句**。
    ///
    /// 口径必须说清：这是**本机保护**，不替代数据库权限 —— 它拦的是"我在这台机器上点错了"，
    /// 不是"有人绕过客户端"。所以它不能被 Safe Mode 之类的开关关掉（那是提醒，这是标记）。
    public var isReadOnly: Bool

    /// 连接建立后自动执行的 SQL（FR-CONN-17），例如 `SET search_path` / `statement_timeout`。
    public var startupSQL: String?

    /// 自定义分组 / 文件夹（FR-CONN-15）：按「项目 / 环境」组织大量连接。
    ///
    /// 为什么是**可选字符串**而不是分组对象：需求要的是"能归入自定义分组、侧边栏按组折叠"，
    /// 不是一套分组管理模型。字符串让用户随手打一个组名就能用；空 / 只有空白的组名视为**未分组**
    /// （否则会出现一个名字是空格的诡异分组）。
    public var group: String?

    /// SSH 隧道（FR-CONN-18）。`nil` = 直连 —— **默认就是直连**，不给已有连接凭空加一层跳板。
    ///
    /// 存的是"怎么连跳板机"，**口令 / 私钥口令不在这里**（走 `SecretStore`，键由
    /// `SSHTunnelSecrets.secretKey(for:)` 派生）。老配置文件里没有这个字段，解码后就是 `nil`，
    /// 因此不需要 schemaVersion 迁移。
    public var sshTunnel: SSHTunnelConfig?

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
        schemaVersion: Int = ConnectionConfig.currentSchemaVersion,
        environment: ConnectionEnvironment? = nil,
        colorTag: CategoricalTone? = nil,
        isReadOnly: Bool = false,
        startupSQL: String? = nil,
        group: String? = nil,
        sshTunnel: SSHTunnelConfig? = nil
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
        self.environment = environment
        self.colorTag = colorTag
        self.isReadOnly = isReadOnly
        self.startupSQL = startupSQL
        self.group = group
        self.sshTunnel = sshTunnel
    }

    /// 归一化后的组名：空 / 纯空白 → `nil`（未分组）。
    public var normalizedGroup: String? {
        guard let group else { return nil }
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 启动 SQL 拆成**逐条**语句（空串 / 纯注释不算）。
    ///
    /// 拆分的意义：连接之后要逐条发、逐条报错 —— 一条失败不该把后面的一起吞掉，
    /// 用户需要知道到底是哪一条没生效（`search_path` 没设上，后面所有查询都可能找错表）。
    public var startupStatements: [String] {
        guard let startupSQL, !startupSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return StatementSplitter(databaseType: dbType)
            .split(startupSQL)
            .map { $0.sql.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--") }
    }

    /// 显示用的外观（环境标签 + 自选色）。各处显示都走它，保证一致。
    public var appearance: ConnectionAppearance {
        ConnectionAppearance(environment: environment, colorTag: colorTag)
    }

    public var isValid: Bool {
        // 隧道参数的合法性**并进同一条规则**：表单允许保存、模型判为非法（或反过来）
        // 是两套规则漂移的经典来源（FR-CONN-06 / R-10 要求单一事实来源）。
        // 没配隧道、或隧道被关掉时，这条判定是恒真的 —— 直连行为一字未变。
        let tunnelIsValid = sshTunnel.map { !$0.isEnabled || $0.isValid } ?? true
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        port > 0 && port <= 65535 &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        tunnelIsValid
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
