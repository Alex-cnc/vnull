import Foundation

/// SQL 生成器：把「界面上的一次点击」翻译成一条可执行 SQL（FR-DATA-01 ~ FR-DATA-03、FR-DDL-01、FR-DIAG-01）。
///
/// 只做字符串拼装，不连库、不执行，便于单测覆盖。
/// 所有标识符都走方言的 `quoteIdentifier`，避免大小写 / 保留字 / 特殊字符踩坑；
/// 分页统一走方言的 `limitClause`（PG `LIMIT n OFFSET m`，GBase `LIMIT m, n`）。
public enum SQLGenerator {

    /// 表数据浏览：`SELECT * FROM <表> LIMIT <行数> OFFSET <偏移>`（FR-DATA-01）。
    ///
    /// - Parameters:
    ///   - table: 表名（不含 schema）。
    ///   - schema: schema 名；GBase 等无 schema 层时传 nil。
    ///   - limit: 最多取多少行，默认 200（与「浏览前 N 行」的直觉一致）。
    ///   - offset: 偏移量，默认 0。
    public static func selectRows(
        table: String,
        schema: String? = nil,
        limit: Int = 200,
        offset: Int = 0,
        dialect: any SQLDialect
    ) -> String {
        let target = qualifiedName(table: table, schema: schema, dialect: dialect)
        let safeLimit = max(0, limit)
        let safeOffset = max(0, offset)
        return "SELECT * FROM \(target) \(dialect.limitClause(offset: safeOffset, count: safeLimit));"
    }

    /// 表行数统计：`SELECT count(*) FROM <表>`（FR-DATA-01）。
    public static func countRows(
        table: String,
        schema: String? = nil,
        dialect: any SQLDialect
    ) -> String {
        let target = qualifiedName(table: table, schema: schema, dialect: dialect)
        return "SELECT count(*) FROM \(target);"
    }

    /// 生成 INSERT 模板（列名齐全、值为占位符）（FR-DATA-03）。
    public static func insertTemplate(
        table: String,
        columns: [String],
        schema: String? = nil,
        dialect: any SQLDialect
    ) -> String {
        let target = qualifiedName(table: table, schema: schema, dialect: dialect)
        guard !columns.isEmpty else {
            return "INSERT INTO \(target) DEFAULT VALUES;"
        }
        let columnList = columns.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        return "INSERT INTO \(target) (\(columnList)) VALUES (\(placeholders));"
    }

    /// 生成 SELECT 模板（按列名列出）（FR-DATA-03）。
    public static func selectTemplate(
        table: String,
        columns: [String],
        schema: String? = nil,
        dialect: any SQLDialect
    ) -> String {
        let target = qualifiedName(table: table, schema: schema, dialect: dialect)
        let columnList = columns.isEmpty
            ? "*"
            : columns.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")
        return "SELECT \(columnList) FROM \(target);"
    }

    /// 依据列定义生成 `CREATE TABLE`（FR-DDL-01）。
    ///
    /// 只覆盖「列名 + 类型 + 是否可空」这三项最基本的信息：
    /// 主键、默认值、约束、索引需要更完整的元数据，当前不做（见任务清单）。
    public static func createTable(
        table: String,
        columns: [ColumnMeta],
        schema: String? = nil,
        dialect: any SQLDialect
    ) -> String {
        let target = qualifiedName(table: table, schema: schema, dialect: dialect)
        guard !columns.isEmpty else {
            return "CREATE TABLE \(target) ();"
        }

        let definitions = columns.map { column -> String in
            var definition = "\(dialect.quoteIdentifier(column.name)) \(column.typeName)"
            if !column.isNullable {
                definition += " NOT NULL"
            }
            return definition
        }

        return "CREATE TABLE \(target) (\n    " + definitions.joined(separator: ",\n    ") + "\n);"
    }

