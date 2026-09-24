import XCTest
@testable import DoyahCore

/// 用假的 DatabaseService 验证 MetadataService 的层级与映射，
/// 不依赖真实数据库。
///
/// 结构：服务器 → 数据库 → schema(PG) → 表/视图 → 列
final class MetadataServiceTests: XCTestCase {

    // MARK: - 服务器根节点

    func testRootIsServerNode() async throws {
        let service = FakeDatabaseService { _ in nil }
        let metadata = MetadataService(
            service: service,
            dialect: PostgresDialect(),
            databaseName: "postgres",
            serverLabel: "本地 · 127.0.0.1:5432"
        )

        let roots = try await metadata.loadRoot()

        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].kind, .server)
        XCTAssertEqual(roots[0].name, "本地 · 127.0.0.1:5432")
        XCTAssertTrue(roots[0].isExpandable)
    }

    // MARK: - 服务器 → 数据库

    func testPostgresServerChildrenAreAccessibleDatabases() async throws {
        let service = FakeDatabaseService { sql in
            guard sql.contains("pg_database") else { return nil }
            return Self.result(["datname"], [["postgres"], ["appdb"]])
        }
        let metadata = MetadataService(service: service, dialect: PostgresDialect(), databaseName: "postgres")

        let server = DatabaseObject(id: "server", name: "server", kind: .server)
        let databases = try await metadata.loadChildren(of: server)

        XCTAssertEqual(databases.map(\.name), ["postgres", "appdb"])
        XCTAssertTrue(databases.allSatisfy { $0.kind == .database })
        XCTAssertEqual(databases.map(\.database), ["postgres", "appdb"])
        XCTAssertTrue(databases.allSatisfy { $0.isExpandable })
    }

    func testPostgresDatabaseQueryFiltersByConnectPrivilege() {
        let sql = PostgresDialect().listDatabasesQuery()

        XCTAssertTrue(sql.contains("pg_database"))
        XCTAssertTrue(sql.contains("datistemplate = false"))
        XCTAssertTrue(sql.contains("has_database_privilege(current_user, datname, 'CONNECT')"))
    }

    // MARK: - 数据库 → schema

    func testPostgresDatabaseChildrenAreSchemasAndFilterSystemSchemas() async throws {
        let service = FakeDatabaseService { sql in
            guard sql.contains("information_schema.schemata") else { return nil }
            return Self.result(["schema_name"], [
                ["public"],
                ["app"],
                ["information_schema"],
                ["pg_catalog"],
                ["pg_toast"],
                ["pg_temp_1"]
            ])
        }
        let metadata = MetadataService(service: service, dialect: PostgresDialect(), databaseName: "postgres")

        let database = DatabaseObject(id: "db:postgres", name: "postgres", kind: .database, database: "postgres")
        let schemas = try await metadata.loadChildren(of: database)

        XCTAssertEqual(schemas.map(\.name), ["public", "app"])
        XCTAssertTrue(schemas.allSatisfy { $0.kind == .schema })
        XCTAssertEqual(schemas.map(\.database), ["postgres", "postgres"])
        XCTAssertEqual(schemas.map(\.schema), ["public", "app"])
    }

    // MARK: - schema → 表 / 视图

    func testPostgresSchemaChildrenMapTableAndViewKinds() async throws {
        let service = FakeDatabaseService { sql in
            guard sql.contains("information_schema.tables") else { return nil }
            return Self.result(["table_name", "table_type"], [
                ["users", "BASE TABLE"],
                ["user_summary", "VIEW"]
            ])
        }
        let metadata = MetadataService(service: service, dialect: PostgresDialect(), databaseName: "postgres")

        let schema = DatabaseObject(
            id: "db:postgres|schema:public",
            name: "public",
            kind: .schema,
            database: "postgres",
            schema: "public"
        )
        let tables = try await metadata.loadChildren(of: schema)

        XCTAssertEqual(tables.map(\.name), ["users", "user_summary"])
        XCTAssertEqual(tables.map(\.kind), [.table, .view])
        XCTAssertTrue(tables.allSatisfy { $0.database == "postgres" && $0.schema == "public" })
    }

    // MARK: - 表 → 列

    func testPostgresTableChildrenReturnColumnsWithTypes() async throws {
        let service = FakeDatabaseService { sql in
            guard sql.contains("information_schema.columns") else { return nil }
            return Self.result(["column_name", "data_type", "is_nullable", "column_default"], [
                ["id", "integer", "NO", nil],
                ["name", "text", "YES", nil]
            ])
        }
        let metadata = MetadataService(service: service, dialect: PostgresDialect(), databaseName: "postgres")

        let table = DatabaseObject(
            id: "db:postgres|schema:public|table:users",
            name: "users",
            kind: .table,
            database: "postgres",
            schema: "public"
        )
        let columns = try await metadata.loadChildren(of: table)

        XCTAssertEqual(columns.map(\.name), ["id", "name"])
        XCTAssertEqual(columns.map(\.detail), ["integer", "text"])
        XCTAssertTrue(columns.allSatisfy { $0.kind == .column })
        XCTAssertFalse(columns[0].isExpandable)
    }

    func testEmptySchemaReturnsEmptyChildren() async throws {
        let service = FakeDatabaseService { sql in
            guard sql.contains("information_schema.tables") else { return nil }
            return Self.result(["table_name", "table_type"], [])
        }
        let metadata = MetadataService(service: service, dialect: PostgresDialect(), databaseName: "postgres")

        let schema = DatabaseObject(
            id: "db:postgres|schema:empty_schema",
            name: "empty_schema",
            kind: .schema,
            database: "postgres",
            schema: "empty_schema"
        )
        let children = try await metadata.loadChildren(of: schema)

        XCTAssertTrue(children.isEmpty)
    }

    // MARK: - GBase

    func testGBaseServerChildrenAreDatabases() async throws {
        let config = ConnectionConfig(
            name: "GBase",
            dbType: .gbase8a,
            host: "127.0.0.1",
            port: 5258,
            database: "test",
            username: "gbase",
            sslMode: .disable,
            timeout: 5
        )
        let service = FakeDatabaseService(config: config) { sql in
            guard sql.uppercased().contains("SHOW DATABASES") else { return nil }
            return Self.result(["Database"], [["gbase"], ["test"]])
        }
        let metadata = MetadataService(service: service, dialect: GBaseDialect(), databaseName: "test")

        let server = DatabaseObject(id: "server", name: "server", kind: .server)
        let databases = try await metadata.loadChildren(of: server)

        XCTAssertEqual(databases.map(\.name), ["gbase", "test"])
        XCTAssertTrue(databases.allSatisfy { $0.kind == .database })
    }

    /// **GBase 没有 schema 层**：数据库节点的子节点直接是表 / 视图。
    ///
    /// 这条分支此前**没有任何单测**（FR-META-02 的取证结论），而它恰恰是"GBase 树与 PG 树不一样"
    /// 的唯一实现处 —— 没有实例也能用假服务把它钉住；有实例时要验的只是"服务端真的返回这些列"。
    func testGBaseDatabaseChildrenAreTablesWithoutSchemaLayer() async throws {
        let config = ConnectionConfig(
            name: "GBase", dbType: .gbase8a, host: "127.0.0.1", port: 5258,
            database: "test", username: "gbase", sslMode: .disable, timeout: 5
        )
        var issued: [String] = []
        let service = FakeDatabaseService(config: config) { sql in
            issued.append(sql)
            guard sql.uppercased().contains("SHOW TABLES") else { return nil }
            return Self.result(["Tables_in_test"], [["orders"], ["v_orders"]])
        }
        let metadata = MetadataService(service: service, dialect: GBaseDialect(), databaseName: "test")

        let database = DatabaseObject(id: "db:test", name: "test", kind: .database, database: "test")
        let children = try await metadata.loadChildren(of: database)

        XCTAssertEqual(children.count, 2)
        XCTAssertTrue(children.allSatisfy { $0.kind != .schema }, "GBase 不该出现 schema 节点")
        XCTAssertTrue(children.allSatisfy { $0.database == "test" })
        XCTAssertTrue(children.allSatisfy { $0.schema == nil }, "没有 schema 层，schema 就应当是空")
        XCTAssertEqual(children.map(\.name), ["orders", "v_orders"])
        XCTAssertTrue(issued.contains { $0.contains("SHOW TABLES FROM `test`") }, "应当走 SHOW TABLES FROM：\(issued)")
    }

    /// `SHOW TABLES` 只有一列（没有类型列）：不能因此把视图当成表，也不能把表当成视图 ——
    /// 默认按表处理（GBase 8a 的视图名约束与 PG 不同，这里不猜）。
    func testGBaseTableKindsDefaultToTableWithoutTypeColumn() async throws {
        let config = ConnectionConfig(
            name: "GBase", dbType: .gbase8a, host: "127.0.0.1", port: 5258,
            database: "test", username: "gbase", sslMode: .disable, timeout: 5
        )
        let service = FakeDatabaseService(config: config) { sql in
            guard sql.uppercased().contains("SHOW TABLES") else { return nil }
            return Self.result(["Tables_in_test"], [["orders"]])
        }
        let metadata = MetadataService(service: service, dialect: GBaseDialect(), databaseName: "test")
        let children = try await metadata.loadChildren(
            of: DatabaseObject(id: "db:test", name: "test", kind: .database, database: "test")
        )
        XCTAssertEqual(children.first?.kind, .table)
    }

    /// 表节点的子节点是列（`DESC <表>`），列上带类型；GBase 的列不继承 schema。
    func testGBaseTableChildrenAreColumnsWithTypes() async throws {
        let config = ConnectionConfig(
            name: "GBase", dbType: .gbase8a, host: "127.0.0.1", port: 5258,
            database: "test", username: "gbase", sslMode: .disable, timeout: 5
        )
        var issued: [String] = []
        let service = FakeDatabaseService(config: config) { sql in
            issued.append(sql)
            guard sql.uppercased().hasPrefix("DESC") else { return nil }
            return Self.result(
                ["Field", "Type", "Null", "Key", "Default", "Extra"],
                [["id", "int(11)", "NO", "PRI", nil, ""], ["name", "varchar(64)", "YES", nil, nil, ""]]
            )
        }
        let metadata = MetadataService(service: service, dialect: GBaseDialect(), databaseName: "test")
        let table = DatabaseObject(
            id: "db:test|schema:|table:orders", name: "orders", kind: .table, database: "test", schema: nil
        )
        let columns = try await metadata.loadChildren(of: table)

        XCTAssertEqual(columns.map(\.name), ["id", "name"])
        XCTAssertTrue(columns.allSatisfy { $0.kind == .column })
        XCTAssertEqual(columns.first?.detail, "int(11)", "列上要带类型")
        XCTAssertTrue(columns.allSatisfy { $0.schema == nil }, "GBase 的列不该凭空长出 schema")
        XCTAssertTrue(issued.contains { $0.uppercased().hasPrefix("DESC") }, "应当走 DESC：\(issued)")
    }

    /// **对照**：同一份"数据库"节点，PG 方言给的是 schema，GBase 方言给的是表 ——
    /// 层级差异是**方言驱动**的，不是写死在树里的。
    func testHierarchyDifferenceIsDialectDriven() async throws {
        let pgConfig = ConnectionConfig(
            name: "PG", dbType: .postgresql, host: "127.0.0.1", port: 5432,
            database: "postgres", username: "postgres", sslMode: .disable, timeout: 5
        )
        let pgService = FakeDatabaseService(config: pgConfig) { sql in
            guard sql.contains("information_schema.schemata") else { return nil }
            return Self.result(["schema_name"], [["public"], ["information_schema"]])
        }
        let pgMetadata = MetadataService(service: pgService, dialect: PostgresDialect(), databaseName: "postgres")
        let pgChildren = try await pgMetadata.loadChildren(
            of: DatabaseObject(id: "db:postgres", name: "postgres", kind: .database, database: "postgres")
        )
        XCTAssertTrue(pgChildren.allSatisfy { $0.kind == .schema }, "PG 的下一层是 schema")
        XCTAssertFalse(pgChildren.contains { $0.name == "information_schema" }, "系统 schema 要过滤掉")

        let gbaseConfig = ConnectionConfig(
            name: "GBase", dbType: .gbase8a, host: "127.0.0.1", port: 5258,
            database: "test", username: "gbase", sslMode: .disable, timeout: 5
        )
        let gbaseService = FakeDatabaseService(config: gbaseConfig) { sql in
            guard sql.uppercased().contains("SHOW TABLES") else { return nil }
            return Self.result(["Tables_in_test"], [["orders"]])
        }
        let gbaseMetadata = MetadataService(service: gbaseService, dialect: GBaseDialect(), databaseName: "test")
        let gbaseChildren = try await gbaseMetadata.loadChildren(
            of: DatabaseObject(id: "db:test", name: "test", kind: .database, database: "test")
        )
        XCTAssertTrue(gbaseChildren.allSatisfy { $0.kind == .table }, "GBase 的下一层是表")
    }

    // MARK: - Helpers

    private static func result(_ columns: [String], _ rows: [[String?]]) -> QueryResult {
        QueryResult(
            columns: columns.enumerated().map { ColumnMeta(id: $0.offset, name: $0.element) },
            rows: rows
        )
    }
}

