import XCTest
@testable import PostgresClientCore

final class PostgresServiceTests: XCTestCase {
    func testPostgresConfigurationMapping() async throws {
        let config = ConnectionConfig(
            name: "本地 PostgreSQL",
            dbType: .postgresql,
            host: "127.0.0.1",
            port: 5432,
            database: "postgres",
            username: "postgres",
            sslMode: .disable,
            timeout: 5
        )

        let service = PostgresService(config: config, password: "secret")
        let postgresConfiguration = try await service.makePostgresConfiguration()

        XCTAssertEqual(postgresConfiguration.host, "127.0.0.1")
        XCTAssertEqual(postgresConfiguration.port, 5432)
        XCTAssertEqual(postgresConfiguration.username, "postgres")
        XCTAssertEqual(postgresConfiguration.database, "postgres")
        XCTAssertFalse(postgresConfiguration.tls.isAllowed)
    }

    func testEmptyDatabaseBecomesNil() async throws {
        let config = ConnectionConfig(
            name: "默认库",
            dbType: .postgresql,
            host: "db.local",
            port: 5433,
            database: "",
            username: "alex",
            sslMode: .disable,
            timeout: 3
        )

        let service = PostgresService(config: config, password: nil)
        let postgresConfiguration = try await service.makePostgresConfiguration()

        XCTAssertEqual(postgresConfiguration.host, "db.local")
        XCTAssertEqual(postgresConfiguration.port, 5433)
        XCTAssertNil(postgresConfiguration.database)
    }

    // MARK: - 影响行数判定（FR-EXEC-10 / R-01）

    func testDMLStatementsReportAffectedRows() {
        XCTAssertTrue(PostgresService.reportsAffectedRows("INSERT INTO t VALUES (1);"))
        XCTAssertTrue(PostgresService.reportsAffectedRows("insert into t values (1)"))
        XCTAssertTrue(PostgresService.reportsAffectedRows("  UPDATE t SET a = 1 WHERE b = 2"))
        XCTAssertTrue(PostgresService.reportsAffectedRows("DELETE FROM t WHERE id > 10"))
        XCTAssertTrue(PostgresService.reportsAffectedRows("-- 注释\nUPDATE t SET a = 1"))
        XCTAssertTrue(PostgresService.reportsAffectedRows("/* 块注释 */\nDELETE FROM t"))
    }

    func testNonDMLStatementsDoNotReportAffectedRows() {
        XCTAssertFalse(PostgresService.reportsAffectedRows("SELECT 1"))
        XCTAssertFalse(PostgresService.reportsAffectedRows("CREATE TABLE t (id int)"))
        XCTAssertFalse(PostgresService.reportsAffectedRows("TRUNCATE t"))
        XCTAssertFalse(PostgresService.reportsAffectedRows("WITH x AS (SELECT 1) SELECT * FROM x"))
        XCTAssertFalse(PostgresService.reportsAffectedRows(""))
    }

    func testReturningStatementsUseStreamingPath() {
        // 带 RETURNING 时列名来自流式结果，影响行数由结果本身体现。
        XCTAssertFalse(PostgresService.reportsAffectedRows("INSERT INTO t VALUES (1) RETURNING id"))
        XCTAssertFalse(PostgresService.reportsAffectedRows("update t set a = 1 returning a"))
    }

    /// 「update」出现在别处（例如字符串字面量）时不应误判为 DML。
    func testKeywordMustBeTheFirstToken() {
        XCTAssertFalse(PostgresService.reportsAffectedRows("SELECT 'update t set a = 1'"))
    }
}
