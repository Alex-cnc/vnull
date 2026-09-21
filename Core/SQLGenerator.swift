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
}
