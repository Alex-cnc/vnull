import XCTest
@testable import PostgresClientCore

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

    func cancel() async {}

    func beginTransaction() async throws {}
    func commit() async throws {}
    func rollback() async throws {}

    func execute(_ sql: String, options: QueryOptions) -> AsyncThrowingStream<QueryEvent, Error> {
        AsyncThrowingStream { continuation in
            if let result = resolver(sql) {
                continuation.yield(.resultSet(result))
            }
            continuation.yield(.finished(QuerySummary(statementCount: 1, duration: 0)))
            continuation.finish()
        }
    }
}
