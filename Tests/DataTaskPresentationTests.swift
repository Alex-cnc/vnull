import XCTest
@testable import PostgresClientCore

/// FR-AI-05 / FR-AI-06：数据任务面板的纯逻辑（调度状态映射、执行记录展示、列表筛选）。
final class DataTaskPresentationTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTask(
        name: String = "订单归档",
        enabled: Bool = true,
        writeMode: DataTaskDefinition.Target.WriteMode = .append,
        sourceTable: String = "orders",
        targetTable: String = "orders_archive",
        specs: String = "把订单搬到归档表。",
        schedule: TaskSchedule = .manual
    ) -> DataTaskDefinition {
        DataTaskDefinition(
            name: name,
            specs: specs,
            source: .init(schema: "public", table: sourceTable, columns: ["id"]),
            target: .init(schema: "public", table: targetTable, writeMode: writeMode),
            schedule: schedule,
            isEnabled: enabled,
            createdAt: epoch,
            updatedAt: epoch
        )
    }

    // MARK: - 调度状态映射

    func testDecisionMapsToPanelStatus() {
        let task = makeTask()

        XCTAssertEqual(DataTaskPresentation.status(for: .notScheduled), .notScheduled)
        XCTAssertEqual(DataTaskPresentation.status(for: .disabled), .disabled)
        XCTAssertEqual(
            DataTaskPresentation.status(for: .waiting(until: epoch)),
            .waiting
        )
        XCTAssertEqual(DataTaskPresentation.status(for: .due(plannedAt: epoch)), .due)
        XCTAssertEqual(
            DataTaskPresentation.status(for: .missed(plannedAt: epoch, overdueBy: 600)),
            .missed
        )
        // 判定本身仍由 Core 的调度器给出（这里只做界面投影，不改语义）。
        XCTAssertEqual(
            DataTaskPresentation.status(for: TaskScheduler.decision(for: task, now: epoch)),
            .notScheduled
        )
    }

    func testPlannedAndOverdueValues() {
        XCTAssertEqual(DataTaskPresentation.plannedAt(.waiting(until: epoch)), epoch)
        XCTAssertEqual(DataTaskPresentation.plannedAt(.due(plannedAt: epoch)), epoch)
        XCTAssertEqual(DataTaskPresentation.plannedAt(.missed(plannedAt: epoch, overdueBy: 10)), epoch)
        XCTAssertNil(DataTaskPresentation.plannedAt(.disabled))

        // 不足一分钟按 1 分钟算：显示「晚了约 0 分钟」会让人以为没晚。
        XCTAssertEqual(DataTaskPresentation.overdueMinutes(.missed(plannedAt: epoch, overdueBy: 5)), 1)
        XCTAssertEqual(DataTaskPresentation.overdueMinutes(.missed(plannedAt: epoch, overdueBy: 600)), 10)
        XCTAssertNil(DataTaskPresentation.overdueMinutes(.due(plannedAt: epoch)))
    }

    func testNextRunTextOnlyForScheduledEnabledTasks() {
        let recurring = makeTask(schedule: TaskSchedule(kind: .recurring, intervalSeconds: 3600))
        let text = DataTaskPresentation.nextRunText(for: recurring, lastRun: nil, now: epoch)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("20"))

        // 手动任务没有下一次；停用任务也没有。
        XCTAssertNil(DataTaskPresentation.nextRunText(for: makeTask(), lastRun: nil, now: epoch))
        XCTAssertNil(
            DataTaskPresentation.nextRunText(for: makeTask(enabled: false, schedule: TaskSchedule(kind: .recurring, intervalSeconds: 60)), lastRun: nil, now: epoch)
        )
    }

    // MARK: - 执行记录

    func testLatestRunAndDurationFormatting() {
        let taskID = UUID()
        let other = UUID()
        let runs = [
            TaskRunRecord(id: UUID(), taskID: other, startedAt: epoch, status: .succeeded),
            TaskRunRecord(id: UUID(), taskID: taskID, startedAt: epoch, status: .failed, message: "连接失败"),
            TaskRunRecord(id: UUID(), taskID: taskID, startedAt: epoch.addingTimeInterval(60), status: .succeeded)
        ]

        let latest = DataTaskPresentation.latestRun(for: taskID, in: runs)

        XCTAssertEqual(latest?.status, .succeeded)
        XCTAssertNil(DataTaskPresentation.latestRun(for: UUID(), in: runs))

        XCTAssertEqual(DataTaskPresentation.durationText(0.25), "250 ms")
        XCTAssertEqual(DataTaskPresentation.durationText(2.5), "2.5 s")
        XCTAssertEqual(DataTaskPresentation.durationText(125), "2 min 5 s")
        XCTAssertEqual(DataTaskPresentation.durationText(nil), "—")
        XCTAssertEqual(DataTaskPresentation.rowsText(12), "12")
        XCTAssertEqual(DataTaskPresentation.rowsText(nil), "—")
    }

    // MARK: - 列表筛选

    func testFilterMatchesNameSpecsAndTables() {
        let tasks = [
            makeTask(name: "订单归档", sourceTable: "orders", targetTable: "orders_archive"),
            makeTask(name: "客户同步", sourceTable: "customers", targetTable: "customers_dw", specs: "每小时同步客户")
        ]

        XCTAssertEqual(DataTaskPresentation.filter(tasks).count, 2)
        XCTAssertEqual(DataTaskPresentation.filter(tasks, query: "归档").map(\.name), ["订单归档"])
        XCTAssertEqual(DataTaskPresentation.filter(tasks, query: "CUSTOMERS").map(\.name), ["客户同步"])
        XCTAssertEqual(DataTaskPresentation.filter(tasks, query: "客户").map(\.name), ["客户同步"])
        XCTAssertEqual(DataTaskPresentation.filter(tasks, query: "不存在").count, 0)
    }

    func testFilterCanLimitToEnabledTasks() {
        let tasks = [
            makeTask(name: "启用中"),
            makeTask(name: "已停用", enabled: false)
        ]

        XCTAssertEqual(
            DataTaskPresentation.filter(tasks, onlyEnabled: true).map(\.name),
            ["启用中"]
        )
    }

    // MARK: - 写入定性

    func testDestructiveWriteClassification() {
        XCTAssertFalse(DataTaskPresentation.isDestructiveWrite(makeTask(writeMode: .append)))
        XCTAssertTrue(DataTaskPresentation.isDestructiveWrite(makeTask(writeMode: .overwrite)))
        XCTAssertTrue(DataTaskPresentation.isDestructiveWrite(makeTask(writeMode: .upsert)))
    }

    // MARK: - 时间字段

    func testDateTextAndParseRoundTrip() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 3, minute: 5))!

        let text = DataTaskPresentation.dateText(date, timeZone: calendar.timeZone)
        XCTAssertEqual(text, "2026-09-22 03:05")
        // 展示文本能原样解析回来（编辑器里「不改也不丢」）。
        XCTAssertEqual(DataTaskPresentation.parseDate(text), date)
    }

    func testParseDateAcceptsISOAndRejectsGarbage() {
        XCTAssertEqual(
            DataTaskPresentation.parseDate("2026-09-22T03:00:00Z"),
            ISO8601DateFormatter().date(from: "2026-09-22T03:00:00Z")
        )
        XCTAssertNil(DataTaskPresentation.parseDate(""))
        XCTAssertNil(DataTaskPresentation.parseDate("   "))
        XCTAssertNil(DataTaskPresentation.parseDate("下周三"))
        XCTAssertEqual(DataTaskPresentation.dateText(nil), "")
    }
}
