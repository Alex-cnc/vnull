import XCTest
@testable import DoyahCore

/// FR-AI-09 / NFR-AI-03：审计面板用到的纯逻辑（过滤、格式化、导出列顺序、导出脱敏）。
final class AgentAuditPresentationTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentAuditPresentationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func record(
        sql: String,
        outcome: AgentActionRecord.Outcome = .generated,
        connection: String? = "DemoPG",
        database: String? = "appdb",
        model: String? = "qwen2.5:7b",
        at date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        detail: String? = nil
    ) -> AgentActionRecord {
        let assessment = AgentGuardrail.evaluate(sql: sql, databaseType: .postgresql, policy: .approvalRequired)
        return AgentActionRecord.make(
            sql: sql,
            assessment: assessment,
            context: .init(connectionName: connection, database: database, model: model),
            outcome: outcome,
            detail: detail,
            at: date
        )
    }

    // MARK: - 语句摘要

    func testStatementSummaryFlattensWhitespace() {
        let summary = AgentAuditPresentation.statementSummary("SELECT a,\n  b\nFROM t")

        XCTAssertEqual(summary, "SELECT a, b FROM t")
        XCTAssertFalse(summary.contains("\n"))
    }

    func testStatementSummaryTruncatesLongStatements() {
        let sql = "SELECT " + String(repeating: "x", count: 200)

        let summary = AgentAuditPresentation.statementSummary(sql, limit: 20)

        XCTAssertEqual(summary.count, 21, "截断到 limit 个字符 + 省略号")
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertTrue(AgentAuditPresentation.statementSummary(sql).hasSuffix("…"))
        // 短语句原样返回，不加省略号。
        XCTAssertEqual(AgentAuditPresentation.statementSummary("SELECT 1", limit: 20), "SELECT 1")
    }

    // MARK: - 各列格式

    func testTimestampTextUsesFixedFormatInGivenTimeZone() {
        // 固定时区，避免「跑测试的机器在哪个时区」影响断言。
        let text = AgentAuditPresentation.timestampText(
            Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(text, "2023-11-14 22:13:20")
    }

    func testConnectionAndModelTextFallBackToPlaceholder() {
        let full = record(sql: "SELECT 1")
        XCTAssertEqual(AgentAuditPresentation.connectionText(full), "DemoPG · appdb")
        XCTAssertEqual(AgentAuditPresentation.modelText(full), "qwen2.5:7b")

        let bare = record(sql: "SELECT 1", connection: nil, database: nil, model: "   ")
        XCTAssertEqual(AgentAuditPresentation.connectionText(bare), AgentAuditPresentation.placeholder)
        XCTAssertEqual(AgentAuditPresentation.modelText(bare), AgentAuditPresentation.placeholder)

        let noDatabase = record(sql: "SELECT 1", database: nil)
        XCTAssertEqual(AgentAuditPresentation.connectionText(noDatabase), "DemoPG")
    }

    func testFindingsTextListsReasonsAndIsEmptyWhenClean() {
        let risky = record(sql: "DROP TABLE orders")
        XCTAssertEqual(AgentAuditPresentation.findingsText(risky), AgentGuardFinding.dropStatement.message)
        XCTAssertTrue(AgentAuditPresentation.isHighRisk(risky))

        let clean = record(sql: "SELECT 1")
        XCTAssertEqual(AgentAuditPresentation.findingsText(clean), "")
        XCTAssertFalse(AgentAuditPresentation.isHighRisk(clean))

        let multi = record(sql: "UPDATE t SET a = 1")
        XCTAssertTrue(AgentAuditPresentation.findingsText(multi).contains("WHERE"))
    }

    // MARK: - 过滤

    func testFilterByOutcome() {
        let records = [
            record(sql: "SELECT 1", outcome: .generated),
            record(sql: "INSERT INTO t (a) VALUES (1)", outcome: .pendingApproval),
            record(sql: "DROP TABLE t", outcome: .rejected)
        ]

        XCTAssertEqual(AgentAuditFilter.all.apply(to: records).count, 3)

        let pending = AgentAuditFilter(outcome: .pendingApproval).apply(to: records)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.outcome, .pendingApproval)
        XCTAssertTrue(AgentAuditFilter(outcome: .executed).apply(to: records).isEmpty)
    }

    func testFilterByConnectionAndSearchText() {
        let records = [
            record(sql: "SELECT * FROM orders", connection: "DemoPG"),
            record(sql: "SELECT * FROM customers", connection: "ProdPG", model: "gpt-4o-mini")
        ]

        XCTAssertEqual(AgentAuditFilter(connectionName: "DemoPG").apply(to: records).count, 1)
        // 空白连接条件视为「不限」。
        XCTAssertEqual(AgentAuditFilter(connectionName: "   ").apply(to: records).count, 2)

        // 关键词大小写不敏感，且能匹配语句 / 连接 / 模型 / 库。
        XCTAssertEqual(AgentAuditFilter(searchText: "ORDERS").apply(to: records).count, 1)
        XCTAssertEqual(AgentAuditFilter(searchText: "prodpg").apply(to: records).count, 1)
        XCTAssertEqual(AgentAuditFilter(searchText: "gpt-4o").apply(to: records).count, 1)
        XCTAssertEqual(AgentAuditFilter(searchText: "appdb").apply(to: records).count, 2)
        XCTAssertTrue(AgentAuditFilter(searchText: "没有这个").apply(to: records).isEmpty)
    }

    func testFilterCanMatchDetailText() {
        let records = [
            record(sql: "SELECT 1", detail: "只读模式已拒绝"),
            record(sql: "SELECT 2", detail: "已执行")
        ]

        XCTAssertEqual(AgentAuditFilter(searchText: "只读模式").apply(to: records).count, 1)
    }

    func testFilterCombinesConditionsAndReportsActiveState() {
        let records = [
            record(sql: "SELECT * FROM orders", outcome: .executed, connection: "DemoPG"),
            record(sql: "SELECT * FROM orders", outcome: .executed, connection: "ProdPG"),
            record(sql: "DROP TABLE orders", outcome: .rejected, connection: "DemoPG")
        ]

        let filter = AgentAuditFilter(outcome: .executed, connectionName: "DemoPG", searchText: "orders")
        let matched = filter.apply(to: records)

        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.connectionName, "DemoPG")
        XCTAssertTrue(filter.isActive)
        XCTAssertFalse(AgentAuditFilter.all.isActive)
        XCTAssertFalse(AgentAuditFilter(searchText: "   ").isActive)
    }

    func testConnectionNamesAreDeduplicatedAndSorted() {
        let records = [
            record(sql: "SELECT 1", connection: "ProdPG"),
            record(sql: "SELECT 1", connection: "DemoPG"),
            record(sql: "SELECT 1", connection: "ProdPG"),
            record(sql: "SELECT 1", connection: nil),
            record(sql: "SELECT 1", connection: "")
        ]

        XCTAssertEqual(AgentAuditFilter.connectionNames(in: records), ["DemoPG", "ProdPG"])
    }

    // MARK: - 导出（NFR-AI-03）

    /// 导出列顺序是**一份**定义（`csvColumns`），CSV 表头必须与它一致。
    func testCSVColumnsOrderIsStableAndUsedByExport() async throws {
        XCTAssertEqual(
            AgentAuditLog.csvColumns,
            ["timestamp", "connection", "database", "model",
             "statement_kind", "risk", "findings", "outcome", "duration_ms", "sql", "detail"]
        )

        let log = AgentAuditLog(directoryURL: try makeDirectory())
        try await log.append(record(sql: "SELECT 1"))

        let csv = try await log.exportCSV()
        let firstLine = csv.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        XCTAssertEqual(firstLine ?? "", AgentAuditLog.csvColumns.joined(separator: ","))
    }

    func testExportJSONHasNoByteOrderMarkAndIsAnArray() async throws {
        let log = AgentAuditLog(directoryURL: try makeDirectory())
        try await log.append(record(sql: "SELECT 1"))

        let data = try await log.export(.json)

        XCTAssertFalse(String(decoding: data.prefix(3), as: UTF8.self) == "\u{FEFF}")
        let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(array?.count, 1)
        XCTAssertEqual(array?.first?["sql"] as? String, "SELECT 1")
    }

    /// CSV 导出带 UTF-8 BOM（Excel 打开中文不乱码），且**仍然脱敏**。
    func testExportCSVHasByteOrderMarkAndIsRedacted() async throws {
        let log = AgentAuditLog(directoryURL: try makeDirectory())
        try await log.append(
            record(
                sql: "SELECT * FROM t WHERE token = 'sk-abcdef1234567890'",
                outcome: .failed,
                detail: "调用失败：Bearer sk-abcdef1234567890"
            )
        )

        let data = try await log.export(.csv)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("\u{FEFF}"))
        XCTAssertFalse(text.contains("sk-abcdef1234567890"))
        XCTAssertTrue(text.contains(AgentAudit.redactionPlaceholder))
        XCTAssertTrue(text.contains(AgentAuditLog.csvColumns.joined(separator: ",")))
    }

    /// JSON 导出同样脱敏（导出路径只有一条，两条格式都过 `AgentAudit.redacted`）。
    func testExportJSONIsRedacted() async throws {
        let log = AgentAuditLog(directoryURL: try makeDirectory())
        try await log.append(
            record(sql: "SELECT * FROM t WHERE api_key = 'deadbeefdeadbeef'", outcome: .failed)
        )

        let text = String(decoding: try await log.export(.json), as: UTF8.self)

        XCTAssertFalse(text.contains("deadbeefdeadbeef"))
        XCTAssertTrue(text.contains(AgentAudit.redactionPlaceholder))
    }

    func testExportFormatsExposeFileNaming() {
        XCTAssertEqual(AgentAuditExportFormat.json.fileExtension, "json")
        XCTAssertEqual(AgentAuditExportFormat.csv.fileExtension, "csv")
        XCTAssertEqual(AgentAuditExportFormat.json.defaultBaseName, "agent-audit")
        XCTAssertEqual(AgentAuditExportFormat.allCases.count, 2)
    }

    // MARK: - 耗时展示（NFR-AI-03）

    func testDurationTextFormatsMillisecondsAndSeconds() {
        XCTAssertEqual(AgentAuditPresentation.durationText(milliseconds: 0), "0 ms")
        XCTAssertEqual(AgentAuditPresentation.durationText(milliseconds: 820), "820 ms")
        XCTAssertEqual(AgentAuditPresentation.durationText(milliseconds: 999), "999 ms")
        XCTAssertEqual(AgentAuditPresentation.durationText(milliseconds: 1000), "1.0 s")
        XCTAssertEqual(AgentAuditPresentation.durationText(milliseconds: 1234), "1.2 s")
        // 日志被手改过也不该显示负数
        XCTAssertEqual(AgentAuditPresentation.durationText(milliseconds: -5), "0 ms")
    }

    func testDurationTextUsesPlaceholderWhenRecordHasNoDuration() {
        let without = AgentActionRecord(
            sql: "SELECT 1", statementKind: .readQuery, risk: .low, outcome: .generated
        )
        XCTAssertEqual(AgentAuditPresentation.durationText(without), AgentAuditPresentation.placeholder)

        let with = AgentActionRecord(
            sql: "SELECT 1", statementKind: .readQuery, risk: .low,
            outcome: .generated, durationMilliseconds: 2500
        )
        XCTAssertEqual(AgentAuditPresentation.durationText(with), "2.5 s")
    }
}