    /// 生成 `DROP TABLE`（带 `IF EXISTS`，避免手滑报错中断脚本）（FR-DDL-02）。
    public static func dropTable(
        table: String,
        schema: String? = nil,
        ifExists: Bool = true,
        dialect: any SQLDialect
    ) -> String {
        let target = qualifiedName(table: table, schema: schema, dialect: dialect)
        return "DROP TABLE \(ifExists ? "IF EXISTS " : "")\(target);"
    }

    /// 生成 `TRUNCATE TABLE`（FR-DDL-02）。
    public static func truncateTable(
        table: String,
        schema: String? = nil,
        dialect: any SQLDialect
    ) -> String {
        let target = qualifiedName(table: table, schema: schema, dialect: dialect)
        return "TRUNCATE TABLE \(target);"
    }

    /// 执行计划语句（FR-DIAG-01）。
    ///
    /// - `analyze = true` 会**真正执行**语句（含 DML 的写操作），
    ///   因此调用方必须在界面上明确提示；`false` 只做解析与规划。
    /// - `formatJSON = true` 用于 PG 的 `FORMAT JSON`（便于结构化展示计划树）；
    ///   GBase 不支持该选项，会自动降级为普通 `EXPLAIN`。
    public static func explain(
        sql: String,
        analyze: Bool = false,
        buffers: Bool = false,
        formatJSON: Bool = false,
        dialect: any SQLDialect
    ) -> String {
        let statement = trimTrailingSemicolon(sql)
        guard dialect.featureSet.contains(.supportsExplain) else {
            return "EXPLAIN \(statement);"
        }

        var options: [String] = []
        if analyze { options.append("ANALYZE") }
        if buffers, dialect.databaseType == .postgresql { options.append("BUFFERS") }
        if formatJSON, dialect.databaseType == .postgresql { options.append("FORMAT JSON") }

        guard !options.isEmpty else {
            return "EXPLAIN \(statement);"
        }
        return "EXPLAIN (\(options.joined(separator: ", "))) \(statement);"
    }

    /// `schema.table` / `table`，两端都按方言引用（FR-DATA-01）。
    public static func qualifiedName(
        table: String,
        schema: String?,
        dialect: any SQLDialect
    ) -> String {
        guard let schema, !schema.isEmpty, dialect.featureSet.contains(.supportsSchemas) else {
            return dialect.quoteIdentifier(table)
        }
        return "\(dialect.quoteIdentifier(schema)).\(dialect.quoteIdentifier(table))"
    }

