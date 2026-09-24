import XCTest
@testable import DoyahCore

/// FR-DRV-09：MySQL 方言与 `DatabaseType.mysql` 的契约测试。
///
/// **这些用例不需要实例**，验的是"我们这一侧的判决"：方言文本、类型映射、
/// 语句头判定、以及"MySQL 与 GBase 8a 共享同一份 SQL 文本，但不许悄悄漂移"。
final class MySQLDialectTests: XCTestCase {

    private let mysql = MySQLDialect()
    private let gbase = GBaseDialect()

    // MARK: - 方言与 GBase 8a 的一致性（转发关系的护栏）

    /// MySQL 方言**转发** `GBaseDialect` 的 MySQL 兼容部分。转发的风险是"两边慢慢不一样了"，
    /// 所以这里逐条比对文本 —— 一旦有人只改了一边，这条用例就会红。
    func testSharedQueriesMatchGBaseDialect() {
        XCTAssertEqual(mysql.listDatabasesQuery(), gbase.listDatabasesQuery())
        XCTAssertEqual(mysql.serverActivityQuery(), gbase.serverActivityQuery())
        XCTAssertEqual(mysql.cancelSessionStatement(pid: 42), gbase.cancelSessionStatement(pid: 42))
        XCTAssertEqual(mysql.terminateSessionStatement(pid: 42), gbase.terminateSessionStatement(pid: 42))
        XCTAssertEqual(mysql.serverVersionQuery(), gbase.serverVersionQuery())
        XCTAssertEqual(mysql.currentDatabaseQuery(), gbase.currentDatabaseQuery())
        XCTAssertEqual(
            mysql.listTablesQuery(database: "shop", schema: nil),
            gbase.listTablesQuery(database: "shop", schema: nil)
        )
        XCTAssertEqual(
            mysql.listColumnsQuery(table: "orders", schema: nil),
            gbase.listColumnsQuery(table: "orders", schema: nil)
        )
        XCTAssertEqual(mysql.keywords, gbase.keywords)
        XCTAssertEqual(mysql.quoteIdentifier("we`ird"), gbase.quoteIdentifier("we`ird"))
        XCTAssertEqual(mysql.limitClause(offset: 10, count: 20), gbase.limitClause(offset: 10, count: 20))
    }

    /// 唯一**故意不同**的一处：建库权限探测。MySQL 有 `mysql.user`，
    /// GBase 8a 上没有（那边返回 nil，G-17）—— 这条差异必须被钉住，否则以后有人"顺手统一"就错了。
    func testDatabaseCreationPrivilegeDiffersOnPurpose() throws {
        XCTAssertNil(gbase.databaseCreationPrivilegeQuery(), "GBase 上没有 mysql.user，应如实返回 nil")
        let query = try XCTUnwrap(mysql.databaseCreationPrivilegeQuery())
        XCTAssertTrue(query.contains("mysql.user"))
        XCTAssertTrue(query.uppercased().contains("CURRENT_USER()"))
    }

    func testIdentifierQuoteAndDelimiterAreMySQLLike() {
        XCTAssertEqual(mysql.identifierQuote, "`")
        XCTAssertEqual(mysql.statementDelimiter, ";")
        XCTAssertTrue(mysql.featureSet.contains(.supportsSSL))
        // MySQL 里 database 与 schema 同一件事，树形结构因此没有 schema 层。
        XCTAssertFalse(mysql.featureSet.contains(.supportsSchemas))
    }

    func testVersionParsingHandlesMySQLStyleStrings() {
        let version = mysql.parseServerVersion("8.0.36-log")
        XCTAssertEqual(version.major, 8)
        XCTAssertEqual(version.minor, 0)
        XCTAssertEqual(version.patch, 36)
        let mariadb = mysql.parseServerVersion("10.11.6-MariaDB")
        XCTAssertEqual(mariadb.major, 10)
        XCTAssertEqual(mariadb.minor, 11)
    }

    // MARK: - DatabaseType.mysql 的机械补分支

