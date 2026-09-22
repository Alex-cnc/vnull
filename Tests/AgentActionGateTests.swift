import XCTest
@testable import DoyahCore

/// FR-AI-09：智能体动作的提交闸门（只读模式 / 白名单 / 逐次审批）。
///
/// 这里测的是「界面接上去之后，智能体动作到底会走哪条路」：
/// 被拒 → 连审批单都没有；写操作 → 待审批；只读 / 白名单 → 放行但留痕。
final class AgentActionGateTests: XCTestCase {

    private let context = AgentActionRecord.Context(
        connectionName: "DemoPG", database: "appdb", model: "qwen2.5:7b"
    )

    /// 「写操作逐次批准」的策略：只读关闭，两道审批闸门都开。
    private var writable: AgentGuardPolicy {
        AgentGuardPolicy(readOnly: false, requireApprovalForHighRisk: true, requireApprovalForWrites: true)
    }

    private func submit(_ sql: String, policy: AgentGuardPolicy) -> AgentActionSubmission {
        AgentActionGate.submit(sql: sql, databaseType: .postgresql, policy: policy, context: context)
    }

    // MARK: - 只读模式（AC-AI-02）

    /// 只读模式下，写操作 / DDL 一律被拒，**并且连审批单都建不出来**。
    func testReadOnlyModeDeniesWritesWithoutCreatingApproval() {
        let statements = [
            "INSERT INTO orders (id) VALUES (1)",
            "UPDATE orders SET total = 0 WHERE id = 1",
            "DELETE FROM orders WHERE id = 1",
            "CREATE TABLE orders (id int)",
            "ALTER TABLE orders ADD COLUMN b int",
            "DROP TABLE orders",
            "TRUNCATE TABLE orders",
            "GRANT SELECT ON orders TO app",
            "REVOKE SELECT ON orders FROM app"
        ]

        for sql in statements {
            let submission = submit(sql, policy: .readOnlyDefault)

            XCTAssertTrue(submission.isDenied, "只读模式下应当被拒：\(sql)")
            XCTAssertFalse(submission.awaitsApproval, "被拒的语句不该进审批队列：\(sql)")
            XCTAssertNil(submission.approval, "被拒的语句连审批单都建不出来：\(sql)")
            XCTAssertEqual(submission.record.outcome, .denied)
            XCTAssertEqual(submission.record.connectionName, "DemoPG")
            XCTAssertFalse(
                submission.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "拒绝必须给出可读原因：\(sql)"
            )
            XCTAssertFalse(submission.record.statementKind.isReadOnly)
        }
    }

    /// 只读查询在只读模式下照常放行，但**同样留痕**（NFR-AI-03）。
    func testReadOnlyModeAllowsReadQueryAndStillRecordsIt() {
        let submission = submit("SELECT * FROM orders", policy: .readOnlyDefault)

        guard case .approved(let approval) = submission else {
            return XCTFail("只读查询应当放行，实际：\(submission)")
        }
        XCTAssertEqual(approval.state, .approved)
        XCTAssertEqual(approval.decidedBy, "auto", "无需人工决定")
        XCTAssertEqual(approval.record.outcome, .approved)
        XCTAssertEqual(approval.record.statementKind, .readQuery)
        XCTAssertEqual(approval.record.risk, .low)
    }

    // MARK: - 逐次审批（FR-AI-09）

    /// 写操作（即使没有风险点）一律进待审批，且**未批准不得执行**。
    func testPlainWriteBecomesPendingApproval() {
        let submission = submit("INSERT INTO orders (id) VALUES (1)", policy: writable)

        guard case .awaitingApproval(let approval) = submission else {
            return XCTFail("写操作应当待审批，实际：\(submission)")
        }
        XCTAssertEqual(approval.state, .pending)
        XCTAssertTrue(approval.awaitsHumanDecision)
        XCTAssertFalse(approval.canExecute, "批准之前不得执行")
        XCTAssertEqual(approval.record.outcome, .pendingApproval)
        XCTAssertEqual(approval.record.statementKind, .dataChange)
        XCTAssertEqual(approval.record.detail, AgentGuardFinding.writeStatement.message)
    }

    /// 高危语句待审批时带上具体风险点（NFR-AI-12：为什么被拦要说得出来）。
    func testHighRiskWriteCarriesFindings() {
        let submission = submit("DROP TABLE orders", policy: writable)

        guard case .awaitingApproval(let approval) = submission else {
            return XCTFail("DROP 应当待审批，实际：\(submission)")
        }
        XCTAssertEqual(approval.record.risk, .destructive)
        XCTAssertEqual(approval.record.findings, [.dropStatement])
        XCTAssertTrue(approval.record.detail?.contains("DROP") ?? false)
    }

