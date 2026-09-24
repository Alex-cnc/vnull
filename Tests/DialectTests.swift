import XCTest
@testable import DoyahCore

final class DialectTests: XCTestCase {
    func testPostgresDialectBasics() {
        let dialect = PostgresDialect()

        XCTAssertEqual(dialect.quoteIdentifier("user"), "\"user\"")
        XCTAssertEqual(dialect.quoteIdentifier("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(dialect.limitClause(offset: 5, count: 10), "LIMIT 10 OFFSET 5")
        XCTAssertEqual(dialect.currentDatabaseQuery(), "SELECT current_database()")
        XCTAssertTrue(dialect.featureSet.contains(.supportsSchemas))
    }

    func testGBaseDialectBasics() {
        let dialect = GBaseDialect()

        XCTAssertEqual(dialect.quoteIdentifier("user"), "`user`")
        XCTAssertEqual(dialect.limitClause(offset: 5, count: 10), "LIMIT 5, 10")
        XCTAssertEqual(dialect.currentDatabaseQuery(), "SELECT DATABASE()")
        XCTAssertTrue(dialect.featureSet.contains(.supportsCustomDelimiter))
        XCTAssertFalse(dialect.featureSet.contains(.supportsSchemas))
    }

    /// 全库对象搜索是**方言能力**（FR-META-12）：PG 给系统目录查询，其余方言明确返回 nil ——
    /// nil 会让界面说一句"该方言不支持"，而不是把 PG 口径的 SQL 丢过去换回一句 SQL 报错。
    func testObjectSearchIsDialectCapability() {
        let postgres = PostgresDialect()
        let query = postgres.objectSearchQuery(schema: "public", limit: 500)
        XCTAssertNotNil(query)
        XCTAssertTrue(query?.contains("public") == true, query ?? "")

        // GBase 8a 走 MySQL 协议，PG 的系统目录不适用 —— 不实现即不支持（协议扩展默认 nil）。
        XCTAssertNil(GBaseDialect().objectSearchQuery(schema: nil, limit: 500))
    }

    func testServerVersionParsing() {
        let postgres = PostgresDialect()
        let pgVersion = postgres.parseServerVersion("16.2")
        XCTAssertEqual(pgVersion.major, 16)
        XCTAssertEqual(pgVersion.minor, 2)

        let gbase = GBaseDialect()
        let gbaseVersion = gbase.parseServerVersion("8.6.2.11")
        XCTAssertEqual(gbaseVersion.major, 8)
        XCTAssertEqual(gbaseVersion.minor, 6)
        XCTAssertEqual(gbaseVersion.patch, 2)
    }
    /// 语句分隔符来自**方言**，不是界面写死的 —— 工具条右侧那串「PostgreSQL · 分隔符 ;」里，
    /// 「PostgreSQL」随连接类型变，「分隔符 x」随方言变（FR-EDIT-08）。
    ///
    /// 目前两种方言恰好都是 `;`，所以今天看不出差别；这条测试钉的是**取值来源**：
    /// 以后加方言（Oracle 的 `/`、MySQL 的自定义分隔符）时，界面会自动跟着变，
    /// 而不会出现"界面写着 `;`、实际按别的分隔符切语句"这种对不上的情况。
    func testStatementDelimiterComesFromDialect() {
        XCTAssertEqual(SQLDialectFactory.make(for: .postgresql).statementDelimiter, ";")
        XCTAssertEqual(SQLDialectFactory.make(for: .gbase8a).statementDelimiter, ";")
    }

}
