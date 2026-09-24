import XCTest
@testable import DoyahCore

/// FR-AI-03 的 Core 半边：证据层（不许无依据断言）+ 建议裁决层（建议 SQL 走同一道审批闸门）。
///
/// **不需要模型端点、不需要数据库**：这一层是纯组装与纯解析 —— 这也正是把它单独做出来的理由。
final class DiagnosisTests: XCTestCase {

    private let dialect = PostgresDialect()

    private func context() -> DiagnosisContext {
        DiagnosisContext(
            question: "这条查询为什么慢？",
            target: "postgres@127.0.0.1:5432/analytics",
            evidence: [
                DiagnosisContextBuilder.makeEvidence(
                    id: "e1",
                    kind: .statement,
                    sql: "SELECT * FROM orders WHERE created_at > now() - interval '1 day'",
                    rows: []
                ),
                DiagnosisContextBuilder.makeEvidence(
                    id: "e2",
                    kind: .executionPlan,
                    sql: "EXPLAIN SELECT …",
                    rows: [["Seq Scan on orders  (cost=0.00..431.00 rows=21 width=8)"]]
                ),
                DiagnosisContextBuilder.makeEvidence(
                    id: "e3",
                    kind: .slowQueries,
                    sql: "SELECT query, calls FROM pg_stat_statements …",
                    rows: nil,
                    failureReason: "pg_stat_statements 未安装"
                ),
            ]
        )
    }

    // MARK: - 证据层

    /// 三种状态必须能被表达，而且**互相分得开**：取到了有行 / 取到了零行 / 根本没取到。
    func testEvidenceStatesAreDistinct() {
        let withRows = DiagnosisContextBuilder.makeEvidence(
            id: "e1", kind: .tableStats, sql: "q", rows: [["a"], ["b"]]
        )
        XCTAssertTrue(withRows.isAvailable)
        XCTAssertEqual(withRows.note, "共 2 行")

        let empty = DiagnosisContextBuilder.makeEvidence(id: "e2", kind: .lockBlocking, sql: "q", rows: [])
        XCTAssertTrue(empty.isAvailable, "“查到了但没有行”与“没查到”是两件事")
        XCTAssertEqual(empty.note, "查到了，但没有行")

        let missing = DiagnosisContextBuilder.makeEvidence(
            id: "e3", kind: .slowQueries, sql: "q", rows: nil, failureReason: "扩展未安装"
        )
        XCTAssertFalse(missing.isAvailable)
        XCTAssertTrue(missing.note.contains("扩展未安装"))
    }

    func testEvidenceRowsAreBoundedAndTruncationIsStated() {
        let rows = (1...100).map { ["\($0)"] }
        let evidence = DiagnosisContextBuilder.makeEvidence(id: "e1", kind: .tableStats, sql: "q", rows: rows)
        XCTAssertEqual(evidence.rows.count, DiagnosisContextBuilder.maxRowsPerEvidence)
        XCTAssertTrue(evidence.isTruncated)
        XCTAssertTrue(evidence.note.contains("共 100 行"))
        XCTAssertTrue(evidence.note.contains("前 40 行"))
    }

    /// 取不到的证据必须在提示词里**单独点名**，并且提示词里写死"不许对它们下结论"。
    func testPromptListsUnavailableEvidenceExplicitly() {
        let text = context().promptText()
        XCTAssertTrue(text.contains("没有拿到证据"))
        XCTAssertTrue(text.contains("e3"))
        XCTAssertTrue(text.contains("pg_stat_statements 未安装"))
        XCTAssertTrue(text.contains("结论: <一句话> [依据: e1,e2]"), "输出格式必须写进提示词")
    }

    func testBoundedPromptStatesTruncation() {
        let context = DiagnosisContext(
            question: "问题",
            target: "t",
            evidence: [
                DiagnosisContextBuilder.makeEvidence(
                    id: "e1", kind: .statement, sql: "q",
                    rows: (1...40).map { _ in [String(repeating: "x", count: 400)] }
                )
            ]
        )
        let bounded = context.boundedPromptText(maxCharacters: 1_000)
        XCTAssertLessThanOrEqual(bounded.count, 1_000 + 120)
        XCTAssertTrue(bounded.contains("已截断"))
    }

    /// 取数计划：语句 → 计划 → 锁 → 慢查询 → 统计（顺序固定，模型先看到什么由此决定）。
    func testEvidencePlanOrderAndDialectGating() {
        let plan = DiagnosisContextBuilder.evidencePlan(for: "SELECT 1", dialect: dialect)
        XCTAssertEqual(plan.map(\.kind), [.statement, .executionPlan, .lockBlocking, .slowQueries, .tableStats])
        XCTAssertTrue(plan[1].sql.hasPrefix("EXPLAIN "))

        // MySQL 协议族：没有 pg_stat_statements（慢查询拿不到）、表体积统计与锁等待查询
        // 也还没实现 → 这些证据**一条都不该出现**（"取不到"就不该出现在提示词里当依据）。
        let mysqlPlan = DiagnosisContextBuilder.evidencePlan(
            for: "SELECT 1",
            dialect: SQLDialectFactory.make(for: .mysql)
        )
        XCTAssertEqual(mysqlPlan.map(\.kind), [.statement, .executionPlan])
        XCTAssertNil(DiagnosisEvidenceQueries.slowQueries(dialect: SQLDialectFactory.make(for: .mysql)))
        XCTAssertNil(DiagnosisEvidenceQueries.lockBlocking(dialect: SQLDialectFactory.make(for: .mysql)))
    }