    /// 去掉结尾的分号与空白：把「编辑器里的一整条语句」安全地嵌进 `EXPLAIN (...)`。
    static func trimTrailingSemicolon(_ sql: String) -> String {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - 库级管理（FR-SESS-05）

    /// `ALTER DATABASE` 的可改项（FR-SESS-05）。
    ///
    /// PostgreSQL 把「改属主」与「改选项 / 参数」分成不同语句形，因此本类型允许多项并存，
    /// 生成时拆成多条语句（由 `StatementSplitter` 逐条执行）。全部字段为空即视为「无改动」。
    public struct DatabaseAlterations: Equatable, Sendable {
        /// 新属主（角色名）。
        public var owner: String?
        /// 连接数上限；`-1` 表示不限。
        public var connectionLimit: Int?
        /// 是否允许连接。
        public var allowConnections: Bool?
        /// 库级参数名（如 `search_path`）。
        public var parameterName: String?
        /// 库级参数值（数字 / 布尔裸写，其余加引号转义）。
        public var parameterValue: String?

        public init(
            owner: String? = nil,
            connectionLimit: Int? = nil,
            allowConnections: Bool? = nil,
            parameterName: String? = nil,
            parameterValue: String? = nil
        ) {
            self.owner = owner
            self.connectionLimit = connectionLimit
            self.allowConnections = allowConnections
            self.parameterName = parameterName
            self.parameterValue = parameterValue
        }

        /// 是否没有任何可执行的改动。
        public var isEmpty: Bool {
            owner == nil && connectionLimit == nil && allowConnections == nil
                && parameterName == nil && parameterValue == nil
        }
    }

    /// 生成 `ALTER DATABASE`（FR-SESS-05）。
    ///
    /// - 返回 `nil` 的情形：方言非 PostgreSQL（GBase 的 `ALTER DATABASE` 选项集不同）、
    ///   库名 / 属主名 / 参数名非法、连接数小于 `-1`、参数名与值只给了一个、或没有任何改动。
    ///   采用「全有或全无」：任一字段非法即整条不生成，避免界面拿着一半合法一半非法的语句去执行。
    /// - 属主与选项 / 参数无法合成一条语句，因此返回值可能含多行（每行一条语句，以 `;` 结尾）。
    public static func alterDatabase(
        name: String,
        alterations: DatabaseAlterations,
        dialect: any SQLDialect
    ) -> String? {
        guard dialect.databaseType == .postgresql else { return nil }
        guard PrivilegeProbe.isValidDatabaseName(name), !alterations.isEmpty else { return nil }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = dialect.quoteIdentifier(trimmedName)
        var statements: [String] = []

        if let owner = alterations.owner {
            let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
            guard PrivilegeProbe.isValidRoleName(trimmedOwner) else { return nil }
            statements.append("ALTER DATABASE \(target) OWNER TO \(dialect.quoteIdentifier(trimmedOwner));")
        }

        var options: [String] = []
        if let limit = alterations.connectionLimit {
            guard limit >= -1 else { return nil }
            options.append("CONNECTION LIMIT \(limit)")
        }
        if let allow = alterations.allowConnections {
            options.append("ALLOW_CONNECTIONS \(allow ? "true" : "false")")
        }
        if !options.isEmpty {
            statements.append("ALTER DATABASE \(target) WITH " + options.joined(separator: " ") + ";")
        }

        if alterations.parameterName != nil || alterations.parameterValue != nil {
            guard let rawName = alterations.parameterName,
                  let rawValue = alterations.parameterValue,
                  PrivilegeProbe.isValidSettingName(rawName)
            else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            statements.append("ALTER DATABASE \(target) SET \(name) TO \(settingLiteral(rawValue));")
        }

        guard !statements.isEmpty else { return nil }
        return statements.joined(separator: "\n")
    }

    /// 生成 `DROP DATABASE`（FR-SESS-05）。
    ///
    /// **不可回滚且会删除库内全部对象**，调用方必须二次确认；`ifExists` 默认 `true`，
    /// 避免「库不存在」直接中断脚本。库名非法时返回 `nil`。
    public static func dropDatabase(
        name: String,
        ifExists: Bool = true,
        dialect: any SQLDialect
    ) -> String? {
        guard PrivilegeProbe.isValidDatabaseName(name) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "DROP DATABASE \(ifExists ? "IF EXISTS " : "")\(dialect.quoteIdentifier(trimmed));"
    }

    // MARK: - 索引与约束（FR-DDL-03 扩写）

    /// 参照动作（外键的 `ON DELETE` / `ON UPDATE`）。
    public enum ReferentialAction: String, Sendable, CaseIterable {
        case cascade = "CASCADE"
        case restrict = "RESTRICT"
        case setNull = "SET NULL"
        case setDefault = "SET DEFAULT"
        case noAction = "NO ACTION"
    }

    /// 索引定义。
    public struct IndexDefinition: Equatable, Sendable {
        public var name: String
        public var table: String
        public var schema: String?
        /// 索引列（按顺序）。
        public var columns: [String]
        public var isUnique: Bool
        /// 索引方法：btree / hash / gist / gin / brin / spgist；nil = 用默认 btree。
        public var method: String?
        /// 部分索引的 `WHERE` 条件（原样拼入，拒绝含 `;` 以免堆叠语句）。
        public var whereClause: String?
        /// `CONCURRENTLY`：不锁表建索引（不能在事务块中执行）。
        public var concurrently: Bool

        public init(
            name: String,
            table: String,
            schema: String? = nil,
            columns: [String],
            isUnique: Bool = false,
            method: String? = nil,
            whereClause: String? = nil,
            concurrently: Bool = false
        ) {
            self.name = name
            self.table = table
            self.schema = schema
            self.columns = columns
            self.isUnique = isUnique
            self.method = method
            self.whereClause = whereClause
            self.concurrently = concurrently
        }
    }

    /// 允许的索引方法白名单。
    static let allowedIndexMethods: Set<String> = ["btree", "hash", "gist", "gin", "brin", "spgist"]

    /// 生成 `CREATE INDEX`（FR-DDL-03 扩写）；输入非法返回 `nil`。
    public static func createIndex(_ index: IndexDefinition, dialect: any SQLDialect) -> String? {
        guard PrivilegeProbe.isValidIdentifier(index.name),
              let table = qualifiedNameChecked(table: index.table, schema: index.schema, dialect: dialect),
              !index.columns.isEmpty,
              index.columns.allSatisfy({ PrivilegeProbe.isValidIdentifier($0) })
        else { return nil }

        var method = ""
        if let raw = index.method {
            let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard allowedIndexMethods.contains(normalized) else { return nil }
            method = " USING \(normalized)"
        }

        var wherePart = ""
        if let raw = index.whereClause {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard !trimmed.contains(";") else { return nil }
                wherePart = " WHERE \(trimmed)"
            }
        }

        let unique = index.isUnique ? "UNIQUE " : ""
        let concurrently = index.concurrently ? "CONCURRENTLY " : ""
        let name = dialect.quoteIdentifier(trimmedSQLIdentifier(index.name))
        let columns = index.columns.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")
        return "CREATE \(unique)INDEX \(concurrently)\(name) ON \(table)\(method) (\(columns))\(wherePart);"
    }