    func testDatabaseTypeMySQLDefaults() {
        XCTAssertEqual(DatabaseType.mysql.displayName, "MySQL")
        XCTAssertEqual(DatabaseType.mysql.defaultPort, 3306)
        XCTAssertEqual(DatabaseType.mysql.defaultSSLMode, .prefer)
        XCTAssertNil(DatabaseType.mysql.defaultSchema, "MySQL 的 database 就是 schema，没有默认 schema 层")
        XCTAssertNotEqual(DatabaseType.mysql.defaultPort, DatabaseType.postgresql.defaultPort)
    }

    func testFactoriesReturnMySQLImplementations() {
        XCTAssertTrue(SQLDialectFactory.make(for: .mysql) is MySQLDialect)
        XCTAssertEqual(SQLDialectFactory.make(for: .mysql).databaseType, .mysql)
        XCTAssertTrue(
            DatabaseServiceFactory.make(
                for: ConnectionConfig(name: "m", dbType: .mysql, username: "root"),
                password: nil
            ) is MySQLService
        )
    }

    /// GBase 8a 仍走"未实现"占位 —— **不要在没做之前把它顺手接上 MySQL 驱动**：
    /// 同一个协议族不代表同一个产品（方言、权限模型、`SHOW GRANTS` 的解析都还要各自验）。
    func testGBaseStillUsesNotImplementedService() {
        XCTAssertTrue(
            DatabaseServiceFactory.make(
                for: ConnectionConfig(name: "g", dbType: .gbase8a, username: "root"),
                password: nil
            ) is NotImplementedDatabaseService
        )
    }

    /// 会话心跳语句：MySQL 协议族用 `SELECT 1`（与 PG 一样轻，但走的是各自的方言入口）。
    func testKeepAliveStatement() {
        XCTAssertEqual(KeepAlivePolicy.statement(for: .mysql), "SELECT 1")
        XCTAssertEqual(KeepAlivePolicy.statement(for: .gbase8a), "SELECT 1")
    }

    // MARK: - 语句头判定（0 行的 SELECT 与 INSERT 不是一回事）

    func testReturnsRowsRecognisesQueries() {
        XCTAssertTrue(MySQLService.returnsRows("SELECT 1"))
        XCTAssertTrue(MySQLService.returnsRows("  select * from t"))
        XCTAssertTrue(MySQLService.returnsRows("SHOW TABLES"))
        XCTAssertTrue(MySQLService.returnsRows("DESC orders"))
        XCTAssertTrue(MySQLService.returnsRows("EXPLAIN SELECT 1"))
        XCTAssertTrue(MySQLService.returnsRows("WITH x AS (SELECT 1) SELECT * FROM x"))
        XCTAssertFalse(MySQLService.returnsRows("INSERT INTO t VALUES (1)"))
        XCTAssertFalse(MySQLService.returnsRows("UPDATE t SET a = 1"))
        XCTAssertFalse(MySQLService.returnsRows("CREATE TABLE t (a int)"))
    }

    func testReturnsRowsSkipsLeadingComments() {
        XCTAssertTrue(MySQLService.returnsRows("-- 注释\nSELECT 1"))
        XCTAssertTrue(MySQLService.returnsRows("/* 块注释 */ SELECT 1"))
        XCTAssertFalse(MySQLService.returnsRows("-- 只有注释"))
    }

    // MARK: - 类型名映射（界面显示要能对上 SQL 里的写法）

    func testTypeNamesUseSQLSpellingNotWireNames() {
        XCTAssertEqual(MySQLService.typeName(for: .longlong), "bigint")
        XCTAssertEqual(MySQLService.typeName(for: .long), "int")
        XCTAssertEqual(MySQLService.typeName(for: .short), "smallint")
        XCTAssertEqual(MySQLService.typeName(for: .tiny), "tinyint")
        XCTAssertEqual(MySQLService.typeName(for: .varString), "varchar")
        XCTAssertEqual(MySQLService.typeName(for: .newdecimal), "decimal")
        XCTAssertEqual(MySQLService.typeName(for: .datetime), "datetime")
    }
}
