import XCTest
@testable import PostgresClientCore

/// FR-AI-05 / FR-AI-06：specs → 数据任务模型、试运行预览、调度骨架与执行历史。
final class DataTaskTests: XCTestCase {

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
            .appendingPathComponent("DataTaskTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTask(
        schedule: TaskSchedule = .manual,
        transformations: [DataTaskDefinition.Transformation] = [],
        target: DataTaskDefinition.Target? = nil,
        source: DataTaskDefinition.Source? = nil
    ) -> DataTaskDefinition {
        DataTaskDefinition(
            name: "订单归档",
            specs: "把 30 天前的订单搬到归档表，只保留订单号、客户与金额。",
            source: source ?? .init(schema: "public", table: "orders", columns: ["id", "customer_id", "total"]),
            transformations: transformations,
            target: target ?? .init(schema: "public", table: "orders_archive"),
            schedule: schedule,
            createdAt: epoch,
            updatedAt: epoch
        )
    }

    // MARK: - 定义与校验（FR-AI-05）

    func testSpecsAndDefinitionAreBothRetained() {
        let task = makeTask()

        // 「specs 与生成的任务定义同时留存、均为可编辑文本」。
        XCTAssertEqual(task.specs, "把 30 天前的订单搬到归档表，只保留订单号、客户与金额。")
        XCTAssertTrue(task.isValid)
        XCTAssertEqual(task.source.table, "orders")
        XCTAssertEqual(task.target.table, "orders_archive")
    }

    func testValidationRejectsMissingPieces() {
        var task = makeTask()
        task.name = "  "
        task.specs = ""
        task.source.table = ""
        task.target.table = ""
        XCTAssertTrue(task.issues.contains("任务名不能为空。"))
        XCTAssertTrue(task.issues.contains { $0.contains("规格说明") })
        XCTAssertTrue(task.issues.contains("数据来源表不能为空。"))
        XCTAssertTrue(task.issues.contains("目标表不能为空。"))
        XCTAssertFalse(task.isValid)
    }

    func testValidationOfScheduleCombinations() {
        var once = makeTask(schedule: TaskSchedule(kind: .once))
        XCTAssertTrue(once.issues.contains("一次性任务必须指定执行时间。"))

        once.schedule.runAt = epoch
        XCTAssertTrue(once.isValid)

        var recurring = makeTask(schedule: TaskSchedule(kind: .recurring))
        XCTAssertTrue(recurring.issues.contains("周期任务必须指定执行间隔。"))

        recurring.schedule.intervalSeconds = 0
        XCTAssertTrue(recurring.issues.contains("周期必须为正数。"))

        recurring.schedule.intervalSeconds = 3600
        XCTAssertTrue(recurring.isValid)
    }

    func testUpsertRequiresKeyColumns() {
        var task = makeTask(target: .init(schema: "public", table: "t", writeMode: .upsert))
        XCTAssertTrue(task.issues.contains { $0.contains("冲突键") })

        task.target.keyColumns = ["id"]
        XCTAssertTrue(task.isValid)
    }

    func testTransformationValidation() {
        var task = makeTask(transformations: [.init(kind: .derive, column: nil, expression: "  ")])
        XCTAssertTrue(task.issues.contains("派生列转换缺少表达式。"))

        task.transformations = [.init(kind: .rename, column: nil)]
        XCTAssertTrue(task.issues.contains { $0.contains("缺少源列名") })

        // 表达式里塞语句 → 直接拒绝。
        task.transformations = [.init(kind: .derive, expression: "1); DROP TABLE t; --")]
        XCTAssertTrue(task.issues.contains { $0.contains("形似语句") })

        // 过滤条件里塞语句 → 同样拒绝。
        var filtered = makeTask()
        filtered.source.filter = "1=1; DELETE FROM orders"
        XCTAssertTrue(filtered.issues.contains { $0.contains("过滤条件") })
    }

    // MARK: - 试运行预览（FR-AI-05）