    /// 生成 `DROP INDEX`；输入非法返回 `nil`。
    public static func dropIndex(
        name: String,
        schema: String? = nil,
        ifExists: Bool = true,
        concurrently: Bool = false,
        dialect: any SQLDialect
    ) -> String? {
        guard let target = qualifiedNameChecked(table: name, schema: schema, dialect: dialect) else { return nil }
        let concurrentlyPart = concurrently ? "CONCURRENTLY " : ""
        let ifExistsPart = ifExists ? "IF EXISTS " : ""
        return "DROP INDEX \(concurrentlyPart)\(ifExistsPart)\(target);"
    }

    /// 外键定义。
    public struct ForeignKeyDefinition: Equatable, Sendable {
        /// 约束名；nil = 交给数据库自动命名。
        public var name: String?
        public var table: String
        public var schema: String?
        public var columns: [String]
        public var referencedTable: String
        public var referencedSchema: String?
        public var referencedColumns: [String]
        public var onDelete: ReferentialAction?
        public var onUpdate: ReferentialAction?

        public init(
            name: String? = nil,
            table: String,
            schema: String? = nil,
            columns: [String],
            referencedTable: String,
            referencedSchema: String? = nil,
            referencedColumns: [String],
            onDelete: ReferentialAction? = nil,
            onUpdate: ReferentialAction? = nil
        ) {
            self.name = name
            self.table = table
            self.schema = schema
            self.columns = columns
            self.referencedTable = referencedTable
            self.referencedSchema = referencedSchema
            self.referencedColumns = referencedColumns
            self.onDelete = onDelete
            self.onUpdate = onUpdate
        }
    }

