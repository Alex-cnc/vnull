import XCTest
@testable import DoyahCore

/// specs 版本化与重跑语义（FR-AI-11）。
///
/// 三件最容易被做松的事，这里逐个钉：
/// ① 历史**只能追加**（可被改写的历史不叫历史）；
/// ② 内容没变**不记新版本**（否则真正的改动会被噪音淹掉）；
/// ③ 重跑语义**必须显式选**，且要与任务自带的写入模式对得上。
final class SpecVersioningTests: XCTestCase {

    private func definition(
        id: UUID = UUID(),
        name: String = "夜间汇总",
        specs: String = "把订单按天汇总",
        table: String = "orders",
        writeMode: DataTaskDefinition.Target.WriteMode = .append,
        transformations: [DataTaskDefinition.Transformation] = []
    ) -> DataTaskDefinition {
        DataTaskDefinition(
            id: id,
            name: name,
            specs: specs,
            source: DataTaskDefinition.Source(table: table),
            transformations: transformations,
            target: DataTaskDefinition.Target(table: "summary", writeMode: writeMode)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doyah-specs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: 版本记录

    func testRecordCreatesIncreasingVersions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpecVersionStore(directoryURL: directory)
        let taskID = UUID()

        let first = try store.record(definition: definition(id: taskID, name: "v1"))
        let second = try store.record(definition: definition(id: taskID, name: "v2"))

        XCTAssertEqual(first?.number, 1)
        XCTAssertEqual(second?.number, 2)
        XCTAssertEqual(store.versions(taskID: taskID).map(\.number), [1, 2])
    }

    /// 内容没变就不记新版本 —— 连 `updatedAt` 变了也不算改动。
    func testIdenticalContentDoesNotCreateVersion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpecVersionStore(directoryURL: directory)
        let taskID = UUID()

        let base = definition(id: taskID)
        XCTAssertNotNil(try store.record(definition: base))
        var touched = base
        touched.updatedAt = Date().addingTimeInterval(3600)
        touched.createdAt = Date().addingTimeInterval(-3600)
        XCTAssertNil(try store.record(definition: touched), "只改了时间戳不该记新版本")
        XCTAssertEqual(store.versions(taskID: taskID).count, 1)
    }

    func testVersionsAreIsolatedPerTask() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpecVersionStore(directoryURL: directory)
        let a = UUID(), b = UUID()

        _ = try store.record(definition: definition(id: a, name: "A1"))
        _ = try store.record(definition: definition(id: b, name: "B1"))
        _ = try store.record(definition: definition(id: a, name: "A2"))

