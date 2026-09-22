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
}