/// 测试用假服务：按 SQL 片段返回预置结果。
final class FakeDatabaseService: DatabaseService, @unchecked Sendable {
    let config: ConnectionConfig
    private let resolver: @Sendable (String) -> QueryResult?

    init(
        config: ConnectionConfig = ConnectionConfig(
            name: "fake",
            dbType: .postgresql,
            host: "127.0.0.1",
            port: 5432,
            database: "postgres",
            username: "postgres",
            sslMode: .disable,
            timeout: 5
        ),
        resolver: @escaping @Sendable (String) -> QueryResult?
    ) {
        self.config = config
        self.resolver = resolver
    }

    func connect() async throws -> ServerInfo {
        ServerInfo(version: "16.2", database: config.database, user: config.username)
    }

    func disconnect() async {}

    /// 假驱动不模拟服务端取消：如实回答"没有在执行"，而不是假装取消成功。
    func cancel(_ handle: ExecutionHandle) async -> CancelOutcome { .notActive }

    func beginTransaction() async throws {}
    func commit() async throws {}
    func rollback() async throws {}

    func execute(
        _ sql: String,
        options: QueryOptions,
        handle: ExecutionHandle
    ) -> AsyncThrowingStream<QueryEvent, Error> {
        AsyncThrowingStream { continuation in
            if let result = resolver(sql) {
                continuation.yield(.resultSet(result))
            }
            continuation.yield(.finished(QuerySummary(statementCount: 1, duration: 0)))
            continuation.finish()
        }
    }
}
