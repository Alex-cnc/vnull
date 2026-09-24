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
        case .mysql:
            return MySQLDialect()
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
    /// 全库对象搜索的**单次**元数据查询（FR-META-12）；nil = 该方言不支持。
    ///
    /// 为什么放进方言层：这条查询吃的是**系统目录**（PG 的 `pg_class` / `information_schema`），
    /// 换方言就是另一套目录。没有这一层时，非 PG 连接上会拿一条 PG 口径的 SQL 去跑，
    /// 用户看到的是一句莫名其妙的 SQL 报错 —— 而"这个方言不支持"本该是一句人话。
    func objectSearchQuery(schema: String?, limit: Int) -> String?

    /// 数据库统计指标查询（FR-DIAG-04）；nil = 该方言不支持。
    ///
    /// 这些指标吃的是 **PostgreSQL 的统计视图**（`pg_stat_user_tables` / `pg_stat_database` / `pg_stat_activity`），
    /// 换方言就是另一套（或根本没有），所以走同一个"能力开口"模式。
    func databaseStatsQuery(_ metric: DatabaseStats.Metric, limit: Int) -> String?
    /// 表结构查询（FR-DDL-03）：列名 / 类型 / 可空 / **默认值** / **是否主键**；nil = 该方言不支持。
    ///
    /// 与 `listColumnsQuery` 的区别：那个只给对象树用的列名与类型，这个要支撑"改表结构"，
    /// 必须知道当前默认值与主键 —— 否则界面上算不出差异、会把没改的列也写成 ALTER。
    func tableStructureQuery(table: String, schema: String?) -> String?

    /// 视图定义查询（FR-META-13）：结果的**定义体**由 `ObjectDDL` 包成 `CREATE OR REPLACE VIEW`。
    /// nil = 该方言不支持（界面据此不呈现该项，而不是给一句看不懂的报错）。
    func viewDDLQuery(view: String, schema: String?) -> String?
    /// 函数 / 存储过程定义查询（FR-META-13）；nil = 该方言不支持。
    func functionDDLQuery(function: String, schema: String?) -> String?

    /// 已存在索引的查询（FR-DDL-03 的「删索引」要先看得见）；nil = 不支持。
    /// 结果约定：第 1 列索引名、第 2 列定义文本。
    func tableIndexesQuery(table: String, schema: String?) -> String?
    /// 已存在约束的查询（主键 / 唯一 / 外键 / CHECK）；nil = 不支持。
    /// 结果约定：第 1 列约束名、第 2 列类型代码（p/u/f/c）、第 3 列定义文本。
    func tableConstraintsQuery(table: String, schema: String?) -> String?

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
    func viewDDLQuery(view: String, schema: String?) -> String? { nil }
    func functionDDLQuery(function: String, schema: String?) -> String? { nil }
    func tableIndexesQuery(table: String, schema: String?) -> String? { nil }
    func tableConstraintsQuery(table: String, schema: String?) -> String? { nil }
    func lockWaitingQuery() -> String? { nil }
    func objectSearchQuery(schema: String?, limit: Int) -> String? { nil }
    func databaseStatsQuery(_ metric: DatabaseStats.Metric, limit: Int) -> String? { nil }
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

    /// 全库对象搜索（FR-META-12）：PG 口径的系统目录查询，由 `ObjectSearch` 提供，方言层只做转发。
    public func objectSearchQuery(schema: String?, limit: Int) -> String? {
        ObjectSearch.query(schema: schema, limit: limit)
    }

    /// 数据库统计指标（FR-DIAG-04）：四类指标各自一条查询，全部用**PG 12 起就有的视图**，
    /// 刻意不用 `pg_stat_io`（那是 16+）—— 需求点名的"按版本兼容"落在这里。
    public func databaseStatsQuery(_ metric: DatabaseStats.Metric, limit: Int) -> String? {
        let bounded = max(1, limit)
        switch metric {
        case .tableSizes:
            return """
            SELECT schemaname || '.' || relname AS name,
                   pg_total_relation_size(relid) AS bytes
            FROM pg_catalog.pg_statio_user_tables
            ORDER BY bytes DESC
            LIMIT \(bounded)
            """
        case .indexHitRate:
            return """
            SELECT schemaname || '.' || relname AS name,
                   seq_scan, idx_scan
            FROM pg_catalog.pg_stat_user_tables
            ORDER BY (seq_scan + idx_scan) DESC
            LIMIT \(bounded)
            """
        case .connections:
            return """
            SELECT coalesce(state, 'unknown') AS state, count(*) AS count
            FROM pg_catalog.pg_stat_activity
            WHERE backend_type = 'client backend'
            GROUP BY state
            ORDER BY count DESC
            """
        case .cacheHitRate:
            return """
            SELECT sum(blks_hit) AS hits, sum(blks_read) AS reads
            FROM pg_catalog.pg_stat_database
            """
        }
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

    /// 视图定义体：`pg_get_viewdef` 直接给出 `SELECT …`（带结尾分号），由 `ObjectDDL` 包装。
    ///
    /// 用 `regclass` 转换而不是去 `pg_views` 里查文本：`regclass` 走的是标识符解析，
    /// 带 schema / 带引号的怪名字都能正确落到同一个对象上。
    public func viewDDLQuery(view: String, schema: String?) -> String? {
        let target = SQLGenerator.qualifiedName(table: view, schema: schema, dialect: self)
        return "SELECT pg_get_viewdef(\(literal(target))::regclass, true) AS view_definition"
    }

    /// 函数定义：`pg_get_functiondef` 给出**完整**的 `CREATE OR REPLACE FUNCTION`。
    ///
    /// 同名函数可能有多个重载（不同参数），因此不 `LIMIT 1` —— 全部取出由 `ObjectDDL` 依次拼接，
    /// 丢掉任何一个都会让人以为"这函数只有一种签名"。
    public func functionDDLQuery(function: String, schema: String?) -> String? {
        var sql = """
        SELECT pg_get_functiondef(p.oid) AS function_definition
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.proname = \(literal(function))
        """
        if let schema, !schema.isEmpty {
            sql += "\n  AND n.nspname = \(literal(schema))"
        } else {
            // 没给 schema 时只取当前搜索路径可见的那些，避免同名函数跨 schema 混进来。
            sql += "\n  AND pg_function_is_visible(p.oid)"
        }
        return sql + "\n ORDER BY p.oid"
    }

    /// 索引：`pg_indexes.indexdef` 就是一条现成的 `CREATE INDEX …`，直接展示即可，
    /// 不必自己从 `pg_index` 拼 —— 拼出来的东西迟早与真实定义有出入。
    public func tableIndexesQuery(table: String, schema: String?) -> String? {
        let schemaName = schema ?? "public"
        return """
        SELECT indexname, indexdef
        FROM pg_indexes
        WHERE schemaname = \(literal(schemaName)) AND tablename = \(literal(table))
        ORDER BY indexname
        """
    }

    /// 约束：`pg_get_constraintdef` 给出定义体；类型代码照抄 `pg_constraint.contype`（p/u/f/c）。
    public func tableConstraintsQuery(table: String, schema: String?) -> String? {
        let schemaName = schema ?? "public"
        return """
        SELECT con.conname, con.contype, pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = \(literal(schemaName))
          AND c.relname = \(literal(table))
          AND con.contype IN ('p', 'u', 'f', 'c')
        ORDER BY con.conname
        """
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

    /// GBase 8a 兼容 MySQL 语法：`SHOW CREATE VIEW` 直接给出完整建视图语句。
    public func viewDDLQuery(view: String, schema: String?) -> String? {
        "SHOW CREATE VIEW \(SQLGenerator.qualifiedName(table: view, schema: schema, dialect: self))"
    }

    /// 同上：`SHOW CREATE FUNCTION` 给出完整定义。
    public func functionDDLQuery(function: String, schema: String?) -> String? {
        "SHOW CREATE FUNCTION \(SQLGenerator.qualifiedName(table: function, schema: schema, dialect: self))"
    }

    /// GBase 8a 兼容 MySQL：`SHOW INDEX FROM <表>` / `SHOW CREATE TABLE` 里含索引与约束。
    public func tableIndexesQuery(table: String, schema: String?) -> String? {
        "SHOW INDEX FROM \(SQLGenerator.qualifiedName(table: table, schema: schema, dialect: self))"
    }

    public func tableConstraintsQuery(table: String, schema: String?) -> String? {
        // MySQL 语法没有"约束清单"这类视图；`information_schema` 可用，但列语义与 PG 不同，
        // 与其给一个半对的实现，不如返回 nil 让界面明说"该库类型暂不支持读约束"。
        nil
    }

    public var builtinFunctions: [String] {
        [
            "database", "version", "now", "count", "sum", "avg", "min", "max",
            "concat", "ifnull", "substring", "trim", "upper", "lower", "length",
            "date_format", "str_to_date"
        ]
    }
}