        XCTAssertEqual(store.versions(taskID: a).map(\.definition.name), ["A1", "A2"])
        XCTAssertEqual(store.versions(taskID: b).map(\.definition.name), ["B1"])
        XCTAssertEqual(store.version(taskID: a, number: 2)?.definition.name, "A2")
    }

    /// 只追加：早先写下的行**逐字不动**（一行坏了也只跳过那一行）。
    func testFileIsAppendOnlyAndSkipsBadLines() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpecVersionStore(directoryURL: directory)
        let taskID = UUID()
        _ = try store.record(definition: definition(id: taskID, name: "v1"))
        let afterFirst = try String(contentsOf: store.location, encoding: .utf8)

        _ = try store.record(definition: definition(id: taskID, name: "v2"))
        let afterSecond = try String(contentsOf: store.location, encoding: .utf8)
        XCTAssertTrue(afterSecond.hasPrefix(afterFirst), "已有行必须逐字保留（只追加）")

        // 塞一行坏数据：好版本仍要读得出来
        let handle = try FileHandle(forWritingTo: store.location)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("这不是 JSON\n".utf8))
        try handle.close()
        XCTAssertEqual(store.versions(taskID: taskID).count, 2, "坏行跳过，好版本照读")
    }

    /// 保存是版本化的收口点：`DataTaskStore.save` 应当自动留下历史。
    func testDataTaskStoreSaveRecordsVersionAutomatically() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataTaskStore(directoryURL: directory)
        let taskID = UUID()

        try await store.save(definition(id: taskID, name: "v1"))
        try await store.save(definition(id: taskID, name: "v2"))
        try await store.save(definition(id: taskID, name: "v2"))   // 同一内容再存一次

        let versions = SpecVersionStore(directoryURL: directory).versions(taskID: taskID)
        XCTAssertEqual(versions.map(\.definition.name), ["v1", "v2"], "重复保存同一内容不该再记一版")
        let versioningError = await store.lastVersioningError
        XCTAssertNil(versioningError)
    }

    /// 保存时给的 `note` 要落进版本记录：界面里的「备注」列靠它，
    /// 而"这次是用户改的还是回滚来的"只能靠它分辨。
    func testSaveNoteLandsInVersionRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataTaskStore(directoryURL: directory)
        let taskID = UUID()

        try await store.save(definition(id: taskID, name: "v1"))
        try await store.save(definition(id: taskID, name: "v2"), note: "回滚到 v1")

        let versions = SpecVersionStore(directoryURL: directory).versions(taskID: taskID)
        XCTAssertEqual(versions.map(\.note), [nil, "回滚到 v1"])
    }

    // MARK: diff

    func testDiffReportsFieldChanges() {
        let before = definition(name: "旧名", specs: "把订单按天汇总", table: "orders")
        var after = before
        after.name = "新名"
        after.specs = "把订单按小时汇总"
        after.target.table = "summary_hourly"

        let changes = SpecDiff.changes(between: before, and: after)
        let fields = changes.map(\.field)
        XCTAssertEqual(fields, ["名称", "规格说明", "目标"], "顺序要稳定：\(fields)")
        XCTAssertTrue(changes.contains { $0.before == "旧名" && $0.after == "新名" })
        XCTAssertTrue(changes.contains { $0.field == "目标" && $0.after.contains("summary_hourly") })
    }

    func testDiffIgnoresTimestamps() {
        var a = definition()
        var b = a
        b.updatedAt = Date().addingTimeInterval(9999)
        b.createdAt = Date().addingTimeInterval(-9999)
        XCTAssertTrue(SpecDiff.changes(between: a, and: b).isEmpty)
        a.name = "改了"
        XCTAssertEqual(SpecDiff.changes(between: a, and: b).count, 1)
    }

    func testDiffReportsTransformationCount() {
        let none = definition()
        let withOne = definition(transformations: [
            DataTaskDefinition.Transformation(kind: .drop, column: "secret")
        ])
        let changes = SpecDiff.changes(between: none, and: withOne)
        // 表达式拆开写：整句太复杂会让类型检查超时（编译器直接报 unable to type-check）
        let hasCountChange = changes.contains { change in
            change.field == "转换条数" && change.before == "0" && change.after == "1"
        }
        XCTAssertTrue(hasCountChange, "\(changes.map(\.description))")
    }

    func testLineDiffForSpecsText() {
        let changes = SpecDiff.lineChanges(from: "第一行\n第二行", to: "第一行\n第二行改了\n第三行")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].field, "第 2 行")
        XCTAssertEqual(changes[1].field, "第 3 行")
    }

    // MARK: 重跑语义

    /// 三种语义映射到**既有的** `Target.WriteMode`，不另造一套写入语义。
    func testRerunModeMapsToDeclaredWriteMode() {
        XCTAssertEqual(RerunMode.overwrite.writeMode, .overwrite)
        XCTAssertEqual(RerunMode.append.writeMode, .append)
        XCTAssertEqual(RerunMode.resume.writeMode, .append, "断点续跑在写入层面仍是追加")
        XCTAssertEqual(RerunMode.allCases.count, 3)
        XCTAssertTrue(RerunPolicy.describe(.resume).contains("断点"))
    }

    func testOverwriteWithoutTargetTableIsBlocked() {
        let broken = definition(writeMode: .overwrite)
        var noTable = broken
        noTable.target.table = "   "
        let verdict = RerunPolicy.evaluate(mode: .overwrite, definition: noTable)
        XCTAssertFalse(verdict.isAllowed)
        XCTAssertTrue(verdict.blockers.contains { $0.contains("目标表") }, "\(verdict.blockers)")
    }

    /// 选的重跑语义与任务声明的写入模式**不一致** → 阻止（幂等承诺不能是空话）。
    func testMismatchBetweenRerunModeAndTaskWriteModeIsBlocked() {
        let task = definition(writeMode: .append)
        let verdict = RerunPolicy.evaluate(mode: .overwrite, definition: task)
        XCTAssertFalse(verdict.isAllowed, "\(verdict)")
        XCTAssertTrue(verdict.blockers.contains { $0.contains("不一致") }, "\(verdict.blockers)")
    }

    func testAppendModeWarnsAboutDuplicates() {
        let verdict = RerunPolicy.evaluate(mode: .append, definition: definition(writeMode: .append))
        XCTAssertTrue(verdict.isAllowed)
        XCTAssertTrue(verdict.warnings.contains { $0.contains("重复数据") }, "\(verdict.warnings)")
    }

    /// upsert 的任务选追加：不阻止，但要说明"实际不是纯追加"。
    func testUpsertTaskWithAppendModeWarnsInsteadOfBlocking() {
        let task = definition(writeMode: .upsert)
        let verdict = RerunPolicy.evaluate(mode: .append, definition: task)
        XCTAssertTrue(verdict.isAllowed)
        XCTAssertTrue(verdict.warnings.contains { $0.contains("upsert") }, "\(verdict.warnings)")
    }

    /// 断点续跑：允许但提醒"需要进度标记"。
    func testResumeModeWarnsAboutCheckpoint() {
        let task = definition(writeMode: .append)
        let verdict = RerunPolicy.evaluate(mode: .resume, definition: task)
        XCTAssertTrue(verdict.isAllowed)
        XCTAssertTrue(verdict.warnings.contains { $0.contains("进度") }, "\(verdict.warnings)")
    }
}