    /// **执行计划绝不用 `EXPLAIN ANALYZE`** —— 那会真的执行语句（AgentGuardrail 标为高危）。
    func testExecutionPlanNeverUsesAnalyze() {
        for type in DatabaseType.allCases {
            let sql = DiagnosisEvidenceQueries.executionPlan(
                for: "DELETE FROM t",
                dialect: SQLDialectFactory.make(for: type)
            )
            XCTAssertFalse(sql.uppercased().contains("ANALYZE"), "\(type) 的计划查询不许带 ANALYZE")
            XCTAssertTrue(sql.hasPrefix("EXPLAIN "))
        }
    }

    // MARK: - 裁决层：不许无依据断言

    func testCitedConclusionIsAccepted() {
        let report = DiagnosisAdvice.parse(
            reply: "结论: 全表扫描导致慢 [依据: e2]\n建议: CREATE INDEX ON orders (created_at)",
            context: context()
        )
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items[0].citations, ["e2"])
        XCTAssertEqual(report.items[0].suggestedSQL, "CREATE INDEX ON orders (created_at)")
        XCTAssertFalse(report.hasRejections)
    }

    func testConclusionWithoutCitationsIsRejected() {
        let report = DiagnosisAdvice.parse(
            reply: "结论: 应该是索引没建好",
            context: context()
        )
        XCTAssertTrue(report.items.isEmpty, "没有依据的结论不许被采纳")
        XCTAssertEqual(report.rejections.count, 1)
        XCTAssertEqual(report.rejections[0].reason, .missingCitations)
    }

    func testConclusionCitingUnknownEvidenceIsRejected() {
        let report = DiagnosisAdvice.parse(
            reply: "结论: 看上去是锁冲突 [依据: e9]",
            context: context()
        )
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(report.rejections.first?.reason, .unknownCitation("e9"))
    }

    /// 拿不到的证据**不能**被引用（`e3` 就在上下文里，但它是"未取到"）。模型引用它必须被拒。
    func testUnavailableEvidenceCannotBeCited() {
        let report = DiagnosisAdvice.parse(
            reply: "结论: 历史上一直很慢 [依据: e3]",
            context: context()
        )
        XCTAssertTrue(report.items.isEmpty, "未取到的证据不能作为依据")
        XCTAssertEqual(report.rejections.first?.reason, .unknownCitation("e3"))
    }

    func testUnparsableLinesAreKeptNotDropped() {
        let report = DiagnosisAdvice.parse(
            reply: "总之我觉得是磁盘慢\n结论: 全表扫描 [依据: e2]",
            context: context()
        )
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.rejections.count, 1)
        XCTAssertEqual(report.rejections[0].reason, .unparsable)
        XCTAssertEqual(report.rejections[0].line, "总之我觉得是磁盘慢")
    }

    // MARK: - 裁决层：建议 SQL 走同一道审批闸门

    func testSuggestedSQLGoesThroughExecutionSafety() {
        // 只读连接上的写语句：直接拒绝（不可绕过）——与在编辑器里敲这条语句同一判据。
        let readOnly = ExecutionSafetyPolicy(isEnabled: true, isReadOnly: true)
        let report = DiagnosisAdvice.parse(
            reply: "结论: 表膨胀了 [依据: e1]\n建议: VACUUM FULL orders",
            context: context(),
            policy: readOnly
        )
        guard case .refused = report.items[0].decision else {
            return XCTFail("只读连接上的 VACUUM FULL 必须被拒绝，实际是 \(String(describing: report.items[0].decision))")
        }
    }

    /// 高危写语句在可写连接上要**要求确认**，而不是放行。
    func testHighRiskSuggestedSQLNeedsConfirmation() {
        let report = DiagnosisAdvice.parse(
            reply: "结论: 需要重建索引 [依据: e2]\n建议: DROP INDEX idx_orders_created",
            context: context(),
            policy: ExecutionSafetyPolicy(isEnabled: true)
        )
        guard case .needsConfirmation = report.items[0].decision else {
            return XCTFail("DROP INDEX 应当需要确认，实际是 \(String(describing: report.items[0].decision))")
        }
    }

    /// 中英标点与 `建议：` 全角冒号都要认（模型输出很不稳定，这一层不能挑食）。
    func testFullWidthPunctuationIsAccepted() {
        let report = DiagnosisAdvice.parse(
            reply: "结论：全表扫描 [依据：e1，e2]\n建议：ANALYZE orders",
            context: context()
        )
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items[0].citations, ["e1", "e2"])
        XCTAssertEqual(report.items[0].suggestedSQL, "ANALYZE orders")
    }

    /// 结论 + 建议 + 再结论：建议归属于**紧邻的上一条**结论，不许串到别条去。
    func testSuggestionAttachesToNearestConclusion() {
        let report = DiagnosisAdvice.parse(
            reply: """
            结论: 第一条 [依据: e1]
            建议: SELECT 1
            结论: 第二条 [依据: e2]
            建议: SELECT 2
            """,
            context: context()
        )
        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(report.items[0].suggestedSQL, "SELECT 1")
        XCTAssertEqual(report.items[1].suggestedSQL, "SELECT 2")
        XCTAssertEqual(report.items[0].citations, ["e1"])
    }
}
