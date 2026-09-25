import XCTest
@testable import DoyahCore

/// **AI 产物 → 笔记**的桥（DOYAH-10 / 任务 1）：元信息要对、行数据不许进、指纹要稳定。
final class AICaptureTests: XCTestCase {

    private func context() -> DiagnosisContext {
        DiagnosisContext(
            question: "这条查询为什么慢？",
            target: "postgres@192.168.5.217:5432/dsh_db（8.4.10）",
            evidence: [
                DiagnosisContextBuilder.makeEvidence(
                    id: "e1", kind: .statement, sql: "SELECT * FROM orders", rows: []
                ),
                DiagnosisContextBuilder.makeEvidence(
                    id: "e2", kind: .executionPlan, sql: "EXPLAIN SELECT * FROM orders",
                    rows: [["Seq Scan on orders  (cost=0.00..431.00 rows=21 width=8)"], ["  Filter: (id > 1)"]]
                )
            ]
        )
    }

    private func report() -> DiagnosisAdviceReport {
        DiagnosisAdvice.parse(
            reply: "结论: 全表扫描 [依据: e2]\n建议: CREATE INDEX ON orders (id)",
            context: context()
        )
    }

    func testDiagnosisNoteKeepsConclusionsCitationsAndSQL() {
        let note = AICapture.diagnosisNote(
            question: "这条查询为什么慢？", target: context().target, context: context(), report: report()
        ).makeNote()
        XCTAssertEqual(note.source.kind, .diagnosis)
        XCTAssertEqual(note.source.connectionName, "192.168.5.217", "来源只留主机名，不留连接串")
        XCTAssertTrue(note.body.contains("全表扫描"))
        XCTAssertTrue(note.body.contains("e2"), "引用编号要留在笔记里")
        XCTAssertTrue(note.body.contains("CREATE INDEX ON orders (id)"))
        XCTAssertTrue(note.body.contains("EXPLAIN SELECT * FROM orders"), "取证 SQL 可复跑，要留")
    }

    /// **行数据不进笔记**：证据里那两行计划文本（rows）不该出现在正文里。
    func testDiagnosisNoteNeverCarriesEvidenceRowData() {
        let note = AICapture.diagnosisNote(
            question: "q", target: context().target, context: context(), report: report()
        ).makeNote()
        XCTAssertFalse(note.containsRowData)
        XCTAssertFalse(note.body.contains("cost=0.00..431.00"), "证据行数据不允许进笔记正文")
        XCTAssertTrue(note.body.contains("共 2 行"), "但'取到几行'这类说明要留 —— 那是元信息不是数据")
    }

    func testFingerprintIsStableAndSensitiveToContent() {
        let first = AICapture.diagnosisNote(question: "q", target: context().target, context: context(), report: report())
        let second = AICapture.diagnosisNote(question: "q", target: context().target, context: context(), report: report())
        XCTAssertEqual(first.source.fingerprint, second.source.fingerprint, "同一份产物必须算出同一个指纹")
        XCTAssertNotNil(first.source.fingerprint)

        let other = DiagnosisAdvice.parse(reply: "结论: 换个说法 [依据: e2]", context: context())
        let third = AICapture.diagnosisNote(question: "q", target: context().target, context: context(), report: other)
        XCTAssertNotEqual(first.source.fingerprint, third.source.fingerprint, "结论不同就是另一份产物")
    }

    func testMaintenanceNoteRecordsStatesReasonsAndUnparsableLines() {
        let review = MaintenancePlanner.makePlan(
            from: """
            task: analyze | 更新统计 | sql: ANALYZE public.customers
            task: reindex | 重建索引 | sql: REINDEX INDEX public.orders_pkey
            task: backup | 备份 | command: pg_dump -Fc analytics
            想删掉一张表
            """,
            policy: MaintenancePolicy()
        )
        let note = AICapture.maintenanceNote(
            planText: "task: analyze | 更新统计 | sql: ANALYZE public.customers",
            review: review,
            target: "postgres@192.168.5.217:5432/dsh_db"
        ).makeNote()
        XCTAssertEqual(note.source.kind, .maintenance)
        XCTAssertTrue(note.body.contains("已拒绝"), "被限流拒绝的条目要记下来（含理由）")
        XCTAssertTrue(note.body.contains("没看懂的行"))
        XCTAssertTrue(note.body.contains("想删掉一张表"), "看不懂的行原样保留")
    }

    func testSkillNoteIsThePlaceForAICraftedKnowHow() {
        let note = AICapture.skillNote(
            title: "MySQL 时区排查步骤",
            body: "1) SELECT @@global.time_zone\n2) 看 TIMESTAMP 列",
            connectionName: "DemoMySQL"
        ).makeNote()
        XCTAssertEqual(note.source.kind, .skill)
        XCTAssertEqual(note.source.connectionName, "DemoMySQL")
        XCTAssertEqual(note.tags, ["技能"])
        XCTAssertFalse(note.containsRowData)
    }

    func testSQLNoteUsesFirstLineAsTitle() {
        let sql = "SELECT id, name\nFROM customers\nWHERE id > 1"
        let note = AICapture.sqlNote(sql: sql, connectionName: nil).makeNote()
        XCTAssertEqual(note.source.kind, .sql)
        XCTAssertEqual(note.title, "SELECT id, name")
        XCTAssertTrue(note.body.contains("```sql"))
    }

    /// 存进本地库再读回来，元信息不丢（桥与存储合起来才是"能用"）。
    func testCapturedNoteSurvivesStoreRoundTrip() async throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doyah-ai-capture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = NoteStore(fileURL: fileURL)
        let saved = try await store.upsert(
            AICapture.diagnosisNote(question: "q", target: context().target, context: context(), report: report())
        )
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].source.kind, .diagnosis)
        XCTAssertEqual(loaded[0].source.fingerprint, saved.source.fingerprint)
        XCTAssertEqual(loaded[0].source.connectionName, "192.168.5.217")
    }
}
