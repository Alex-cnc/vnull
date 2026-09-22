import XCTest
@testable import DoyahCore

/// FR-EXEC-16：高危语句保护（Safe Mode）。
final class ExecutionSafetyTests: XCTestCase {

    private let on = ExecutionSafetyPolicy(isEnabled: true)
    private let off = ExecutionSafetyPolicy(isEnabled: false)

    private func check(_ sql: String, policy: ExecutionSafetyPolicy? = nil) -> ExecutionSafety.Decision {
        ExecutionSafety.check(sql: sql, databaseType: .postgresql, policy: policy ?? on)
    }

    private func findings(_ sql: String, policy: ExecutionSafetyPolicy? = nil) -> [AgentGuardFinding] {
        if case .needsConfirmation(_, let findings, _) = check(sql, policy: policy) { return findings }
        return []
    }

    // MARK: - 验收要点里的四类高危

    func testUpdateWithoutWhereNeedsConfirmation() {
        XCTAssertTrue(findings("UPDATE orders SET total = 0").contains(.updateWithoutWhere))
        XCTAssertFalse(check("UPDATE orders SET total = 0").isAllowed)
    }

    func testDeleteWithoutWhereNeedsConfirmation() {
        XCTAssertTrue(findings("DELETE FROM orders").contains(.deleteWithoutWhere))
        XCTAssertFalse(check("DELETE FROM orders").isAllowed)
    }

    func testDropAndTruncateNeedConfirmation() {
        XCTAssertTrue(findings("DROP TABLE orders").contains(.dropStatement))
        XCTAssertTrue(findings("TRUNCATE TABLE orders").contains(.truncateStatement))
        XCTAssertFalse(check("DROP TABLE orders").isAllowed)
        XCTAssertFalse(check("TRUNCATE TABLE orders").isAllowed)
    }

    // MARK: - 不该打扰的情形

    func testSafeStatementsPassWithoutPrompt() {
        for sql in [
            "SELECT * FROM orders",
            "SELECT 1",
            "UPDATE orders SET total = 0 WHERE id = 1",
            "DELETE FROM orders WHERE created_at < now() - interval '30 days'",
            "INSERT INTO orders (id) VALUES (1)",
            "CREATE TABLE t (a int)",
            "WITH recent AS (SELECT * FROM orders WHERE id > 10) SELECT * FROM recent"
        ] {
            XCTAssertTrue(check(sql).isAllowed, "不该被拦：\(sql)")
        }
    }

    /// 关闭 Safe Mode 后一律放行（验收要点「可跳过」）。
    func testDisabledPolicyAllowsEverything() {
        XCTAssertTrue(check("DELETE FROM orders", policy: off).isAllowed)
        XCTAssertTrue(check("DROP DATABASE appdb", policy: off).isAllowed)
    }

    /// 子查询里的 WHERE 不算外层条件（否则「无 WHERE 的 UPDATE」会被漏掉）。
    func testWhereInsideSubqueryDoesNotSatisfyOuterUpdate() {
        let sql = "UPDATE orders SET total = (SELECT coalesce(sum(x), 0) FROM items WHERE items.order_id = orders.id)"

        XCTAssertTrue(findings(sql).contains(.updateWithoutWhere))
    }

    /// 字符串与注释里的关键字不参与判定。
    func testKeywordsInsideStringsAndCommentsAreIgnored() {
        XCTAssertTrue(check("-- DELETE FROM orders\nSELECT 1").isAllowed)
        XCTAssertTrue(check("SELECT 'DROP TABLE orders'").isAllowed)
    }

    // MARK: - 与运行范围控制配合

    /// 只对「将要执行的那几条」判定：整篇里有危险语句，但只跑安全的那条 → 不拦。
    func testOnlyChecksTheStatementsAboutToRun() {
        let onlySafe = ExecutionSafety.check(
            statements: ["SELECT * FROM orders"],
            databaseType: .postgresql,
            policy: on
        )
        XCTAssertTrue(onlySafe.isAllowed)

        let withDanger = ExecutionSafety.check(
            statements: ["SELECT 1", "DELETE FROM orders"],
            databaseType: .postgresql,
            policy: on
        )
        XCTAssertFalse(withDanger.isAllowed)
    }

    func testEmptyStatementListIsAllowed() {
        XCTAssertTrue(
            ExecutionSafety.check(statements: [], databaseType: .postgresql, policy: on).isAllowed
        )
    }

    // MARK: - confirmAllWrites

    func testConfirmAllWritesAlsoAsksForOrdinaryWrites() {
        let strict = ExecutionSafetyPolicy(isEnabled: true, confirmAllWrites: true)

        // 带 WHERE 的 UPDATE：默认放行，严格模式下也要确认。
        XCTAssertTrue(check("UPDATE orders SET total = 0 WHERE id = 1").isAllowed)
        let strictDecision = check("UPDATE orders SET total = 0 WHERE id = 1", policy: strict)
        XCTAssertFalse(strictDecision.isAllowed)
        if case .needsConfirmation(let reasons, _, _) = strictDecision {
            XCTAssertFalse(reasons.isEmpty)
        }

        // 纯只读仍然放行。
        XCTAssertTrue(check("SELECT 1", policy: strict).isAllowed)
    }

    /// 严格模式下，高危语句仍然报**具体原因**，而不是笼统的「会改数据」。
    func testStrictModeStillReportsSpecificReasonForHighRisk() {
        let strict = ExecutionSafetyPolicy(isEnabled: true, confirmAllWrites: true)

        XCTAssertTrue(findings("DELETE FROM orders", policy: strict).contains(.deleteWithoutWhere))
    }

    // MARK: - 弹窗文案

    func testConfirmationMessageListsReasonsAndStatements() {
        let decision = check("DROP TABLE orders")

        guard case .needsConfirmation(let reasons, _, let statements) = decision else {
            return XCTFail("应当要求确认")
        }
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("DROP"))
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(decision.message.contains("DROP"))
        XCTAssertTrue(decision.message.contains("orders"))
    }

    /// 多条危险语句只报一次原因、不重复刷屏。
    func testRepeatedReasonsAreDeduplicated() {
        let decision = check("DELETE FROM a; DELETE FROM b; DELETE FROM c")

        guard case .needsConfirmation(let reasons, let findings, let statements) = decision else {
            return XCTFail("应当要求确认")
        }
        XCTAssertEqual(findings, [.deleteWithoutWhere])
        XCTAssertEqual(reasons.count, 1)
        XCTAssertEqual(statements.count, 3, "涉事语句仍要逐条列出")
    }

    func testOneLineCollapsesWhitespace() {
        XCTAssertEqual(
            ExecutionSafety.oneLine("DELETE\n   FROM   orders\n"),
            "DELETE FROM orders"
        )
        let long = String(repeating: "a", count: 200)
        XCTAssertTrue(ExecutionSafety.oneLine(long).hasSuffix("…"))
    }

    /// GBase 方言下同样生效（复用同一套词法扫描）。
    func testWorksForGBaseDialect() {
        XCTAssertFalse(
            ExecutionSafety.check(
                sql: "DELETE FROM orders",
                databaseType: .gbase8a,
                policy: on
            ).isAllowed
        )
        XCTAssertTrue(
            ExecutionSafety.check(
                sql: "SELECT * FROM orders",
                databaseType: .gbase8a,
                policy: on
            ).isAllowed
        )
    }
}
