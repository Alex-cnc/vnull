import XCTest
@testable import PostgresClientCore

/// FR-AI-09 / NFR-AI-03：执行审批状态机与审计日志。
final class AgentAuditTests: XCTestCase {

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
            .appendingPathComponent("AgentAuditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func assessment(
        _ sql: String,
        policy: AgentGuardPolicy = .approvalRequired
    ) -> AgentGuardAssessment {
        AgentGuardrail.evaluate(sql: sql, databaseType: .postgresql, policy: policy)
    }

    private let context = AgentActionRecord.Context(
        connectionName: "DemoPG", database: "appdb", model: "qwen2.5:7b"
    )

    // MARK: - 审批状态机

    func testHappyPathPendingApprovedExecuted() throws {
        let approval = try XCTUnwrap(
            AgentApproval.request(sql: "DROP TABLE orders", assessment: assessment("DROP TABLE orders"), context: context)
        )

        XCTAssertEqual(approval.state, .pending)
        XCTAssertTrue(approval.awaitsHumanDecision)
        XCTAssertFalse(approval.canExecute, "未经批准不得执行")
        XCTAssertEqual(approval.record.outcome, .pendingApproval)

        var approvable = approval
        try approvable.approve(by: "alex", note: "已确认是测试库")
        XCTAssertEqual(approvable.state, .approved)
        XCTAssertTrue(approvable.canExecute)
        XCTAssertEqual(approvable.record.outcome, .approved)
        XCTAssertEqual(approvable.decidedBy, "alex")

        var executed = approvable
        try executed.markExecuted()
        XCTAssertEqual(executed.state, .executed)
        XCTAssertEqual(executed.record.outcome, .executed)
        XCTAssertFalse(executed.canExecute, "执行完不再是「可执行」状态")
        XCTAssertTrue(executed.state.isTerminal)
    }

    func testRejectAndExpireAreTerminal() throws {
        var rejected = try XCTUnwrap(
            AgentApproval.request(sql: "TRUNCATE orders", assessment: assessment("TRUNCATE orders"))
        )
        try rejected.reject(by: "alex", note: "生产库不允许")
        XCTAssertEqual(rejected.state, .rejected)
        XCTAssertEqual(rejected.record.outcome, .rejected)
        XCTAssertEqual(rejected.note, "生产库不允许")
        XCTAssertFalse(rejected.canExecute)

        var expired = try XCTUnwrap(
            AgentApproval.request(sql: "TRUNCATE orders", assessment: assessment("TRUNCATE orders"))
        )
        try expired.expire(note: "超时未决策")
        XCTAssertEqual(expired.state, .expired)
        XCTAssertEqual(expired.record.outcome, .expired)
        XCTAssertTrue(expired.state.isTerminal)
    }

    /// 非法流转一律抛错：执行前必须处于已批准状态。
    func testInvalidTransitionsThrow() throws {
        let pending = try XCTUnwrap(
            AgentApproval.request(sql: "DELETE FROM t", assessment: assessment("DELETE FROM t"))
        )

        // 未批准不得执行 / 不得标记失败。
        var executor = pending
        XCTAssertThrowsError(try executor.markExecuted()) { error in
            XCTAssertEqual(error as? AgentApprovalError, .invalidTransition(from: .pending, to: .executed))
        }
        var failer = pending
        XCTAssertThrowsError(try failer.markFailed())

        // 已批准不得再批准 / 不得被拒。
        var approved = pending
        try approved.approve()
        var reapprove = approved
        XCTAssertThrowsError(try reapprove.approve()) { error in
            XCTAssertEqual(error as? AgentApprovalError, .invalidTransition(from: .approved, to: .approved))
        }
        var rejectAfterApprove = approved
        XCTAssertThrowsError(try rejectAfterApprove.reject()) { error in
            XCTAssertEqual(error as? AgentApprovalError, .invalidTransition(from: .approved, to: .rejected))
        }

        // 终态不得再流转。
        var executed = approved
        try executed.markExecuted()
        var again = executed
        XCTAssertThrowsError(try again.markExecuted())
        var afterExecute = executed
        XCTAssertThrowsError(try afterExecute.approve())
    }