    /// 白名单类别免审批，但仍然是「已生成 / 已批准」的一条记录。
    func testAllowlistedKindSkipsApprovalButIsStillRecorded() {
        let policy = AgentGuardPolicy(
            readOnly: false,
            requireApprovalForHighRisk: true,
            requireApprovalForWrites: true,
            allowedKinds: [.schemaChange]
        )
        let submission = submit("DROP TABLE orders", policy: policy)

        guard case .approved(let approval) = submission else {
            return XCTFail("白名单类别应当放行，实际：\(submission)")
        }
        XCTAssertEqual(approval.state, .approved)
        XCTAssertEqual(submission.record.statementKind, .schemaChange)
        XCTAssertEqual(submission.record.outcome, .approved)
    }

    /// 白名单不能突破只读模式。
    func testAllowlistNeverBypassesReadOnlyMode() {
        let policy = AgentGuardPolicy(
            readOnly: true,
            requireApprovalForHighRisk: true,
            requireApprovalForWrites: true,
            allowedKinds: [.schemaChange, .dataChange, .privilegeChange]
        )

        XCTAssertTrue(submit("DROP TABLE orders", policy: policy).isDenied)
        XCTAssertNil(submit("DROP TABLE orders", policy: policy).approval)
    }

    /// 手改配置文件把 `unknown` 塞进白名单也不生效（闸门里再归一化一次）。
    func testUnknownAllowlistIsSanitizedAtSubmission() {
        let policy = AgentGuardPolicy(
            readOnly: false,
            requireApprovalForHighRisk: true,
            requireApprovalForWrites: true,
            allowedKinds: [.unknown]
        )

        guard case .awaitingApproval(let approval) = submit("FLUMMOX THE DATABASE", policy: policy) else {
            return XCTFail("无法归类的语句必须待审批")
        }
        XCTAssertEqual(approval.record.findings, [.unknownStatement])
    }

    /// 只读模式优先于「写操作放行」：两个开关同时打开时，只读说了算。
    func testReadOnlyWinsOverWritablePolicy() {
        let policy = AgentGuardPolicy(readOnly: true, requireApprovalForHighRisk: false, requireApprovalForWrites: false)

        XCTAssertTrue(submit("INSERT INTO orders (id) VALUES (1)", policy: policy).isDenied)
    }

    // MARK: - 记录与消息

    func testSubmissionMessagesAreReadable() {
        let denied = submit("DROP TABLE orders", policy: .readOnlyDefault)
        XCTAssertTrue(denied.message.contains("只读模式"))

        let pending = submit("INSERT INTO orders (id) VALUES (1)", policy: writable)
        XCTAssertTrue(pending.message.contains("批准"))

        let allowed = submit("SELECT 1", policy: writable)
        XCTAssertTrue(allowed.message.contains("无需审批"))
    }

    /// 每条提交都带着「哪台连接 / 哪个库 / 哪个模型」，且**没有密钥字段**。
    func testSubmissionRecordCarriesContextWithoutSecrets() throws {
        let submission = submit("INSERT INTO orders (id) VALUES (1)", policy: writable)
        let record = submission.record

        XCTAssertEqual(record.connectionName, "DemoPG")
        XCTAssertEqual(record.database, "appdb")
        XCTAssertEqual(record.model, "qwen2.5:7b")

        // 导出（已脱敏）里不得出现密钥字段名。
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(record), as: UTF8.self).lowercased()
        for forbidden in ["apikey", "api_key", "password", "secret", "token"] {
            XCTAssertFalse(json.contains(forbidden), "审计记录里出现了疑似密钥字段：\(forbidden)")
        }
    }

    /// 提交出去的记录能被审批状态机接住：待审批 → 已批准 → 已执行。
    func testPendingSubmissionCanBeApprovedAndExecuted() throws {
        guard case .awaitingApproval(let approval) = submit("DROP TABLE orders", policy: writable) else {
            return XCTFail("DROP 应当待审批")
        }

        var working = approval
        try working.approve(by: "alex", note: "测试库")
        XCTAssertTrue(working.canExecute)
        try working.markExecuted()

        XCTAssertEqual(working.state, .executed)
        XCTAssertEqual(working.record.outcome, .executed)
        XCTAssertEqual(working.decidedBy, "alex")
    }
}
