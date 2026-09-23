import XCTest
@testable import DoyahCore

/// R-21 的「用当前条件重新查询」：把 `WHERE` 插进编辑器里的 SQL。
/// 重点全在**别插错地方**：字符串里的 where、注释里的 where、子查询里的 where 都不是子句。
final class SQLFilterInjectionTests: XCTestCase {

    private let clause = "WHERE \"id\" > '10'"

    private func injected(_ sql: String) -> String? {
        guard case .injected(let new) = SQLFilterInjector.inject(whereClause: clause, into: sql) else { return nil }
        return new
    }

    func testAppendsWhereWhenThereIsNoTrailer() {
        let sql = injected("SELECT * FROM users") ?? ""
        XCTAssertTrue(sql.hasPrefix("SELECT * FROM users\nWHERE \"id\" > '10'"), sql)
    }

    /// 有 ORDER BY / LIMIT 时要插在它们**之前** —— 插到后面就是语法错误。
    func testInsertsBeforeTrailingClauses() {
        let ordered = injected("SELECT * FROM users ORDER BY name") ?? ""
        XCTAssertTrue(ordered.contains("FROM users\nWHERE \"id\" > '10'\nORDER BY name"), ordered)

        let limited = injected("SELECT * FROM users\nLIMIT 100") ?? ""
        XCTAssertTrue(limited.contains("FROM users\nWHERE \"id\" > '10'\nLIMIT 100"), limited)

        let grouped = injected("SELECT role, count(*) FROM users GROUP BY role") ?? ""
        XCTAssertTrue(grouped.contains("FROM users\nWHERE \"id\" > '10'\nGROUP BY role"), grouped)
    }

    /// 已有 WHERE 时不替用户合并条件（语义容易改错），交给用户处理。
    func testExistingWhereIsReportedNotMerged() {
        let result = SQLFilterInjector.inject(whereClause: clause, into: "SELECT * FROM users WHERE active")
        XCTAssertEqual(result, .alreadyHasWhere)
    }

    /// 分号前的空格与分号本身要处理对：条件插在分号之前。
    func testInsertsBeforeTrailingSemicolon() {
        let sql = injected("SELECT * FROM users;") ?? ""
        XCTAssertTrue(sql.hasPrefix("SELECT * FROM users\nWHERE \"id\" > '10'\n;"), sql)
    }

    /// 字符串字面量里的 `where` 不是子句。
    func testWhereInsideStringLiteralIsNotAClause() {
        let sql = injected("SELECT 'where x' AS note FROM users") ?? ""
        XCTAssertFalse(sql.isEmpty)
        XCTAssertTrue(sql.contains("WHERE \"id\" > '10'"), sql)
    }

    /// 注释里的 `WHERE` 也不是子句（否则我们就会以「已有 WHERE」为由拒绝注入）。
    func testWhereInsideCommentsIsIgnored() {
        let line = SQLFilterInjector.inject(
            whereClause: clause,
            into: "SELECT * FROM users -- WHERE old\n"
        )
        XCTAssertNotEqual(line, .alreadyHasWhere)

        let block = SQLFilterInjector.inject(
            whereClause: clause,
            into: "SELECT * /* WHERE old */ FROM users"
        )
        XCTAssertNotEqual(block, .alreadyHasWhere)
    }

    /// 子查询里的 WHERE 在括号内，不该被当成顶层子句。
    func testWhereInsideSubqueryIsNotTopLevel() {
        let sql = injected("SELECT * FROM (SELECT * FROM t WHERE x = 1) s") ?? ""
        XCTAssertTrue(sql.hasSuffix("WHERE \"id\" > '10'"), sql)
    }

    /// 美元引用里的 `order by` / `where` 是函数体正文。
    func testDollarQuotedBodyIsOpaque() {
        let sql = injected("SELECT f($$ SELECT 1 WHERE true ORDER BY 1 $$) FROM t") ?? ""
        XCTAssertTrue(sql.hasSuffix("WHERE \"id\" > '10'"), "不该把函数体里的子句当收尾子句：\(sql)")
    }

    func testMultipleStatementsAreRefused() {
        let result = SQLFilterInjector.inject(whereClause: clause, into: "SELECT 1; SELECT 2;")
        guard case .unsupported(let reason) = result else {
            return XCTFail("多条语句应拒绝注入，实际：\(result)")
        }
        XCTAssertTrue(reason.contains("多条语句"), reason)
    }

    func testNonQueryStatementIsRefused() {
        let result = SQLFilterInjector.inject(whereClause: clause, into: "UPDATE users SET a = 1")
        guard case .unsupported(let reason) = result else {
            return XCTFail("UPDATE 应拒绝注入，实际：\(result)")
        }
        XCTAssertTrue(reason.contains("UPDATE"), reason)
    }

    func testUnionIsRefused() {
        let result = SQLFilterInjector.inject(whereClause: clause, into: "SELECT 1 FROM a UNION SELECT 2 FROM b")
        guard case .unsupported(let reason) = result else {
            return XCTFail("UNION 应拒绝注入，实际：\(result)")
        }
        XCTAssertTrue(reason.contains("UNION"), reason)
    }

    func testWithQueryIsAllowed() {
        let sql = injected("WITH t AS (SELECT 1 AS x) SELECT * FROM t ORDER BY x") ?? ""
        XCTAssertTrue(sql.contains("WHERE \"id\" > '10'\nORDER BY x"), sql)
    }

    func testEmptyClauseIsRefused() {
        let result = SQLFilterInjector.inject(whereClause: "   ", into: "SELECT 1")
        guard case .unsupported = result else {
            return XCTFail("空条件应拒绝，实际：\(result)")
        }
    }
}