    func testTransitionTableIsSymmetricWithRuntimeChecks() {
        XCTAssertTrue(AgentApproval.canTransition(from: .pending, to: .approved))
        XCTAssertTrue(AgentApproval.canTransition(from: .pending, to: .rejected))
        XCTAssertTrue(AgentApproval.canTransition(from: .pending, to: .expired))
        XCTAssertTrue(AgentApproval.canTransition(from: .approved, to: .executed))
        XCTAssertTrue(AgentApproval.canTransition(from: .approved, to: .failed))
        XCTAssertFalse(AgentApproval.canTransition(from: .pending, to: .executed))
        XCTAssertFalse(AgentApproval.canTransition(from: .rejected, to: .approved))
        XCTAssertFalse(AgentApproval.canTransition(from: .executed, to: .approved))
    }

    // MARK: - 审批单生成（含只读模式）

    /// 只读模式下被护栏拒绝的语句**连审批单都建不出来**（AC-AI-02）。
    func testDeniedStatementCannotEvenBeRequestedForApproval() {
        let guarded = assessment("DROP TABLE orders", policy: .readOnlyDefault)
        XCTAssertEqual(guarded.verdict, .deny(.readOnlyMode(kind: .schemaChange)))
        XCTAssertNil(AgentApproval.request(sql: "DROP TABLE orders", assessment: guarded, context: context))
    }

    func testHighRiskStatementBecomesPendingApproval() throws {
        let approval = try XCTUnwrap(
            AgentApproval.request(
                sql: "UPDATE orders SET total = 0",
                assessment: assessment("UPDATE orders SET total = 0"),
                context: context
            )
        )

        XCTAssertEqual(approval.state, .pending)
        XCTAssertEqual(approval.record.statementKind, .dataChange)
        XCTAssertEqual(approval.record.risk, .destructive)
        XCTAssertEqual(approval.record.findings, [.updateWithoutWhere])
        XCTAssertEqual(approval.record.detail?.contains("UPDATE"), true)
    }

    /// 无风险的只读语句自动放行，但仍留痕。
    func testAllowedStatementIsAutoApprovedButStillRecorded() throws {
        let approval = try XCTUnwrap(
            AgentApproval.request(
                sql: "SELECT * FROM orders",
                assessment: assessment("SELECT * FROM orders"),
                context: context
            )
        )

        XCTAssertEqual(approval.state, .approved)
        XCTAssertTrue(approval.canExecute)
        XCTAssertEqual(approval.decidedBy, "auto")
        XCTAssertEqual(approval.record.outcome, .approved)
        XCTAssertEqual(approval.record.statementKind, .readQuery)
        XCTAssertEqual(approval.record.risk, .low)
    }

    // MARK: - 记录模型

    func testRecordCarriesContextAndOutcome() {
        let record = AgentActionRecord.make(
            sql: "DELETE FROM orders",
            assessment: assessment("DELETE FROM orders"),
            context: context,
            outcome: .denied,
            detail: "只读模式"
        )

        XCTAssertEqual(record.connectionName, "DemoPG")
        XCTAssertEqual(record.database, "appdb")
        XCTAssertEqual(record.model, "qwen2.5:7b")
        XCTAssertEqual(record.statementKind, .dataChange)
        XCTAssertEqual(record.risk, .destructive)
        XCTAssertEqual(record.findings, [.deleteWithoutWhere])
        XCTAssertEqual(record.outcome, .denied)
        XCTAssertEqual(record.detail, "只读模式")
    }

    func testRecordCodableRoundTrip() throws {
        // ISO8601 编码不带小数秒：用整秒时间戳，避免把「编码精度」误判成「数据丢失」。
        let wholeSecond = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AgentActionRecord.make(
            sql: "DROP TABLE t",
            assessment: assessment("DROP TABLE t"),
            context: context,
            outcome: .pendingApproval,
            at: wholeSecond
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(AgentActionRecord.self, from: try encoder.encode(record))

        XCTAssertEqual(restored, record)
    }

    // MARK: - 审计日志

    func testAuditLogAppendReadAndPersist() async throws {
        let directory = try makeDirectory()
        let log = AgentAuditLog(directoryURL: directory)

        let initiallyEmpty = try await log.entries()
        XCTAssertTrue(initiallyEmpty.isEmpty, "缺文件时应当为空而不是报错")

        let first = AgentActionRecord.make(
            sql: "SELECT 1", assessment: assessment("SELECT 1"), context: context, outcome: .generated
        )
        let second = AgentActionRecord.make(
            sql: "DROP TABLE t", assessment: assessment("DROP TABLE t"), context: context, outcome: .pendingApproval
        )
        try await log.append(first)
        try await log.append(second)

        let entries = try await log.entries()
        XCTAssertEqual(entries.map(\.id), [first.id, second.id], "应当按写入顺序返回")

        // 换一个实例读同一个文件：落盘生效。
        let reopened = AgentAuditLog(directoryURL: directory)
        let reopenedEntries = try await reopened.entries()
        XCTAssertEqual(reopenedEntries.count, 2)

        try await log.removeAll()
        let afterRemoval = try await log.entries()
        XCTAssertTrue(afterRemoval.isEmpty)
    }

    func testAuditExportJSONIsAnArray() async throws {
        let directory = try makeDirectory()
        let log = AgentAuditLog(directoryURL: directory)
        try await log.append(
            AgentActionRecord.make(sql: "SELECT 1", assessment: assessment("SELECT 1"), outcome: .generated)
        )

        let data = try await log.exportJSON()
        let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]

        XCTAssertEqual(array?.count, 1)
        XCTAssertEqual(array?.first?["sql"] as? String, "SELECT 1")
        XCTAssertEqual(array?.first?["statementKind"] as? String, "readQuery")
    }

