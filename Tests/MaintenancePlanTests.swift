import XCTest
@testable import DoyahCore

/// FR-AI-04 的 Core 半边：计划解析 + 审阅（逐条审批 / 限流 / 只读拒写 / 沙箱外部程序）+ 状态机。
///
/// **不需要模型端点**：模型给的计划用文本代替 —— 这一层判的是"给了这个计划，我们怎么办"。
final class MaintenancePlanTests: XCTestCase {

    private let planText = """
    # 一个"什么都有"的计划
    task: analyze | 更新统计信息 | sql: ANALYZE public.customers
    task: vacuum | 整理膨胀 | sql: VACUUM (ANALYZE) public.orders
    task: reindex | 重建索引 | sql: REINDEX INDEX public.idx_orders_customer
    task: backup | 备份 analytics 库 | command: pg_dump -Fc analytics
    task: indexSuggestion | 建议加索引 | sql: CREATE INDEX ON public.orders (created_at)
    task: grant | 给报表账号只读权限 | sql: GRANT SELECT ON public.orders TO reporting
    """

    private func plan(policy: MaintenancePolicy = MaintenancePolicy()) -> MaintenancePlanReview {
        MaintenancePlanner.makePlan(from: planText, policy: policy)
    }

    // MARK: - 解析

    func testParseRecognisesKindsAndPayloads() {
        let parsed = MaintenancePlanner.parse(planText)
        XCTAssertEqual(parsed.tasks.map(\.kind), [.analyze, .vacuum, .reindex, .backup, .indexSuggestion, .grant])
        XCTAssertEqual(parsed.tasks[0].sql, "ANALYZE public.customers")
        XCTAssertEqual(parsed.tasks[3].command, "pg_dump -Fc analytics")
        XCTAssertEqual(parsed.tasks[3].kind.runsInProcess, false)
        XCTAssertTrue(parsed.unparsable.isEmpty, "注释行与空行不该被当成看不懂的行：\(parsed.unparsable)")
    }