    /// 生成 `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY`（FR-DDL-03 扩写）；输入非法返回 `nil`。
    ///
    /// 两侧列数必须一致——列数不匹配的语句服务端一定报错，本地先拦掉更省事。
    public static func addForeignKey(_ definition: ForeignKeyDefinition, dialect: any SQLDialect) -> String? {
        guard let table = qualifiedNameChecked(table: definition.table, schema: definition.schema, dialect: dialect),
              let referenced = qualifiedNameChecked(
                  table: definition.referencedTable,
                  schema: definition.referencedSchema,
                  dialect: dialect
              ),
              !definition.columns.isEmpty,
              definition.columns.count == definition.referencedColumns.count,
              definition.columns.allSatisfy({ PrivilegeProbe.isValidIdentifier($0) }),
              definition.referencedColumns.allSatisfy({ PrivilegeProbe.isValidIdentifier($0) })
        else { return nil }

        var constraintName = ""
        if let name = definition.name {
            guard PrivilegeProbe.isValidIdentifier(name) else { return nil }
            constraintName = "CONSTRAINT \(dialect.quoteIdentifier(trimmedSQLIdentifier(name))) "
        }

        let columns = definition.columns.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")
        let referencedColumns = definition.referencedColumns.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")
        var actions = ""
        if let onDelete = definition.onDelete { actions += " ON DELETE \(onDelete.rawValue)" }
        if let onUpdate = definition.onUpdate { actions += " ON UPDATE \(onUpdate.rawValue)" }

        return "ALTER TABLE \(table) ADD \(constraintName)FOREIGN KEY (\(columns)) "
            + "REFERENCES \(referenced) (\(referencedColumns))\(actions);"
    }

    /// 生成 `ALTER TABLE … DROP CONSTRAINT`；输入非法返回 `nil`。
    public static func dropConstraint(
        name: String,
        table: String,
        schema: String? = nil,
        ifExists: Bool = true,
        cascade: Bool = false,
        dialect: any SQLDialect
    ) -> String? {
        guard PrivilegeProbe.isValidIdentifier(name),
              let target = qualifiedNameChecked(table: table, schema: schema, dialect: dialect)
        else { return nil }
        let ifExistsPart = ifExists ? "IF EXISTS " : ""
        let cascadePart = cascade ? " CASCADE" : ""
        return "ALTER TABLE \(target) DROP CONSTRAINT \(ifExistsPart)\(dialect.quoteIdentifier(trimmedSQLIdentifier(name)))\(cascadePart);"
    }

    // MARK: - 权限管理（FR-SESS-04）

    /// `GRANT` / `REVOKE` 的作用对象。
    public enum PrivilegeObject: Equatable, Sendable {
        case database(String)
        case schema(String)
        case table(schema: String?, name: String)
        case sequence(schema: String?, name: String)
        case allTablesInSchema(String)
        case allSequencesInSchema(String)
    }

    /// 一次权限变更。
    public struct PrivilegeChange: Equatable, Sendable {
        /// 权限关键字（大小写不敏感）；`ALL` 不能与其他关键字混用。
        public var privileges: [String]
        public var object: PrivilegeObject
        /// 被授权 / 回收的角色；`PUBLIC` 视为关键字（不加引号）。
        public var grantee: String
        /// `GRANT` → `WITH GRANT OPTION`；`REVOKE` → 只回收授权选项。
        public var withGrantOption: Bool

        public init(
            privileges: [String],
            object: PrivilegeObject,
            grantee: String,
            withGrantOption: Bool = false
        ) {
            self.privileges = privileges
            self.object = object
            self.grantee = grantee
            self.withGrantOption = withGrantOption
        }
    }