    func testAuditExportCSVHasHeaderAndEscapesFields() async throws {
        let directory = try makeDirectory()
        let log = AgentAuditLog(directoryURL: directory)
        try await log.append(
            AgentActionRecord.make(
                sql: "SELECT a, b FROM t",
                assessment: assessment("SELECT a, b FROM t"),
                context: context,
                outcome: .generated
            )
        )

        let csv = try await log.exportCSV()
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("timestamp,connection,database,model"))
        // 含逗号的 SQL 必须被引号包裹，否则列会错位。
        XCTAssertTrue(lines[1].contains("\"SELECT a, b FROM t\""))
        XCTAssertTrue(lines[1].contains("DemoPG"))
    }

    // MARK: - 导出脱敏（NFR-AI-03）

    func testExportRedactsSecretsAppearingInAuditContent() async throws {
        let directory = try makeDirectory()
        let log = AgentAuditLog(directoryURL: directory)

        // 模拟「SQL 文本或失败信息里夹带了密钥」的最坏情况。
        let leaky = AgentActionRecord.make(
            sql: "SELECT * FROM t WHERE token = 'sk-abcdef1234567890'",
            assessment: assessment("SELECT * FROM t WHERE token = 'sk-abcdef1234567890'"),
            context: context,
            outcome: .failed,
            detail: "调用失败：Authorization: Bearer sk-abcdef1234567890, api_key=deadbeefdeadbeef"
        )
        try await log.append(leaky)

        let json = String(data: try await log.exportJSON(), encoding: .utf8) ?? ""
        let csv = try await log.exportCSV()

        for exported in [json, csv] {
            XCTAssertFalse(exported.contains("sk-abcdef1234567890"), "导出里不得出现密钥")
            XCTAssertFalse(exported.contains("deadbeefdeadbeef"))
            XCTAssertTrue(exported.contains(AgentAudit.redactionPlaceholder))
        }

        // 原始记录仍在本地（审计不以牺牲完整性为代价，只是导出时脱敏）。
        let entries = try await log.entries()
        XCTAssertTrue(entries.first?.sql.contains("sk-abcdef1234567890") ?? false)
    }

    func testRedactionPatterns() {
        // 策略：把「标签 + 密钥」整段抹掉，连字段名都不留，避免给出猜测线索；
        // 密钥之外的前后文照常保留，审计仍然可读。
        XCTAssertEqual(AgentAudit.redacted("Bearer sk-abcdef1234567890"), "[REDACTED]")
        XCTAssertEqual(AgentAudit.redacted("token: sk-abcdef1234567890"), "[REDACTED]")
        XCTAssertEqual(AgentAudit.redacted("api_key=deadbeefdeadbeef"), "[REDACTED]")
        XCTAssertEqual(AgentAudit.redacted(#""apiKey":"sk-1234567890abcdef""#), #""[REDACTED]""#)
        XCTAssertEqual(AgentAudit.redacted("password = hunter2hunter2"), "[REDACTED]")
        XCTAssertEqual(
            AgentAudit.redacted("连接失败：Bearer sk-abcdef1234567890（已重试）"),
            "连接失败：[REDACTED]（已重试）"
        )
    }

    /// 脱敏不能误伤正常内容。
    func testRedactionLeavesOrdinaryTextAlone() {
        let ordinary = "SELECT id, total FROM orders WHERE created_at > now() - interval '7 days'"

        XCTAssertEqual(AgentAudit.redacted(ordinary), ordinary)
        XCTAssertFalse(AgentAudit.containsSecretLikeText(ordinary))
    }

    /// 审计记录里没有密钥字段：导出的键集合是白名单。
    func testExportedRecordHasNoSecretBearingKeys() async throws {
        let directory = try makeDirectory()
        let log = AgentAuditLog(directoryURL: directory)
        try await log.append(
            AgentActionRecord.make(sql: "SELECT 1", assessment: assessment("SELECT 1"), outcome: .generated)
        )

        let data = try await log.exportJSON()
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let keys = Set(try XCTUnwrap(array.first).keys)

        // nil 可选字段会被 JSONEncoder 省略，因此断言「允许集合的子集 + 必填集合的超集」。
        let allowed: Set<String> = [
            "id", "timestamp", "connectionName", "database", "model",
            "sql", "statementKind", "risk", "findings", "outcome", "detail"
        ]
        XCTAssertTrue(keys.isSubset(of: allowed), "出现了白名单外的字段：\(keys.subtracting(allowed))")
        XCTAssertTrue(keys.isSuperset(of: ["id", "timestamp", "sql", "statementKind", "risk", "findings", "outcome"]))
        for forbidden in ["apiKey", "api_key", "token", "password", "secret"] {
            XCTAssertFalse(keys.contains(forbidden))
        }
    }

    func testOutcomesExposeReadableNames() {
        for outcome in AgentActionRecord.Outcome.allCases {
            XCTAssertFalse(outcome.displayName.isEmpty)
        }
        for state in AgentApprovalState.allCases {
            XCTAssertFalse(state.displayName.isEmpty)
        }
        XCTAssertTrue(AgentApprovalError.notApproved(.pending).localizedDescription.contains("待批准"))
    }

    // MARK: - 从审计日志恢复待审批（FR-AI-09）

    /// 测试用的待审批单（走真实工厂：高危语句 → `.pending`）。
    private func pendingApproval(sql: String) throws -> AgentApproval {
        try XCTUnwrap(
            AgentApproval.request(sql: sql, assessment: assessment(sql), context: context)
        )
    }

    /// 重启后待审批队列为空，但日志里「待批准」那条还挂着：按它恢复。
    func testPendingApprovalsAreRebuiltFromAuditRecords() throws {
        let approval = try pendingApproval(sql: "DROP TABLE orders")

        let restored = AgentApproval.pending(from: [approval.record])

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, approval.id)
        XCTAssertEqual(restored.first?.state, .pending)
        XCTAssertTrue(restored.first?.awaitsHumanDecision ?? false)
        XCTAssertEqual(restored.first?.record, approval.record)
        XCTAssertEqual(restored.first?.createdAt, approval.record.timestamp)
    }

    /// 已决策的动作不能被重新摆回审批队列：同一 id 取**最后一条**记录。
    func testDecidedApprovalIsNotRestored() throws {
        var approved = try pendingApproval(sql: "DROP TABLE orders")
        try approved.approve(by: "alex")
        try approved.markExecuted()

        let restored = AgentApproval.pending(from: [approved.record])

        XCTAssertTrue(restored.isEmpty, "已执行的动作不该再要求审批")
    }

    /// 日志里同一条动作的「待批准 + 已拒绝」两条记录：取最后一条 = 已拒绝。
    func testLastRecordWinsForTheSameAction() throws {
        var rejected = try pendingApproval(sql: "TRUNCATE orders")
        let pendingSnapshot = rejected.record
        try rejected.reject(by: "alex", note: "生产库不允许")

        let restored = AgentApproval.pending(from: [pendingSnapshot, rejected.record])

        XCTAssertTrue(restored.isEmpty)
    }

    /// 恢复的顺序与出现的先后一致，互不干扰；非待审批的记录被跳过。
    func testRestoreKeepsDistinctActionsInOrder() throws {
        let first = try pendingApproval(sql: "DROP TABLE a")
        let second = try pendingApproval(sql: "DROP TABLE b")
        let executed = AgentActionRecord.make(
            sql: "SELECT 1", assessment: assessment("SELECT 1"), context: context, outcome: .executed
        )

        let restored = AgentApproval.pending(from: [first.record, executed, second.record])

        XCTAssertEqual(restored.map(\.id), [first.id, second.id])
        XCTAssertTrue(AgentApproval.pending(from: []).isEmpty)
    }

    // MARK: - 模型调用留痕（NFR-AI-03：模型 / 请求摘要 / 耗时 / 结果状态）

    func testModelCallRecordCarriesModelSummaryOutcomeAndDuration() throws {
        let record = AgentActionRecord.makeModelCall(
            requestSummary: "把订单表里 7 月的金额按客户汇总",
            model: "qwen2.5:7b",
            context: context,
            durationMilliseconds: 1234,
            outcome: .generated
        )

        XCTAssertEqual(record.model, "qwen2.5:7b", "模型名必须留存")
        XCTAssertEqual(record.sql, "把订单表里 7 月的金额按客户汇总", "请求摘要放在语句列")
        XCTAssertEqual(record.outcome, .generated)
        XCTAssertEqual(record.durationMilliseconds, 1234, "耗时必须留存")
        XCTAssertEqual(record.connectionName, context.connectionName)
        XCTAssertEqual(record.database, context.database)
        // 模型调用没有语句可判 —— 不是漏判，而是本来就没有语句
        XCTAssertEqual(record.statementKind, .unknown)
        XCTAssertEqual(record.risk, .low)
        XCTAssertTrue(record.detail?.contains("模型调用") == true, "附注要写明这是模型调用")
        XCTAssertEqual(record.resolvedOrigin, .modelCall, "必须显式标出来源，界面才不会显示成「无法识别的语句」")
    }

    func testModelCallWithoutModelFallsBackToContext() throws {
        let record = AgentActionRecord.makeModelCall(
            requestSummary: "x", model: nil, context: context,
            durationMilliseconds: 10, outcome: .generated
        )
        XCTAssertEqual(record.model, "qwen2.5:7b", "模型名缺省时取上下文里的")
    }

    func testModelCallFailureKeepsReasonAlongsideTheMarker() throws {
        let record = AgentActionRecord.makeModelCall(
            requestSummary: "x", model: nil, context: context,
            durationMilliseconds: 20, outcome: .failed, detail: "请求超时"
        )
        let detail = try XCTUnwrap(record.detail)
        XCTAssertTrue(detail.contains("模型调用"), "不能因为失败原因把「这是模型调用」挤掉")
        XCTAssertTrue(detail.contains("请求超时"))
    }

    func testRequestSummaryIsFlattenedAndTruncated() {
        let long = String(repeating: "a", count: AgentActionRecord.requestSummaryLimit + 50)
        let summary = AgentActionRecord.summaryText("第一行\n\n第二行   内容 " + long)

        XCTAssertFalse(summary.contains("\n"))
        XCTAssertFalse(summary.contains("  "))
        XCTAssertTrue(summary.hasPrefix("第一行 第二行 内容"))
        XCTAssertTrue(summary.hasSuffix("…"), "超长必须截断并给出省略号")
        XCTAssertEqual(summary.count, AgentActionRecord.requestSummaryLimit + 1)
    }

    func testShortRequestSummaryIsUntouched() {
        XCTAssertEqual(AgentActionRecord.summaryText("SELECT 1"), "SELECT 1")
    }

    /// T-51 时代写下的审计行没有 `duration_ms` 字段，**必须照旧能读** ——
    /// 否则升级后老日志会被静默丢弃，审计出现空洞。
    func testRecordWithoutDurationFieldStillDecodes() throws {
        let original = AgentActionRecord.make(
            sql: "SELECT 1", assessment: assessment("SELECT 1"), context: context, outcome: .generated
        )
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        object.removeValue(forKey: "durationMilliseconds")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentActionRecord.self, from: legacy)

        XCTAssertNil(decoded.durationMilliseconds, "缺字段应当解成 nil 而不是抛错")
        XCTAssertNil(decoded.origin, "老日志没有来源字段")
        XCTAssertEqual(decoded.resolvedOrigin, .action, "缺字段一律按「动作提交」解释")
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.sql, original.sql)
    }

    /// 顺带确认新字段确实落盘：写完再换实例读回来，耗时还在。
    func testDurationSurvivesAppendAndReopen() async throws {
        let directory = try makeDirectory()
        let log = AgentAuditLog(directoryURL: directory)
        let record = AgentActionRecord.makeModelCall(
            requestSummary: "汇总 7 月金额", model: "qwen2.5:7b", context: context,
            durationMilliseconds: 4321, outcome: .generated
        )
        try await log.append(record)

        let reopened = AgentAuditLog(directoryURL: directory)
        let entries = try await reopened.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.durationMilliseconds, 4321)
    }
}
