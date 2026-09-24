import XCTest
@testable import DoyahCore

/// FR-DRV-08：GBase 8a 驱动的"离线可验"那一半。
///
/// **本机没有 GBase 实例，所以这里验的不是"能连上 GBase"** —— 那需要一个可达实例。
/// 验的是**我们这一侧的判决**：驱动接上了、方言是 GBase 的、以及"未实测的能力如实留空"
/// （宁可显示"影响行数未知"，也不拿客户端自己数的数字冒充服务端的）。
final class GBaseServiceTests: XCTestCase {

    private func makeConfig() -> ConnectionConfig {
        ConnectionConfig(
            name: "gbase",
            dbType: .gbase8a,
            host: "127.0.0.1",
            port: 5258,
            database: "testdb",
            username: "gbase",
            sslMode: .disable
        )
    }

    /// GBase 8a 不再返回"未实现"占位 —— 驱动已接上（协议族同 MySQL）。
    func testFactoryReturnsGBaseService() {
        let service = DatabaseServiceFactory.make(for: makeConfig(), password: nil)
        XCTAssertTrue(service is GBaseService)
        XCTAssertEqual(service.config.dbType, .gbase8a)
        XCTAssertEqual(service.config.port, 5258)
    }

    /// 方言是 GBase 的（不是顺手用了 MySQL 方言）：树形结构因此没有 schema 层，
    /// 建库权限探测也如实返回 nil（G-17：需要真实例验证 `SHOW GRANTS` 的解析）。
    func testDialectIsGBase() {
        let dialect = SQLDialectFactory.make(for: .gbase8a)
        XCTAssertTrue(dialect is GBaseDialect)
        XCTAssertEqual(dialect.databaseType, .gbase8a)
        XCTAssertNil(dialect.databaseCreationPrivilegeQuery())
        XCTAssertEqual(dialect.listTablesQuery(database: "db", schema: nil), "SHOW TABLES FROM `db`")
    }

    /// **能力缺失要留空，不许"顺手补上"**：GBase 的影响行数 / 自增 ID 会话函数**故意**没有实现
    /// （`ROW_COUNT()` 在 GBase 8a 上的语义未实测）。于是 GBase 上显示"影响行数未知"，
    /// 而 MySQL 上是服务端给的真实数字 —— 两条方言在这件事上的差异必须被钉住，
    /// 否则以后有人"顺手统一"就会在 GBase 上显示出编造的数字。
    func testSessionMetadataHonestyDiffersBetweenDialects() {
        XCTAssertNil(SQLDialectFactory.make(for: .gbase8a).sessionMetadataQuery())
        XCTAssertEqual(
            SQLDialectFactory.make(for: .mysql).sessionMetadataQuery(),
            "SELECT ROW_COUNT(), LAST_INSERT_ID()"
        )
    }

    /// 取消走 `KILL QUERY`（只断语句、不断连接），两条方言一致 —— 这是协议族共性，不是各自发挥。
    func testCancelStatementIsSharedWithinTheFamily() {
        for type in [DatabaseType.mysql, .gbase8a] {
            let dialect = SQLDialectFactory.make(for: type)
            XCTAssertEqual(dialect.cancelSessionStatement(pid: 77), "KILL QUERY 77")
            XCTAssertEqual(dialect.terminateSessionStatement(pid: 77), "KILL 77")
        }
    }

    /// MySQL 协议族的服务器级对象（用户 / 权限 / 表空间）共用一套 SQL。
    func testServerObjectDialectIsSharedWithinTheFamily() {
        XCTAssertTrue(ServerObjectDialectFactory.make(for: .mysql) is GBaseServerObjectDialect)
        XCTAssertTrue(ServerObjectDialectFactory.make(for: .gbase8a) is GBaseServerObjectDialect)
        XCTAssertTrue(ServerObjectDialectFactory.make(for: .postgresql) is PostgresServerObjectDialect)
    }

    /// 四层树（无 schema 层）：MySQL 协议族两类都走"数据库节点直接挂表"。
    func testMetadataTreeSkipsSchemaLayer() async throws {
        for type in [DatabaseType.mysql, .gbase8a] {
            let service = StubMetadataService()
            let metadata = MetadataService(
                service: service,
                dialect: SQLDialectFactory.make(for: type),
                databaseName: "testdb",
                serverLabel: "stub"
            )
            let children = try await metadata.loadChildren(
                of: DatabaseObject(id: "db:testdb", name: "testdb", kind: DatabaseObject.Kind.database)
            )
            XCTAssertFalse(
                children.contains { $0.kind == DatabaseObject.Kind.schema },
                "\(type) 的库节点下不该出现 schema 层"
            )
        }
    }
}

/// 只回一个空结果集的假服务：这条用例只关心"库节点下面挂的是什么类型的节点"。
private final class StubMetadataService: DatabaseService, @unchecked Sendable {
    let config = ConnectionConfig(name: "stub", dbType: .gbase8a, username: "stub")

    func connect() async throws -> ServerInfo {
        ServerInfo(version: "0", database: "stub", user: "stub")
    }

    func disconnect() async {}

    func execute(
        _ sql: String,
        options: QueryOptions,
        handle: ExecutionHandle
    ) -> AsyncThrowingStream<QueryEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.resultSet(QueryResult(columns: [], rows: [])))
            continuation.yield(.finished(QuerySummary(statementCount: 1, duration: 0)))
            continuation.finish()
        }
    }

    func cancel(_ handle: ExecutionHandle) async -> CancelOutcome { .notActive }
    func beginTransaction() async throws {}
    func commit() async throws {}
    func rollback() async throws {}
}