    /// 认不出的行**原样保留**（在维护任务这个场景里，静默丢掉一行可能丢掉一个 `DROP`）。
    func testParseKeepsUnrecognisedLines() {
        let parsed = MaintenancePlanner.parse("想删掉一张表\ntask: analyze | 更新统计 | sql: ANALYZE t")
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.unparsable, ["想删掉一张表"])
    }

    func testEmptyOrMalformedKindIsUnparsable() {
        let parsed = MaintenancePlanner.parse("task: dropEverything | 删库 | sql: DROP DATABASE x")
        XCTAssertTrue(parsed.tasks.isEmpty, "不认识的类别不该被猜成别的类别")
        XCTAssertEqual(parsed.unparsable.count, 1)
    }

    // MARK: - 审阅：审批是**前置**，不是提醒

    func testEveryWriteTaskRequiresApprovalButSuggestionDoesNot() {
        let review = plan()
        let byKind = Dictionary(uniqueKeysWithValues: review.tasks.map { ($0.kind, $0) })
        for kind in [MaintenanceTaskKind.analyze, .vacuum, .grant] {
            XCTAssertTrue(byKind[kind]!.requiresApproval, "\(kind) 是写操作，必须审批")
            XCTAssertEqual(byKind[kind]!.state, .pending, "\(kind) 未被批准前必须停在 pending")
        }
        XCTAssertFalse(byKind[.indexSuggestion]!.requiresApproval, "索引建议只给语句，不改库")
    }

    /// **未批准 = 不可执行**：执行入口只收已批准的任务（类型上的约束，不是纪律口号）。
    func testUnapprovedTasksAreNotExecutable() {
        let review = plan()
        XCTAssertTrue(review.executableTasks(isSandboxed: false).isEmpty)
        let approved = MaintenancePlanner.approve(review, ids: ["m1"])
        XCTAssertEqual(approved.executableTasks(isSandboxed: false).map(\.id), ["m1"])
        XCTAssertGreaterThan(approved.pendingApproval.count, 0)
    }

    func testRejectedTaskStaysVisibleInThePlan() {
        let rejected = MaintenancePlanner.reject(plan(), ids: ["m2"])
        XCTAssertEqual(rejected.tasks.first { $0.id == "m2" }?.state, .rejected)
        XCTAssertTrue(rejected.executableTasks(isSandboxed: false).isEmpty)
        XCTAssertEqual(rejected.tasks.count, 6, "拒绝了什么要留在计划里看得见")
    }

    // MARK: - 限流与连接属性

    /// 高开销任务默认**一次只放一条**（`REINDEX` 会长时间持锁、备份会读全库）。
    func testHighCostTasksAreRateLimited() {
        let review = plan()
        let highCost = review.tasks.filter(\.isHighCost)
        XCTAssertEqual(highCost.map(\.id), ["m3", "m4"])
        XCTAssertEqual(review.tasks.first { $0.id == "m3" }?.state, .pending)
        XCTAssertEqual(review.tasks.first { $0.id == "m4" }?.state, .rejected, "第二条高开销应当被限流拒绝")
        XCTAssertTrue(
            review.tasks.first { $0.id == "m4" }!.reviewNotes.contains { $0.contains("高开销") }
                || review.tasks.first { $0.id == "m4" }!.reviewNotes.contains { $0.contains("限流") },
            "限流要写明理由：\(review.tasks.first { $0.id == "m4" }!.reviewNotes)"
        )
    }

    func testExplicitOverrideAllowsMultipleHighCost() {
        let review = plan(policy: MaintenancePolicy(allowMultipleHighCost: true))
        XCTAssertEqual(review.tasks.first { $0.id == "m4" }?.state, .pending)
    }

    /// 只读连接：写任务**连批准都不允许**（不可绕过，与 `ExecutionSafety` 同一条口径）。
    func testReadOnlyConnectionRefusesWritesAndCannotApproveThem() {
        let review = plan(policy: MaintenancePolicy(isReadOnly: true))
        for id in ["m1", "m2", "m3", "m6"] {
            XCTAssertEqual(review.tasks.first { $0.id == id }?.state, .rejected, "\(id) 在只读连接上必须被拒")
        }
        let attempted = MaintenancePlanner.approve(review, ids: ["m1", "m2"])
        XCTAssertTrue(attempted.executableTasks(isSandboxed: false).isEmpty, "被拒的任务不会因为'批准'而复活")
    }

    /// 沙箱构建：外部程序类任务**不可执行**，且理由要写在任务上（R-18）。
    func testSandboxedBuildBlocksExternalProgramTasks() {
        // 单独一份"只有备份"的计划：上面那份里备份已被限流拒绝，测不到沙箱这条规则。
        let onlyBackup = MaintenancePlanner.makePlan(
            from: "task: backup | 备份 analytics 库 | command: pg_dump -Fc analytics",
            policy: MaintenancePolicy(isSandboxed: true)
        )
        let approved = MaintenancePlanner.approve(onlyBackup, ids: ["m1"])
        XCTAssertEqual(
            approved.executableTasks(isSandboxed: false).map(\.id), ["m1"],
            "非沙箱构建下外部程序可以跑"
        )
        XCTAssertTrue(approved.executableTasks(isSandboxed: true).isEmpty, "沙箱构建下 pg_dump 起不来（R-18）")
        XCTAssertTrue(
            approved.tasks.first!.reviewNotes.contains { $0.contains("沙箱") || $0.contains("外部程序") },
            "理由要写在任务上：\(approved.tasks.first!.reviewNotes)"
        )
    }

    // MARK: - 风险分类与状态机

    func testRiskClassificationIsHonestAboutBackups() {
        let review = plan()
        // 备份的"破坏性"不在 SQL 关键字上，而在"它动的是整个数据库"。
        XCTAssertEqual(review.tasks.first { $0.kind == .backup }?.risk, .destructive)
        XCTAssertEqual(review.tasks.first { $0.kind == .analyze }?.risk, .low)
        // 授权调整是 elevated（权限变更）。
        XCTAssertEqual(review.tasks.first { $0.kind == .grant }?.risk, .elevated)
    }

    func testExecutionRecordsSuccessAndFailureWithReasons() {
        var review = MaintenancePlanner.approve(plan(), ids: ["m1", "m2"])
        review = MaintenancePlanner.record(review, taskID: "m1")
        review = MaintenancePlanner.record(review, taskID: "m2", failureReason: "锁等待超时")
        XCTAssertEqual(review.tasks.first { $0.id == "m1" }?.state, .executed)
        XCTAssertEqual(review.tasks.first { $0.id == "m2" }?.state, .failed(reason: "锁等待超时"))
        // 失败的任务不能因为再批准一次就"复活"。
        let again = MaintenancePlanner.approve(review, ids: ["m2"])
        XCTAssertEqual(again.tasks.first { $0.id == "m2" }?.state, .failed(reason: "锁等待超时"))
    }

    /// 危险语句走的是同一条护栏（`DROP` 的计划任务不该被当成"普通维护"）。
    func testDangerousStatementKeepsItsRiskFromGuardrail() {
        let text = "task: custom | 清掉旧数据 | sql: DELETE FROM public.audit_log"
        let review = MaintenancePlanner.makePlan(from: text, policy: MaintenancePolicy())
        XCTAssertEqual(review.tasks.first?.risk, .destructive, "无 WHERE 的 DELETE 是破坏性语句")
        XCTAssertTrue(review.tasks.first!.requiresApproval)
        XCTAssertTrue(
            review.tasks.first!.reviewNotes.contains { $0.contains("WHERE") || $0.contains("破坏") || $0.contains("无") }
        )
    }
}