    func testDryRunLaysOutStepsAndPreviewSQL() {
        let task = makeTask(
            transformations: [.init(kind: .mask, column: "customer_id", expression: "md5(customer_id::text)")],
            target: .init(schema: "public", table: "orders_archive", writeMode: .append)
        )

        let dryRun = task.dryRun()

        XCTAssertTrue(dryRun.isRunnable)
        XCTAssertEqual(dryRun.steps.count, 3)
        XCTAssertTrue(dryRun.steps[0].contains(#""public"."orders""#), "实际：\(dryRun.steps[0])")
        XCTAssertTrue(dryRun.steps[1].contains("脱敏"))
        XCTAssertTrue(dryRun.steps[2].contains("追加"))
        // 预览 SQL 只取少量行：试运行本身不能变成重查询。
        XCTAssertTrue(dryRun.previewStatements[0].contains("LIMIT 10"))
        XCTAssertTrue(dryRun.previewStatements[0].hasPrefix("SELECT"))
    }

    func testDryRunOverwriteModeWarnsAboutTruncate() {
        let task = makeTask(target: .init(schema: "public", table: "t", writeMode: .overwrite))

        let dryRun = task.dryRun()

        XCTAssertTrue(dryRun.previewStatements.contains { $0.hasPrefix("TRUNCATE TABLE") })
        XCTAssertEqual(dryRun.warnings.count, 1)
        XCTAssertTrue(dryRun.warnings[0].contains("清空"))
    }

    func testDryRunReportsIssuesInsteadOfPretendingToBeRunnable() {
        var task = makeTask()
        task.source.table = ""

        let dryRun = task.dryRun()
        XCTAssertFalse(dryRun.isRunnable)
        XCTAssertFalse(dryRun.issues.isEmpty)
    }

    func testDryRunUsesDialectQuoting() {
        let task = makeTask(source: .init(schema: "销售", table: "订单", columns: ["客户号"]))

        XCTAssertTrue(task.dryRun(dialect: PostgresDialect()).previewStatements[0].contains(#""销售"."订单""#))
        XCTAssertTrue(task.dryRun(dialect: GBaseDialect()).previewStatements[0].contains("`订单`"))
    }

    // MARK: - 调度（FR-AI-06）

    func testManualTaskIsNeverScheduled() {
        let task = makeTask(schedule: .manual)

        XCTAssertEqual(TaskScheduler.decision(for: task, now: epoch), .notScheduled)
        XCTAssertNil(TaskScheduler.nextRun(for: task, after: epoch))
    }

    func testDisabledTaskReportsDisabled() {
        var task = makeTask(schedule: TaskSchedule(kind: .once, runAt: epoch.addingTimeInterval(60)))
        task.isEnabled = false

        XCTAssertEqual(TaskScheduler.decision(for: task, now: epoch), .disabled)
    }

    func testOnceScheduleDueAndWaiting() {
        let runAt = epoch.addingTimeInterval(3600)
        let task = makeTask(schedule: TaskSchedule(kind: .once, runAt: runAt))

        XCTAssertEqual(TaskScheduler.decision(for: task, now: epoch), .waiting(until: runAt))
        XCTAssertEqual(TaskScheduler.decision(for: task, now: runAt), .due(plannedAt: runAt))
        // 已经跑过就不再排期。
        XCTAssertEqual(TaskScheduler.decision(for: task, now: runAt, lastRun: runAt), .notScheduled)
    }

    /// 一次性任务的窗口被错过：给出明确提示而不是静默跳过或直接补跑。
    func testMissedWindowIsReportedNotSilentlySkipped() {
        let runAt = epoch
        let task = makeTask(schedule: TaskSchedule(kind: .once, runAt: runAt))
        let now = runAt.addingTimeInterval(2 * 3600)

        let decision = TaskScheduler.decision(for: task, now: now)

        guard case .missed(let plannedAt, let overdueBy) = decision else {
            return XCTFail("应当判为错过，实际：\(decision)")
        }
        XCTAssertEqual(plannedAt, runAt)
        XCTAssertEqual(overdueBy, 2 * 3600, accuracy: 1)
        XCTAssertTrue(decision.message.contains("错过"))
        XCTAssertTrue(decision.message.contains("确认"))
    }

    /// 宽限期内仍视为到点（避免刚好晚几秒就要求人工确认）。
    func testGracePeriodKeepsDueStatus() {
        let runAt = epoch
        let task = makeTask(schedule: TaskSchedule(kind: .once, runAt: runAt))
        let now = runAt.addingTimeInterval(30)

        XCTAssertEqual(TaskScheduler.decision(for: task, now: now, grace: 60), .due(plannedAt: runAt))
        XCTAssertFalse(TaskScheduler.decision(for: task, now: now, grace: 10).isDue)
    }

    func testRecurringScheduleSteps() {
        let interval: TimeInterval = 3600
        let task = makeTask(
            schedule: TaskSchedule(kind: .recurring, intervalSeconds: interval, startAt: epoch)
        )

        XCTAssertEqual(TaskScheduler.decision(for: task, now: epoch), .due(plannedAt: epoch))
        XCTAssertEqual(
            TaskScheduler.decision(for: task, now: epoch.addingTimeInterval(30), grace: 60),
            .due(plannedAt: epoch)
        )
        // 跑过第一次后，下一次是 start + interval。
        XCTAssertEqual(
            TaskScheduler.decision(for: task, now: epoch.addingTimeInterval(30), lastRun: epoch),
            .waiting(until: epoch.addingTimeInterval(interval))
        )
        XCTAssertEqual(
            TaskScheduler.nextRun(for: task, after: epoch, lastRun: epoch),
            epoch.addingTimeInterval(interval)
        )
    }

    func testRecurringScheduleDefaultStartIsTaskCreation() {
        let interval: TimeInterval = 600
        let task = makeTask(schedule: TaskSchedule(kind: .recurring, intervalSeconds: interval))

        // 未指定 startAt 时用创建时间。
        XCTAssertEqual(TaskScheduler.decision(for: task, now: epoch), .due(plannedAt: epoch))
    }

    func testMissedRunsEnumeratesWindow() {
        let interval: TimeInterval = 3600
        let task = makeTask(
            schedule: TaskSchedule(kind: .recurring, intervalSeconds: interval, startAt: epoch)
        )
        let from = epoch.addingTimeInterval(interval)
        let to = epoch.addingTimeInterval(4 * interval)

        let missed = TaskScheduler.missedRuns(for: task, from: from, to: to)

        XCTAssertEqual(missed, [
            epoch.addingTimeInterval(interval),
            epoch.addingTimeInterval(2 * interval),
            epoch.addingTimeInterval(3 * interval)
        ])
    }

    func testMissedRunsHonoursLastRunAndLimit() {
        let interval: TimeInterval = 3600
        let task = makeTask(
            schedule: TaskSchedule(kind: .recurring, intervalSeconds: interval, startAt: epoch)
        )

        // 已经跑过前两个点：只剩第三个。
        let missed = TaskScheduler.missedRuns(
            for: task,
            from: epoch,
            to: epoch.addingTimeInterval(3.5 * interval),
            lastRun: epoch.addingTimeInterval(2 * interval)
        )
        XCTAssertEqual(missed, [epoch.addingTimeInterval(3 * interval)])

        // limit 生效：不会算出成千上万个点。
        let capped = TaskScheduler.missedRuns(
            for: task,
            from: epoch,
            to: epoch.addingTimeInterval(1000 * interval),
            limit: 5
        )
        XCTAssertEqual(capped.count, 5)
    }

    func testMissedRunsForOnceSchedule() {
        let task = makeTask(schedule: TaskSchedule(kind: .once, runAt: epoch.addingTimeInterval(600)))

        XCTAssertEqual(
            TaskScheduler.missedRuns(for: task, from: epoch, to: epoch.addingTimeInterval(3600)),
            [epoch.addingTimeInterval(600)]
        )
        XCTAssertTrue(TaskScheduler.missedRuns(for: task, from: epoch, to: epoch).isEmpty)
        XCTAssertTrue(
            TaskScheduler.missedRuns(for: task, from: epoch, to: epoch.addingTimeInterval(3600),
                                     lastRun: epoch.addingTimeInterval(600)).isEmpty
        )
    }

    func testDecisionMessagesAreReadable() {
        XCTAssertTrue(ScheduleDecision.notScheduled.message.contains("未设置"))
        XCTAssertTrue(ScheduleDecision.disabled.message.contains("停用"))
        XCTAssertTrue(ScheduleDecision.waiting(until: epoch).message.contains("下次执行"))
        XCTAssertTrue(ScheduleDecision.due(plannedAt: epoch).message.contains("已到"))
    }

    // MARK: - 执行历史与持久化

    func testRunRecordDuration() {
        var record = TaskRunRecord(taskID: UUID(), startedAt: epoch)
        XCTAssertNil(record.duration)

        record.finishedAt = epoch.addingTimeInterval(12)
        XCTAssertEqual(record.duration, 12)
        XCTAssertFalse(TaskRunRecord.Status.succeeded.displayName.isEmpty)
    }

    func testStoreRoundTripAndHistory() async throws {
        let directory = try makeDirectory()
        let store = DataTaskStore(directoryURL: directory)

        var task = makeTask(schedule: TaskSchedule(kind: .recurring, intervalSeconds: 3600))
        let saved = try await store.save(task)
        XCTAssertEqual(saved.id, task.id)

        task.name = "订单归档（改）"
        try await store.save(task)

        let tasks = try await store.tasks()
        XCTAssertEqual(tasks.count, 1, "同一个 id 应当被替换而不是追加")
        XCTAssertEqual(tasks[0].name, "订单归档（改）")

        try await store.appendRun(TaskRunRecord(taskID: task.id, startedAt: epoch, status: .failed, message: "连接超时"))
        try await store.appendRun(TaskRunRecord(
            taskID: task.id, startedAt: epoch.addingTimeInterval(3600), finishedAt: epoch.addingTimeInterval(3660),
            status: .succeeded, rowsWritten: 120
        ))

        let runs = try await store.runs(for: task.id)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].status, .failed)
        XCTAssertEqual(runs[1].rowsWritten, 120)

        // 调度用：最近一次成功执行时刻。
        let lastSuccess = try await store.lastSuccessfulRun(for: task.id)
        XCTAssertEqual(lastSuccess, epoch.addingTimeInterval(3600))

        try await store.delete(id: task.id)
        let remaining = try await store.tasks()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testStoreIsEmptyWhenFilesAreMissing() async throws {
        let directory = try makeDirectory()
        let store = DataTaskStore(directoryURL: directory)

        let emptyTasks = try await store.tasks()
        let emptyRuns = try await store.runs()
        let missingLastRun = try await store.lastSuccessfulRun(for: UUID())
        XCTAssertTrue(emptyTasks.isEmpty)
        XCTAssertTrue(emptyRuns.isEmpty)
        XCTAssertNil(missingLastRun)
    }

    func testTaskDefinitionCodableRoundTrip() throws {
        let task = makeTask(
            schedule: TaskSchedule(kind: .recurring, intervalSeconds: 900, startAt: epoch),
            transformations: [.init(kind: .cast, column: "total", expression: "numeric(12,2)")],
            target: .init(schema: "public", table: "t", writeMode: .upsert, keyColumns: ["id"])
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(DataTaskDefinition.self, from: try encoder.encode(task))

        XCTAssertEqual(restored, task)
        XCTAssertEqual(restored.specs, task.specs)
    }

    /// 导出设置里的目录书签只是字节，不参与校验（T-55 负责生成与解析）。
    func testExportSettingsDoNotAffectValidation() {
        var task = makeTask()
        task.output = .init(format: .csv, directoryBookmark: Data([0x01, 0x02]), fileNameTemplate: "orders-{date}.csv")

        XCTAssertTrue(task.isValid)
    }
}
