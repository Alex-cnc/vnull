import Foundation

public struct DatabaseVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var raw: String

    public init(major: Int, minor: Int, patch: Int = 0, raw: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.raw = raw
    }

    public var description: String {
        if patch > 0 {
            return "\(major).\(minor).\(patch)"
        }
        return "\(major).\(minor)"
    }

    public static func < (lhs: DatabaseVersion, rhs: DatabaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public enum SQLDialectFactory {
    public static func make(for databaseType: DatabaseType) -> any SQLDialect {
        switch databaseType {
        case .postgresql:
            return PostgresDialect()
        case .gbase8a:
            return GBaseDialect()
        }
    }
}

public protocol SQLDialect: Sendable {
    var databaseType: DatabaseType { get }
    var featureSet: SQLFeatureSet { get }
    var identifierQuote: String { get }
    var statementDelimiter: String { get }

    func quoteIdentifier(_ identifier: String) -> String
    func limitClause(offset: Int, count: Int) -> String
    func listDatabasesQuery() -> String
    /// 「当前用户能否创建数据库」的探测 SQL（单行单列布尔值）；
    /// 返回 nil 表示该方言暂不支持探测 —— UI 不应呈现「新建数据库」（FR-META-11）。
    func databaseCreationPrivilegeQuery() -> String?
    /// 服务器会话 / 进程列表查询（FR-SESS-01）；返回 nil 表示该方言暂不支持。
    func serverActivityQuery() -> String?
    /// 指定角色的对象权限查询（FR-SESS-04）：库 / schema / 表 / 视图 / 序列上的已授权限；nil = 不支持。
    func objectPrivilegeQuery(role: String) -> String?
    /// 锁等待 / 阻塞链查询（FR-DIAG-05）；nil = 该方言不支持。
    func lockWaitingQuery() -> String?
    /// 表结构查询（FR-DDL-03）：列名 / 类型 / 可空 / **默认值** / **是否主键**；nil = 该方言不支持。
    ///
    /// 与 `listColumnsQuery` 的区别：那个只给对象树用的列名与类型，这个要支撑"改表结构"，
    /// 必须知道当前默认值与主键 —— 否则界面上算不出差异、会把没改的列也写成 ALTER。
    func tableStructureQuery(table: String, schema: String?) -> String?

    /// 取消某个后端会话上**正在执行的语句**（FR-SESS-02）；nil = 不支持。
    func cancelSessionStatement(pid: Int) -> String?
    /// **终止**某个后端会话（FR-SESS-02）；nil = 不支持。
    func terminateSessionStatement(pid: Int) -> String?
    func listSchemasQuery(database: String) -> String
    func listTablesQuery(database: String, schema: String?) -> String
    func listColumnsQuery(table: String, schema: String?) -> String
    func serverVersionQuery() -> String
    func currentDatabaseQuery() -> String
    func parseServerVersion(_ raw: String) -> DatabaseVersion
    var keywords: [String] { get }
    var builtinFunctions: [String] { get }
}

/// 默认实现：新增的会话监控能力（FR-SESS）对暂不支持的方言统一「不提供」，
/// 这样第三方方言实现不必为了编译通过而写空方法。
public extension SQLDialect {
    func serverActivityQuery() -> String? { nil }
    func cancelSessionStatement(pid: Int) -> String? { nil }
    func terminateSessionStatement(pid: Int) -> String? { nil }
    func objectPrivilegeQuery(role: String) -> String? { nil }
    func tableStructureQuery(table: String, schema: String?) -> String? { nil }
    func lockWaitingQuery() -> String? { nil }
}

public struct PostgresDialect: SQLDialect {
    public let databaseType: DatabaseType = .postgresql
    public let featureSet: SQLFeatureSet = [
        .supportsSchemas,
        .supportsTransactions,
        .supportsMultipleStatements,
        .supportsSSL,
        .supportsExplain
    ]
    public let identifierQuote = "\""
    public let statementDelimiter = ";"

    public init() {}

    public func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    public func limitClause(offset: Int, count: Int) -> String {
        "LIMIT \(count) OFFSET \(offset)"
    }

    public func listDatabasesQuery() -> String {
        """
        SELECT datname
        FROM pg_database
        WHERE datistemplate = false
          AND has_database_privilege(current_user, datname, 'CONNECT')
        ORDER BY datname
        """
    }

    /// 建库权限：超级用户或 `rolcreatedb` 为真即可创建数据库。
    /// 只查 `pg_roles`，不依赖任何较新版本特性（`rolcreatedb` 自 8.1 起存在）。
    public func databaseCreationPrivilegeQuery() -> String? {
        "SELECT (rolsuper OR rolcreatedb) FROM pg_roles WHERE rolname = current_user"
    }

    /// 会话监控（FR-SESS-01）：`pg_stat_activity` 里挑出界面需要的列。
    ///
    /// 时间列显式转 `text`，省掉驱动侧的二进制时间戳格式化；`query` 截断到 500 字符，
    /// 避免超长 SQL 把列表撑爆（要全文可以点开该会话复制）。
    public func serverActivityQuery() -> String? {
        """
        SELECT pid,
               usename,
               datname,
               client_addr::text AS client_addr,
               application_name,
               state,
               wait_event_type,
               wait_event,
               backend_start::text AS backend_start,
               query_start::text AS query_start,
               left(query, 500) AS query
        FROM pg_stat_activity
        ORDER BY query_start DESC NULLS LAST
        """
    }

    /// 取消语句：只中断当前语句，会话与连接保留（FR-SESS-02）。
    public func cancelSessionStatement(pid: Int) -> String? {
        "SELECT pg_cancel_backend(\(pid))"
    }

    /// 终止会话：断开该后端的连接（FR-SESS-02）。
    public func terminateSessionStatement(pid: Int) -> String? {
        "SELECT pg_terminate_backend(\(pid))"
    }

    /// 对象权限查询（FR-SESS-04）：列出指定角色在**库 / schema / 表 / 视图 / 序列**上的已授权限。
    ///
    /// `aclexplode` 把 ACL 数组展开成行；`grantee = 0` 即 `PUBLIC`，故 `LEFT JOIN pg_roles` 兜住并 `COALESCE` 成 `PUBLIC`。
    /// PostgreSQL 没有统一的「权限总览」视图，只能拼三类目录表（`pg_database` / `pg_namespace` / `pg_class`）。
    /// 锁等待与阻塞链（FR-DIAG-05）。
    ///
    /// `pg_locks` 只说明「谁在等什么锁」，`pg_blocking_pids()` 才给出「被谁挡住」，
    /// 两者按 pid 合并后，界面才能画出「谁堵住谁」的链。
    /// `pg_blocking_pids` 是 int[]，这里用 `array_to_string` 转成 `101,102` 便于驱动侧统一成文本；
    /// `query` 截断 500 字符（要全文可以点开该会话）。
    public func lockWaitingQuery() -> String? {
        """
        SELECT a.pid,
               a.usename,
               a.datname,
               a.state,
               a.wait_event_type,
               a.wait_event,
               l.locktype,
               l.mode,
               l.granted,
               COALESCE(l.relation::regclass::text, '') AS relation,
               COALESCE(array_to_string(pg_blocking_pids(a.pid), ','), '') AS blocking_pids,
               left(a.query, 500) AS query,
               GREATEST(0, EXTRACT(EPOCH FROM (now() - COALESCE(a.query_start, now())))::int) AS waiting_seconds
        FROM pg_locks l
        JOIN pg_stat_activity a ON a.pid = l.pid
        WHERE NOT l.granted OR cardinality(pg_blocking_pids(a.pid)) > 0
        ORDER BY a.pid, l.locktype
        """
    }

    public func objectPrivilegeQuery(role: String) -> String? {
        """
        WITH target AS (SELECT oid AS role_oid FROM pg_roles WHERE rolname = \(literal(role)))
        SELECT 'database' AS object_kind, d.datname AS object_name, NULL::text AS schema_name,
               COALESCE(r.rolname, 'PUBLIC') AS grantee, p.privilege_type, p.is_grantable
          FROM pg_database d
          CROSS JOIN LATERAL aclexplode(d.datacl) AS p
          LEFT JOIN pg_roles r ON r.oid = p.grantee
         WHERE p.grantee = (SELECT role_oid FROM target) OR p.grantee = 0
        UNION ALL
        SELECT 'schema', n.nspname, NULL,
               COALESCE(r.rolname, 'PUBLIC'), p.privilege_type, p.is_grantable
          FROM pg_namespace n
          CROSS JOIN LATERAL aclexplode(n.nspacl) AS p
          LEFT JOIN pg_roles r ON r.oid = p.grantee
         WHERE p.grantee = (SELECT role_oid FROM target) OR p.grantee = 0
        UNION ALL
        SELECT CASE c.relkind WHEN 'S' THEN 'sequence' WHEN 'v' THEN 'view' ELSE 'table' END,
               c.relname, n.nspname,
               COALESCE(r.rolname, 'PUBLIC'), p.privilege_type, p.is_grantable
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          CROSS JOIN LATERAL aclexplode(c.relacl) AS p
          LEFT JOIN pg_roles r ON r.oid = p.grantee
         WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
           AND (p.grantee = (SELECT role_oid FROM target) OR p.grantee = 0)
         ORDER BY 1, 2, 3
        """
    }

    public func listSchemasQuery(database: String) -> String {
        "SELECT schema_name FROM information_schema.schemata WHERE catalog_name = \(literal(database)) ORDER BY schema_name"
    }

    public func listTablesQuery(database: String, schema: String?) -> String {
        var sql = """
        SELECT table_name, table_type
        FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        """
        if let schema, !schema.isEmpty {
            sql += " AND table_schema = \(literal(schema))"
        }
        sql += " ORDER BY table_name"
        return sql
    }

    /// 列 + 主键一次取回：`information_schema` 里主键要跨两张表，用 LEFT JOIN 收拢成一条查询，
    /// 免得为每张表再发一次往返。
    public func tableStructureQuery(table: String, schema: String?) -> String? {
        let schemaName = schema ?? "public"
        return """
        SELECT c.column_name,
               c.data_type,
               c.is_nullable,
               c.column_default,
               CASE WHEN pk.column_name IS NULL THEN 'NO' ELSE 'YES' END AS is_primary_key
        FROM information_schema.columns c
        LEFT JOIN (
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
             AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = \(literal(schemaName))
              AND tc.table_name = \(literal(table))
        ) pk ON pk.column_name = c.column_name
        WHERE c.table_schema = \(literal(schemaName)) AND c.table_name = \(literal(table))
        ORDER BY c.ordinal_position
        """
    }

    public func listColumnsQuery(table: String, schema: String?) -> String {
        let schemaName = schema ?? "public"
        return """
        SELECT column_name, data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = \(literal(schemaName)) AND table_name = \(literal(table))
        ORDER BY ordinal_position
        """
    }

    public func serverVersionQuery() -> String {
        "SHOW server_version"
    }

    public func currentDatabaseQuery() -> String {
        "SELECT current_database()"
    }

    public func parseServerVersion(_ raw: String) -> DatabaseVersion {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        let major = parts.indices.contains(0) ? parts[0] : 0
        let minor = parts.indices.contains(1) ? parts[1] : 0
        let patch = parts.indices.contains(2) ? parts[2] : 0
        return DatabaseVersion(major: major, minor: minor, patch: patch, raw: cleaned)
    }

    public var keywords: [String] {
        [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "VIEW", "INDEX", "SCHEMA",
            "DATABASE", "FUNCTION", "PROCEDURE", "RETURNS", "LANGUAGE",
            "BEGIN", "END", "DECLARE", "IF", "THEN", "ELSE", "LOOP",
            "LIMIT", "OFFSET", "ORDER", "BY", "GROUP", "HAVING", "JOIN",
            "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AS", "AND", "OR", "NOT",
            "NULL", "TRUE", "FALSE", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
            "IN", "IS", "LIKE", "BETWEEN", "VALUES", "SET", "UNION", "ALL",
            "DISTINCT", "CASE", "WHEN", "EXISTS", "RETURNING", "WITH", "CROSS",
            "FULL", "ASC", "DESC", "USING", "DEFAULT", "CHECK", "UNIQUE",
            "CONSTRAINT", "SEQUENCE", "TRIGGER", "COMMIT", "ROLLBACK",
            "SAVEPOINT", "EXPLAIN", "ANALYZE", "VACUUM", "COPY", "GRANT",
            "REVOKE", "TRUNCATE", "CAST", "INTERVAL"
        ]
    }

    public var builtinFunctions: [String] {
        [
            "current_database", "current_schema", "version", "now", "count",
            "sum", "avg", "min", "max", "coalesce", "nullif", "concat",
            "substring", "trim", "upper", "lower", "length", "date_trunc"
        ]
    }

    private func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

public struct GBaseDialect: SQLDialect {
    public let databaseType: DatabaseType = .gbase8a
    public let featureSet: SQLFeatureSet = [
        .supportsCustomDelimiter,
        .supportsSSL
    ]
    public let identifierQuote = "`"
    public let statementDelimiter = ";"

    public init() {}

    public func quoteIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    public func limitClause(offset: Int, count: Int) -> String {
        "LIMIT \(offset), \(count)"
    }

    public func listDatabasesQuery() -> String {
        "SHOW DATABASES"
    }

    /// GBase 8a 的建库权限判定依赖 `SHOW GRANTS` 输出解析，需真实实例验证后再实现；
    /// 在验证完成前返回 nil（不呈现「新建数据库」），见 `Docs/GBase-技术验证.md` 的 G-17。
    public func databaseCreationPrivilegeQuery() -> String? {
        nil
    }

    /// 会话监控（FR-SESS-01）：MySQL 协议族用 `SHOW PROCESSLIST`。
    ///
    /// 返回列与 `pg_stat_activity` 不同（`Id` / `User` / `db` / `Command` / `Time` / `State` / `Info`），
    /// `SessionMonitor` 已按列名兼容两套命名；**待真实 GBase 8a 实例验证列名与权限**
    /// （普通用户可能只能看到自己的会话）。
    public func serverActivityQuery() -> String? {
        "SHOW PROCESSLIST"
    }

    /// `KILL QUERY` 只取消语句、不断开会话（MySQL 5.0+ 语法，GBase 待实测）。
    public func cancelSessionStatement(pid: Int) -> String? {
        "KILL QUERY \(pid)"
    }

    /// `KILL` 终止整个连接（GBase 待实测）。
    public func terminateSessionStatement(pid: Int) -> String? {
        "KILL \(pid)"
    }

    public func listSchemasQuery(database: String) -> String {
        "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA"
    }

    public func listTablesQuery(database: String, schema: String?) -> String {
        if database.isEmpty {
            return "SHOW TABLES"
        }
        return "SHOW TABLES FROM \(quoteIdentifier(database))"
    }

    public func listColumnsQuery(table: String, schema: String?) -> String {
        "DESC \(quoteIdentifier(table))"
    }

    public func serverVersionQuery() -> String {
        "SELECT VERSION()"
    }

    public func currentDatabaseQuery() -> String {
        "SELECT DATABASE()"
    }

    public func parseServerVersion(_ raw: String) -> DatabaseVersion {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        let major = parts.indices.contains(0) ? parts[0] : 0
        let minor = parts.indices.contains(1) ? parts[1] : 0
        let patch = parts.indices.contains(2) ? parts[2] : 0
        return DatabaseVersion(major: major, minor: minor, patch: patch, raw: cleaned)
    }

    public var keywords: [String] {
        [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "VIEW", "DATABASE", "INDEX",
            "PROCEDURE", "FUNCTION", "BEGIN", "END", "DECLARE", "DELIMITER",
            "IF", "THEN", "ELSE", "WHILE", "LOOP", "CALL", "RETURN",
            "LIMIT", "ORDER", "BY", "GROUP", "HAVING", "JOIN", "LEFT",
            "RIGHT", "INNER", "OUTER", "ON", "AS", "AND", "OR", "NOT",
            "NULL", "TRUE", "FALSE", "PRIMARY", "KEY", "SHOW", "DESC",
            "IN", "IS", "LIKE", "BETWEEN", "VALUES", "SET", "UNION", "ALL",
            "DISTINCT", "CASE", "WHEN", "EXISTS", "ASC", "USING", "DEFAULT",
            "COMMIT", "ROLLBACK", "EXPLAIN", "USE", "REPLACE", "AUTO_INCREMENT",
            "ENGINE", "CHARSET", "COLLATE", "TEMPORARY", "UNSIGNED",
            "ZEROFILL", "GRANT", "REVOKE", "TRUNCATE"
        ]
    }

    public var builtinFunctions: [String] {
        [
            "database", "version", "now", "count", "sum", "avg", "min", "max",
            "concat", "ifnull", "substring", "trim", "upper", "lower", "length",
            "date_format", "str_to_date"
        ]
    }
}