    /// 允许的权限关键字白名单：拒绝把任意文本拼进 SQL。
    static let allowedPrivileges: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER",
        "USAGE", "CREATE", "CONNECT", "TEMPORARY", "EXECUTE", "ALL"
    ]

    /// 生成 `GRANT`；输入非法返回 `nil`。
    public static func grant(_ change: PrivilegeChange, dialect: any SQLDialect) -> String? {
        guard let clause = privilegeClause(change, dialect: dialect),
              let grantee = granteeToken(change.grantee)
        else { return nil }
        let suffix = change.withGrantOption ? " WITH GRANT OPTION" : ""
        return "GRANT \(clause) TO \(grantee)\(suffix);"
    }

    /// 生成 `REVOKE`；`withGrantOption = true` 时只回收授权选项。
    public static func revoke(_ change: PrivilegeChange, dialect: any SQLDialect) -> String? {
        guard let clause = privilegeClause(change, dialect: dialect),
              let grantee = granteeToken(change.grantee)
        else { return nil }
        let option = change.withGrantOption ? "GRANT OPTION FOR " : ""
        return "REVOKE \(option)\(clause) FROM \(grantee);"
    }

    /// `<权限列表> ON <对象>`；任一字段非法即返回 `nil`（全有或全无）。
    static func privilegeClause(_ change: PrivilegeChange, dialect: any SQLDialect) -> String? {
        let privileges = change.privileges
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        guard !privileges.isEmpty, privileges.allSatisfy({ allowedPrivileges.contains($0) }) else { return nil }
        if privileges.contains("ALL"), privileges.count > 1 { return nil }
        guard let object = privilegeObjectToken(change.object, dialect: dialect) else { return nil }
        return "\(privileges.joined(separator: ", ")) ON \(object)"
    }

    /// 对象片段：标识符一律先校验再按方言引用。
    static func privilegeObjectToken(_ object: PrivilegeObject, dialect: any SQLDialect) -> String? {
        switch object {
        case .database(let name):
            guard PrivilegeProbe.isValidDatabaseName(name) else { return nil }
            return "DATABASE \(dialect.quoteIdentifier(trimmedSQLIdentifier(name)))"
        case .schema(let name):
            guard PrivilegeProbe.isValidIdentifier(name) else { return nil }
            return "SCHEMA \(dialect.quoteIdentifier(trimmedSQLIdentifier(name)))"
        case .table(let schema, let name):
            guard let target = qualifiedNameChecked(table: name, schema: schema, dialect: dialect) else { return nil }
            return "TABLE \(target)"
        case .sequence(let schema, let name):
            guard let target = qualifiedNameChecked(table: name, schema: schema, dialect: dialect) else { return nil }
            return "SEQUENCE \(target)"
        case .allTablesInSchema(let schema):
            guard PrivilegeProbe.isValidIdentifier(schema) else { return nil }
            return "ALL TABLES IN SCHEMA \(dialect.quoteIdentifier(trimmedSQLIdentifier(schema)))"
        case .allSequencesInSchema(let schema):
            guard PrivilegeProbe.isValidIdentifier(schema) else { return nil }
            return "ALL SEQUENCES IN SCHEMA \(dialect.quoteIdentifier(trimmedSQLIdentifier(schema)))"
        }
    }

    /// 被授权者：`PUBLIC` 为关键字（不加引号），其余必须是合法标识符。
    static func granteeToken(_ grantee: String) -> String? {
        let trimmed = grantee.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased() == "PUBLIC" { return "PUBLIC" }
        guard PrivilegeProbe.isValidRoleName(trimmed) else { return nil }
        return "\(dialectIndependentQuote(trimmed))"
    }

    /// 角色名统一用双引号（PostgreSQL 语义；GBase 的权限模型本期不接入）。
    static func dialectIndependentQuote(_ identifier: String) -> String {
        "\"\(identifier)\""
    }

    /// 与 `qualifiedName` 同义，但先校验标识符（非法返回 `nil`）。
    static func qualifiedNameChecked(table: String, schema: String?, dialect: any SQLDialect) -> String? {
        guard PrivilegeProbe.isValidIdentifier(table) else { return nil }
        if let schema, !schema.isEmpty {
            guard PrivilegeProbe.isValidIdentifier(schema) else { return nil }
            return qualifiedName(table: table, schema: schema, dialect: dialect)
        }
        return qualifiedName(table: table, schema: nil, dialect: dialect)
    }

    static func trimmedSQLIdentifier(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把库级参数值渲染成 SQL 字面量：数字与布尔 / 开关字面量裸写，其余加单引号并转义 `'`。
    static func settingLiteral(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if Double(trimmed) != nil { return trimmed }
        if ["true", "false", "on", "off"].contains(trimmed.lowercased()) { return trimmed.lowercased() }
        return "'" + trimmed.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
