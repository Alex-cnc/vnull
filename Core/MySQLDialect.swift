import Foundation

/// MySQL 方言（FR-DRV-09）。
///
/// **为什么是"包一层"而不是另写一套**：MySQL 与 GBase 8a 属同一个协议族，
/// 方言差异是 GBase 的**减法**（没有 `information_schema` 的某些表、没有 `SHOW GRANTS` 解析），
/// 不是另写一份 SQL。所以这里**把 MySQL 兼容的那部分转给 `GBaseDialect`**，
/// 只把"我是谁"（`databaseType`）与确实不同的地方改掉。
///
/// 这么做的另一个理由是**冻结纪律**：数据库侧既有代码本轮只增不改，
/// 所以不去抽 `GBaseDialect` 的公共基类（那要改既有文件），而是用组合转发；
/// 两条方言因此共享同一份 SQL 文本，"改了一处忘了另一处"由
/// `Tests/MySQLDialectTests` 的一致性用例守着（它逐条比对两边的文本）。
public struct MySQLDialect: SQLDialect {

    /// MySQL 8.0 的默认排序规则与字符集由服务端决定，我们只声明"没有默认 schema"：
    /// MySQL 里 database 与 schema 是同一个东西（与 GBase 一致），
    /// 所以树形结构是「服务器 → Database → Table → Column」，没有 schema 层。
    public let databaseType: DatabaseType = .mysql

    private let shared: GBaseDialect

    public init(shared: GBaseDialect = GBaseDialect()) {
        self.shared = shared
    }

    // MARK: - 与 GBase 8a 完全一致的部分（转发，不复制 SQL 文本）

    public var featureSet: SQLFeatureSet { shared.featureSet }
    public var identifierQuote: String { shared.identifierQuote }
    public var statementDelimiter: String { shared.statementDelimiter }
    public var keywords: [String] { shared.keywords }
    public var builtinFunctions: [String] { shared.builtinFunctions }

    public func quoteIdentifier(_ identifier: String) -> String {
        shared.quoteIdentifier(identifier)
    }

    public func limitClause(offset: Int, count: Int) -> String {
        shared.limitClause(offset: offset, count: count)
    }

    public func listDatabasesQuery() -> String { shared.listDatabasesQuery() }
    public func listSchemasQuery(database: String) -> String { shared.listSchemasQuery(database: database) }
    public func listTablesQuery(database: String, schema: String?) -> String {
        shared.listTablesQuery(database: database, schema: schema)
    }
    public func listColumnsQuery(table: String, schema: String?) -> String {
        shared.listColumnsQuery(table: table, schema: schema)
    }
    public func serverVersionQuery() -> String { shared.serverVersionQuery() }
    public func currentDatabaseQuery() -> String { shared.currentDatabaseQuery() }
    public func parseServerVersion(_ raw: String) -> DatabaseVersion { shared.parseServerVersion(raw) }
    public func serverActivityQuery() -> String? { shared.serverActivityQuery() }

    /// MySQL 的影响行数 / 自增 ID 会话函数（`ROW_COUNT()` / `LAST_INSERT_ID()`）。
    /// GBase 8a **不覆盖这条**（默认 nil）—— 它在 GBase 上的语义未实测（FR-DRV-08），宁可显示"未知"。
    public func sessionMetadataQuery() -> String? { "SELECT ROW_COUNT(), LAST_INSERT_ID()" }
    public func cancelSessionStatement(pid: Int) -> String? { shared.cancelSessionStatement(pid: pid) }
    public func terminateSessionStatement(pid: Int) -> String? { shared.terminateSessionStatement(pid: pid) }
    public func objectPrivilegeQuery(role: String) -> String? { shared.objectPrivilegeQuery(role: role) }
    public func lockWaitingQuery() -> String? { shared.lockWaitingQuery() }
    public func objectSearchQuery(schema: String?, limit: Int) -> String? {
        shared.objectSearchQuery(schema: schema, limit: limit)
    }
    public func databaseStatsQuery(_ metric: DatabaseStats.Metric, limit: Int) -> String? {
        shared.databaseStatsQuery(metric, limit: limit)
    }
    public func tableStructureQuery(table: String, schema: String?) -> String? {
        shared.tableStructureQuery(table: table, schema: schema)
    }
    public func viewDDLQuery(view: String, schema: String?) -> String? {
        shared.viewDDLQuery(view: view, schema: schema)
    }
    public func functionDDLQuery(function: String, schema: String?) -> String? {
        shared.functionDDLQuery(function: function, schema: schema)
    }
    public func tableIndexesQuery(table: String, schema: String?) -> String? {
        shared.tableIndexesQuery(table: table, schema: schema)
    }
    public func tableConstraintsQuery(table: String, schema: String?) -> String? {
        shared.tableConstraintsQuery(table: table, schema: schema)
    }

    // MARK: - 与 GBase 8a 不同的一处

    /// **建库权限**：MySQL 可以用 `SHOW GRANTS FOR CURRENT_USER()` 的结果判断，
    /// 但更稳的是直接问 `information_schema` 里的权限表 —— 它在 MySQL 5.7 / 8.0 都有，
    /// 而 GBase 8a 上没有这张表（所以那边返回 nil，见 `GBaseDialect`，G-17）。
    ///
    /// 判据写成"存在全局 CREATE 权限或对 `*.*` 的 CREATE"：与
    /// `PostgresDialect.databaseCreationPrivilegeQuery` 的语义保持一致（单行单列布尔值）。
    public func databaseCreationPrivilegeQuery() -> String? {
        """
        SELECT COUNT(*) > 0 AS can_create
          FROM mysql.user
         WHERE User = SUBSTRING_INDEX(CURRENT_USER(), '@', 1)
           AND Host = SUBSTRING_INDEX(CURRENT_USER(), '@', -1)
           AND (Create_priv = 'Y' OR Super_priv = 'Y')
        """
    }
}
