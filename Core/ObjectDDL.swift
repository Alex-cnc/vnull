import Foundation

/// 取对象的 DDL（FR-META-13）。
///
/// 表走的是"读列 + 拼装"的老路（`SQLGenerator.createTableDDL`）—— 那条路只能还原列与可空性，
/// **视图与函数还原不了**：视图的定义体、函数的完整源码都只存在于服务端元数据里，
/// 必须由服务端给出（PG 的 `pg_get_viewdef` / `pg_get_functiondef`，GBase 的 `SHOW CREATE`）。
///
/// 因此这里把"查什么"和"拿到结果怎么装配"分开：
/// - `sql`：要执行的元数据查询；
/// - `assembly`：结果是完整 DDL，还是需要包一层 `CREATE OR REPLACE VIEW`。
public struct ObjectDDLQuery: Equatable, Sendable {

    /// 结果的装配方式。
    public enum Assembly: Equatable, Sendable {
        /// 结果本身就是完整 DDL（`pg_get_functiondef` / `SHOW CREATE …`）。
        case asIs
        /// 结果是**视图定义体**，需要包成 `CREATE OR REPLACE VIEW <限定名> AS <body>`。
        case wrapView(schema: String?, name: String)
    }

    public var sql: String
    public var assembly: Assembly
    /// 从结果里优先取哪几列（按列名，大小写不敏感）；都找不到时退回第一个非空列。
    ///
    /// 为什么不硬编码一个列名：PG 与 GBase 的列名不同（`function_definition` / `Create Function`），
    /// 硬编码意味着每接一个方言就要改一次装配代码。
    public var preferredColumns: [String]

    public init(sql: String, assembly: Assembly, preferredColumns: [String]) {
        self.sql = sql
        self.assembly = assembly
        self.preferredColumns = preferredColumns
    }
}

public enum ObjectDDL {

    /// 视图 DDL 查询；方言不支持时返回 nil（界面据此不呈现该项，而不是给一句看不懂的报错）。
    public static func view(schema: String?, name: String, dialect: any SQLDialect) -> ObjectDDLQuery? {
        guard let sql = dialect.viewDDLQuery(view: name, schema: schema) else { return nil }
        return ObjectDDLQuery(
            sql: sql,
            assembly: .wrapView(schema: schema, name: name),
            preferredColumns: ["view_definition", "Create View", "create view", "ddl"]
        )
    }

    /// 函数 DDL 查询；方言不支持时返回 nil。
    public static func function(schema: String?, name: String, dialect: any SQLDialect) -> ObjectDDLQuery? {
        guard let sql = dialect.functionDDLQuery(function: name, schema: schema) else { return nil }
        return ObjectDDLQuery(
            sql: sql,
            assembly: .asIs,
            preferredColumns: ["function_definition", "Create Function", "create function", "ddl"]
        )
    }

    /// 把查询结果装配成最终 DDL 文本。
    ///
    /// - 多行结果（**同名函数的重载**）会按顺序拼接：每个重载都是一条独立的 `CREATE OR REPLACE FUNCTION`，
    ///   丢掉任何一个都会让人以为"这函数只有一种签名"。空行分隔，便于直接粘进编辑器。
    /// - 结果为空 / 全空列时返回 nil，由调用方给出可读提示。
    public static func assemble(
        _ query: ObjectDDLQuery,
        columns: [String],
        rows: [[String?]],
        dialect: any SQLDialect
    ) -> String? {
        let index = columnIndex(for: query, columns: columns)
        let bodies = rows.compactMap { row -> String? in
            guard row.indices.contains(index), let value = row[index] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !bodies.isEmpty else { return nil }

        switch query.assembly {
        case .asIs:
            return bodies.joined(separator: "\n\n")

        case .wrapView(let schema, let name):
            let target = SQLGenerator.qualifiedName(table: name, schema: schema, dialect: dialect)
            return bodies.map { body -> String in
                // `pg_get_viewdef(..., true)` 的返回值自带结尾分号；再补一个就成了两条语句。
                let definition = body.hasSuffix(";") ? String(body.dropLast()) : body
                return "CREATE OR REPLACE VIEW \(target) AS\n\(definition);"
            }
            .joined(separator: "\n\n")
        }
    }

    /// 优先列 → 后备（第一个出现的列）。
    private static func columnIndex(for query: ObjectDDLQuery, columns: [String]) -> Int {
        let lowered = columns.map { $0.lowercased() }
        for preferred in query.preferredColumns {
            if let index = lowered.firstIndex(of: preferred.lowercased()) {
                return index
            }
        }
        return 0
    }
}
