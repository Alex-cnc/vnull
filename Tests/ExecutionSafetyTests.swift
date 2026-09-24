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

// MARK: - 服务器级对象管理（FR-SESS-03）走的是同一条闸门
//
// 为什么单独立一组：这一项的界面面板曾经自己写了一层"预览 + 确认"，**绕过了 Safe Mode
// 与只读连接**。2026-09-24 需求提出者拍板「统一到一条线」，于是面板改成把
// `ServerObjects.plan(...)` 生成的语句交给 `ExecutionSafety.check` 判定。
// 这组测试钉住的是**这条闸门对 DDL / DCL 真的会拦**——否则"统一"只是接了个空壳。
final class ServerObjectSafetyGateTests: XCTestCase {

    private let on = ExecutionSafetyPolicy(isEnabled: true)

    private func decision(_ statement: String, policy: ExecutionSafetyPolicy) -> ExecutionSafety.Decision {
        ExecutionSafety.check(sql: statement, databaseType: .postgresql, policy: policy)
    }

    /// **与编辑器同规则**：破坏性的服务器级语句（DROP / GRANT）和 `DROP TABLE` 一样，
    /// 在 Safe Mode 开着时需要确认 —— 不是"另立一套只拦某些语句的规则"。
    func testDestructiveServerObjectStatementsBehaveLikeTheEditor() {
        let pairs = [
            ("DROP ROLE \"alice\";", "DROP TABLE \"orders\";"),
            ("DROP EXTENSION \"uuid-ossp\";", "DROP TABLE \"orders\";")
        ]
        for (serverObject, editor) in pairs {
            let a = decision(serverObject, policy: on)
            let b = decision(editor, policy: on)
            XCTAssertFalse(a.isAllowed, "应当需要确认：\(serverObject)")
            XCTAssertEqual(a.isAllowed, b.isAllowed, "应当与编辑器里的同类语句同判：\(serverObject)")
        }
    }

    /// 普通 `CREATE`（建角色 / 建扩展 / 建表空间）在**默认 Safe Mode** 下与编辑器里
    /// 的 `CREATE TABLE` **同判**：都不额外弹窗。
    ///
    /// 这一条是刻意的：统一到一条线 ≠ 什么都要确认一遍 —— 后者会让人养成闭眼点「继续」
    /// 的习惯。要让所有写操作都确认，用户开的是「所有写操作都确认」这个开关（下一条测试）。
    func testBenignCreateMatchesEditorSemanticsUnderDefaultSafeMode() {
        let serverObjectStatements = [
            "CREATE ROLE \"alice\" LOGIN PASSWORD 'x';",
            "ALTER ROLE \"alice\" NOLOGIN;",
            "CREATE EXTENSION \"uuid-ossp\";",
            "CREATE TABLESPACE \"ts\" LOCATION '/data/ts';"
        ]
        let editorBaseline = decision("CREATE TABLE \"t\" (\"id\" integer);", policy: on).isAllowed
        for statement in serverObjectStatements {
            XCTAssertEqual(
                decision(statement, policy: on).isAllowed,
                editorBaseline,
                "应当与编辑器里的 CREATE TABLE 同判：\(statement)"
            )
        }
    }

    /// 用户把「所有写操作都确认」打开后，**每一条**服务器级写操作都要确认 ——
    /// 面板走的就是这个开关，不再有"面板绕开设置"的口子。
    func testConfirmAllWritesSettingAlsoGatesBenignServerObjectDdl() {
        let strict = ExecutionSafetyPolicy(isEnabled: true, confirmAllWrites: true)
        for statement in [
            "CREATE ROLE \"alice\" LOGIN;",
            "ALTER ROLE \"alice\" NOLOGIN;",
            "CREATE EXTENSION \"uuid-ossp\";",
            "CREATE TABLESPACE \"ts\" LOCATION '/data/ts';",
            "GRANT SELECT ON \"orders\" TO \"alice\";"
        ] {
            XCTAssertFalse(
                decision(statement, policy: strict).isAllowed,
                "打开「所有写操作都确认」后应当需要确认：\(statement)"
            )
        }
    }

    /// **只读连接**：直接拒绝，而且**不进确认流程** —— 点「仍然执行」不该等于关掉只读标记。
    func testReadOnlyConnectionRefusesServerObjectWrites() {
        let policy = ExecutionSafetyPolicy(isEnabled: true, isReadOnly: true)
        let result = decision("CREATE ROLE \"alice\" LOGIN;", policy: policy)
        guard case .refused(let reasons, _) = result else {
            return XCTFail("只读连接上应当直接拒绝，实际：\(result)")
        }
        XCTAssertFalse(reasons.isEmpty)
    }

    /// 只读连接上的**只读**语句（读系统表看角色列表）不受影响。
    func testReadOnlyConnectionStillAllowsBrowsingStatements() {
        let policy = ExecutionSafetyPolicy(isEnabled: true, isReadOnly: true)
        XCTAssertTrue(
            decision("SELECT rolname FROM pg_roles ORDER BY rolname;", policy: policy).isAllowed
        )
    }

    /// 反过来也要钉住：Safe Mode 关掉、连接也不是只读时**不该无谓打扰**。
    /// （否则"统一闸门"会退化成"什么都要确认一遍"，用户会养成闭眼点的习惯。）
    func testGateDoesNotPromptWhenPolicyIsOffAndConnectionIsWritable() {
        let off = ExecutionSafetyPolicy(isEnabled: false, isReadOnly: false)
        XCTAssertTrue(decision("CREATE ROLE \"alice\" LOGIN;", policy: off).isAllowed)
    }
}
