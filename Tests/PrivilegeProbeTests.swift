import XCTest
@testable import PostgresClientCore

/// 建库权限探测与数据库名预校验（FR-META-11）。
final class PrivilegeProbeTests: XCTestCase {

    // MARK: - 权限解析（三态）

    func testParsesPostgresBooleanText() {
        XCTAssertEqual(PrivilegeProbe.databaseCreationAllowed(from: "t"), true)
        XCTAssertEqual(PrivilegeProbe.databaseCreationAllowed(from: "f"), false)
    }

    func testParsesCommonBooleanSpellings() {
        XCTAssertEqual(PrivilegeProbe.databaseCreationAllowed(from: "true"), true)
        XCTAssertEqual(PrivilegeProbe.databaseCreationAllowed(from: "YES"), true)
        XCTAssertEqual(PrivilegeProbe.databaseCreationAllowed(from: " on "), true)
        XCTAssertEqual(PrivilegeProbe.databaseCreationAllowed(from: "1"), true)
        XCTAssertEqual(PrivilegeProbe.databaseCreationAllowed(from: "false"), false)
        XCTAssertEqual(PrivilegeProbe.databaseCreationAllowed(from: "No"), false)
        XCTAssertEqual(PrivilegeProbe.databaseCreationAllowed(from: "0"), false)
    }

    /// 未知 / 空值一律按「未知」处理：界面不呈现建库入口。
    func testUnknownValuesAreNil() {
        XCTAssertNil(PrivilegeProbe.databaseCreationAllowed(from: nil))
        XCTAssertNil(PrivilegeProbe.databaseCreationAllowed(from: ""))
        XCTAssertNil(PrivilegeProbe.databaseCreationAllowed(from: "maybe"))
        XCTAssertNil(PrivilegeProbe.databaseCreationAllowed(from: "ERROR: permission denied"))
    }

    // MARK: - 数据库名预校验

    func testValidDatabaseNames() {
        XCTAssertTrue(PrivilegeProbe.isValidDatabaseName("analytics"))
        XCTAssertTrue(PrivilegeProbe.isValidDatabaseName("db_2026"))
        XCTAssertTrue(PrivilegeProbe.isValidDatabaseName("_internal"))
        XCTAssertTrue(PrivilegeProbe.isValidDatabaseName("order$archive"))
        XCTAssertTrue(PrivilegeProbe.isValidDatabaseName("业务库"))
        XCTAssertTrue(PrivilegeProbe.isValidDatabaseName("  trimmed  "))
    }

    func testInvalidDatabaseNames() {
        XCTAssertFalse(PrivilegeProbe.isValidDatabaseName(""))
        XCTAssertFalse(PrivilegeProbe.isValidDatabaseName("   "))
        XCTAssertFalse(PrivilegeProbe.isValidDatabaseName("2026db"))
        XCTAssertFalse(PrivilegeProbe.isValidDatabaseName("has space"))
        XCTAssertFalse(PrivilegeProbe.isValidDatabaseName("semi;colon"))
        XCTAssertFalse(PrivilegeProbe.isValidDatabaseName("quote\"name"))
        XCTAssertFalse(PrivilegeProbe.isValidDatabaseName("dash-name"))
    }

    func testNameLengthLimitIs63Bytes() {
        let ok = String(repeating: "a", count: 63)
        let tooLong = String(repeating: "a", count: 64)

        XCTAssertTrue(PrivilegeProbe.isValidDatabaseName(ok))
        XCTAssertFalse(PrivilegeProbe.isValidDatabaseName(tooLong))
    }
}

/// 方言层的建库权限探测 SQL（FR-META-11）。
final class DatabaseCreationPrivilegeQueryTests: XCTestCase {

    func testPostgresDialectProvidesPrivilegeQuery() throws {
        let query = try XCTUnwrap(PostgresDialect().databaseCreationPrivilegeQuery())

        XCTAssertTrue(query.contains("pg_roles"))
        XCTAssertTrue(query.contains("rolcreatedb"))
        XCTAssertTrue(query.contains("rolsuper"))
        XCTAssertTrue(query.contains("current_user"))
    }

    /// GBase 8a 需真实实例验证 `SHOW GRANTS` 解析后再实现，当前明确返回 nil（不呈现入口）。
    func testGBaseDialectDoesNotGuessPrivilege() {
        XCTAssertNil(GBaseDialect().databaseCreationPrivilegeQuery())
    }

    /// 生成 `CREATE DATABASE` 时名称必须经过方言转义（中文 / 特殊字符安全）。
    func testCreateDatabaseUsesDialectQuoting() {
        let dialect = PostgresDialect()

        XCTAssertEqual(dialect.quoteIdentifier("业务库"), "\"业务库\"")
        XCTAssertEqual(dialect.quoteIdentifier("we\"ird"), "\"we\"\"ird\"")
    }
}
