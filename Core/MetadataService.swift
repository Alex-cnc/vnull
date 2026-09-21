import Foundation

/// 元数据（对象树）服务。
///
/// 树形结构：
/// - PostgreSQL：服务器 → Database → Schema → Table / View → Column
/// - GBase 8a： 服务器 → Database → Table → Column
///
/// 重要约束：PostgreSQL 的 `information_schema` / `pg_catalog` 都是**每个数据库独立**的，
/// 不存在跨库查询。因此：
/// - 「服务器 → 数据库列表」用当前连接执行（服务器级查询，按当前用户 CONNECT 权限过滤）；
/// - 展开某个数据库时，调用方必须传入**连接到该数据库**的 `DatabaseService`，
///   再调用 `loadChildren(of:)`。
///
/// 严格遵循「协议层 / 方言层分离」：
/// - SQL 文本由 `SQLDialect` 生成；
/// - 传输由 `DatabaseService` 完成；
/// - 本类型只负责把查询结果行映射成 `DatabaseObject`。
public struct MetadataService: Sendable {
    public let service: any DatabaseService
    public let dialect: any SQLDialect
    /// 当前 `service` 所连接的数据库。
    public let databaseName: String
    /// 服务器节点显示名，一般是「连接名 · 地址」。
    public let serverLabel: String

    public init(
        service: any DatabaseService,
        dialect: any SQLDialect,
        databaseName: String,
        serverLabel: String = "数据库服务器"
    ) {
        self.service = service
        self.dialect = dialect
        self.databaseName = databaseName
        self.serverLabel = serverLabel
    }

    /// 根节点：服务器本身。
    public func loadRoot() async throws -> [DatabaseObject] {
        [
            DatabaseObject(
                id: "server",
                name: serverLabel,
                kind: .server
            )
        ]
    }

    public func loadChildren(of object: DatabaseObject) async throws -> [DatabaseObject] {
        switch object.kind {
        case .server:
            return try await loadDatabases()

        case .database:
            switch dialect.databaseType {
            case .postgresql:
                return try await loadSchemas(database: object.name)
            case .gbase8a:
                return try await loadTables(database: object.name, schema: nil)
            }

        case .schema:
            return try await loadTables(database: object.database ?? databaseName, schema: object.name)

        case .table, .view:
            return try await loadColumns(of: object)

        case .column, .function:
            return []
        }
    }

    // MARK: - 服务器 / 数据库

    /// 当前登录用户可连接的数据库（PG 按 `has_database_privilege` 过滤）。
    private func loadDatabases() async throws -> [DatabaseObject] {
        let result = try await run(dialect.listDatabasesQuery())
        return result.rows.compactMap { row in
            guard let name = value(row, at: 0) else { return nil }
            return DatabaseObject(
                id: "db:\(name)",
                name: name,
                kind: .database,
                database: name
            )
        }
    }

    private func loadSchemas(database: String) async throws -> [DatabaseObject] {
        let result = try await run(dialect.listSchemasQuery(database: database))
        return result.rows.compactMap { row in
            guard let name = value(row, at: 0), !isSystemSchema(name) else { return nil }
            return DatabaseObject(
                id: "db:\(database)|schema:\(name)",
                name: name,
                kind: .schema,
                database: database,
                schema: name
            )
        }
    }

    private func loadTables(database: String, schema: String?) async throws -> [DatabaseObject] {
        let result = try await run(dialect.listTablesQuery(database: database, schema: schema))
        return result.rows.compactMap { row in
            guard let name = value(row, at: 0) else { return nil }
            let typeName = value(row, at: 1)?.uppercased() ?? ""
            let kind: DatabaseObject.Kind = typeName.contains("VIEW") ? .view : .table
            return DatabaseObject(
                id: "db:\(database)|schema:\(schema ?? "")|\(kind.rawValue):\(name)",
                name: name,
                kind: kind,
                database: database,
                schema: schema
            )
        }
    }

    private func loadColumns(of object: DatabaseObject) async throws -> [DatabaseObject] {
        let schema = object.schema ?? (dialect.databaseType == .postgresql ? "public" : nil)
        let result = try await run(dialect.listColumnsQuery(table: object.name, schema: schema))
        return result.rows.compactMap { row in
            guard let name = value(row, at: 0) else { return nil }
            let typeName = value(row, at: 1)
            let detail = typeName?.isEmpty == false ? typeName : nil
            return DatabaseObject(
                id: "\(object.id)|column:\(name)",
                name: name,
                kind: .column,
                detail: detail,
                database: object.database,
                schema: object.schema
            )
        }
    }

    // MARK: - Helpers

    private func isSystemSchema(_ name: String) -> Bool {
        name == "information_schema" || name == "pg_catalog" || name.hasPrefix("pg_toast") || name.hasPrefix("pg_temp")
    }

    private func value(_ row: [String?], at index: Int) -> String? {
        guard row.indices.contains(index) else { return nil }
        guard let value = row[index], !value.isEmpty else { return nil }
        return value
    }

    private func run(_ sql: String) async throws -> QueryResult {
        var lastResult: QueryResult?
        let stream = service.execute(sql, options: QueryOptions(maxRows: 10_000))
        for try await event in stream {
            if case .resultSet(let result) = event {
                lastResult = result
            }
        }

        guard let lastResult else {
            throw AppError.queryFailed("元数据查询没有返回结果集")
        }
        return lastResult
    }
}
