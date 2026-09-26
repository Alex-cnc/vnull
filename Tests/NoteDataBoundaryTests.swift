import XCTest
@testable import DoyahCore

/// `FR-PLUG-04` 的**数据边界**：笔记数据落在工程数据家**之外**（独立目录），备份与清理策略各自独立。
///
/// 这一份测的是"位置"与"搬家"，不是笔记功能本身（那个在 `NoteTests`）。
/// 为什么把这件事单列：位置错了的后果不是"不好看"，而是**两类风险** ——
/// 宿主的清理 / 迁移顺手带走用户的笔记，或者笔记的迁移动到宿主的连接凭据与审计日志。
final class NoteDataBoundaryTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doyah-note-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func path(_ name: String) -> URL {
        sandbox.appendingPathComponent(name, isDirectory: false)
    }

    private func directory(_ name: String) -> URL {
        sandbox.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - 位置

    /// 默认位置必须**不在**工程数据家里 —— 这是 FR-PLUG-04 的字面要求。
    func testDefaultLocationIsOutsideTheEngineeringDataHome() {
        let file = NoteStore.defaultFileURL(environment: [:])
        let legacy = NoteStore.legacyFileURL()

        XCTAssertEqual(file.pathComponents.suffix(2).joined(separator: "/"), "\(DoyahIdentity.notesDataDirectoryName)/notes.json")
        XCTAssertFalse(file.path.contains("/\(DoyahIdentity.applicationSupportDirectoryName)/"),
                       "笔记库不得落在工程数据家（\(DoyahIdentity.applicationSupportDirectoryName)）里：\(file.path)")
        XCTAssertNotEqual(file.path, legacy.path)
        // 旧位置仍在工程数据家里 —— 迁移是"从那里搬出来"，这条断言让迁移的起点也有据可依。
        XCTAssertTrue(legacy.path.contains("/\(DoyahIdentity.applicationSupportDirectoryName)/"), legacy.path)
        XCTAssertEqual(legacy.lastPathComponent, "notes.json")
    }

    /// `DOYAH_NOTES_DIR` 整体改掉数据家（脚本 / 探针用它把笔记挪到临时目录）。
    func testNotesDirectoryHonoursTheEnvironmentOverride() {
        let override = "/tmp/doyah-notes-override"
        XCTAssertEqual(NoteStore.defaultDirectory(environment: ["DOYAH_NOTES_DIR": override]).path, override)
        XCTAssertEqual(NoteStore.defaultFileURL(environment: ["DOYAH_NOTES_DIR": override]).path,
                       override + "/notes.json")
        // 空串等于没设（不然 `DOYAH_NOTES_DIR=` 会把数据家变成当前目录）。
        XCTAssertEqual(NoteStore.defaultDirectory(environment: ["DOYAH_NOTES_DIR": ""]),
                       NoteStore.defaultDirectory(environment: [:]))
    }

    // MARK: - 迁移

    /// 正常路径：笔记搬过去、**逐字节一致**、旧文件变成新数据家里的备份、原处不再留笔记。
    func testMigrationMovesNotesIntoTheNotesHome() async throws {
        let legacy = path("legacy-notes.json")
        let target = directory("notes-home").appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: legacy)
        _ = try await store.upsert(NoteDraft(title: "第一条", body: "SELECT 1"))
        _ = try await store.upsert(NoteDraft(title: "第二条", body: "SELECT 2", tags: ["pg"]))
        let before = try Data(contentsOf: legacy)

        let report = NoteStoreMigration.migrateIfNeeded(legacyURL: legacy, targetURL: target)

        XCTAssertEqual(report.outcome, .migrated)
        XCTAssertEqual(report.noteCount, 2)
        XCTAssertTrue(report.didMigrate)
        XCTAssertFalse(report.needsAttention)
        XCTAssertEqual(try Data(contentsOf: target), before, "搬的是字节，落盘内容必须与原来完全一致")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "旧位置不该再留着一份笔记")
        let backup = try XCTUnwrap(report.backupURL)
        XCTAssertEqual(backup.lastPathComponent, NoteStoreMigration.backupFileName)
        XCTAssertEqual(backup.deletingLastPathComponent().path, target.deletingLastPathComponent().path,
                       "备份要落在**笔记的数据家**里，不是留在宿主的数据家")
        XCTAssertEqual(try Data(contentsOf: backup), before, "备份就是原来的那份文件")
    }

    /// 幂等 + 绝不覆盖：目标已有文件时一个字节都不动，也不会再搬第二次。
    func testMigrationNeverOverwritesAnExistingTarget() async throws {
        let legacy = path("legacy-notes.json")
        let target = directory("notes-home").appendingPathComponent("notes.json")
        _ = try await NoteStore(fileURL: legacy).upsert(NoteDraft(title: "旧库里的"))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data("[ ]".utf8)
        try newer.write(to: target)

        let report = NoteStoreMigration.migrateIfNeeded(legacyURL: legacy, targetURL: target)

        XCTAssertEqual(report.outcome, .skippedTargetExists)
        XCTAssertEqual(report.noteCount, 0)
        XCTAssertNil(report.backupURL)
        XCTAssertEqual(try Data(contentsOf: target), newer, "目标已有内容 —— 一个字节都不许动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "没搬成就别动旧文件")
    }

    /// 第二次跑：旧文件已经被搬走（改名成备份），于是如实报"没有要搬的东西"，目标一个字节不动。
    func testMigrationIsIdempotentOnSecondRun() async throws {
        let legacy = path("legacy-notes.json")
        let target = directory("notes-home").appendingPathComponent("notes.json")
        _ = try await NoteStore(fileURL: legacy).upsert(NoteDraft(title: "只搬一次"))
        let first = NoteStoreMigration.migrateIfNeeded(legacyURL: legacy, targetURL: target)
        let snapshot = try Data(contentsOf: target)

        let second = NoteStoreMigration.migrateIfNeeded(legacyURL: legacy, targetURL: target)

        XCTAssertEqual(first.outcome, .migrated)
        XCTAssertEqual(second.outcome, .nothingToMigrate)
        XCTAssertFalse(second.didMigrate)
        XCTAssertEqual(try Data(contentsOf: target), snapshot)
    }

    /// 坏文件：**原地保留、目标不建、如实报**（读不懂就别搬，绝不能覆盖用户唯一的笔记库）。
    func testMigrationKeepsAnUnreadableLegacyFileAndReports() throws {
        let legacy = path("legacy-notes.json")
        let target = directory("notes-home").appendingPathComponent("notes.json")
        let corrupt = Data("{ 这不是 JSON".utf8)
        try corrupt.write(to: legacy)

        let report = NoteStoreMigration.migrateIfNeeded(legacyURL: legacy, targetURL: target)

        XCTAssertEqual(report.outcome, .legacyUnreadable)
        XCTAssertTrue(report.needsAttention, "坏文件必须让调用方有机会如实告诉用户")
        XCTAssertNotNil(report.failure, "要给出原因，不能只说「失败」")
        XCTAssertEqual(try Data(contentsOf: legacy), corrupt, "坏文件原地保留 —— 不许删、不许改")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "读不懂就不该在新位置造一个空库")
    }

    /// 没有旧文件：什么都不做（第一次用的机器不该被"迁移"打扰，也不该凭空造目录）。
    func testMigrationDoesNothingWhenThereIsNoLegacyFile() throws {
        let legacy = path("不存在.json")
        let target = directory("notes-home").appendingPathComponent("notes.json")

        let report = NoteStoreMigration.migrateIfNeeded(legacyURL: legacy, targetURL: target)

        XCTAssertEqual(report.outcome, .nothingToMigrate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
    }

    /// 写不进去就如实报 —— 而且旧文件一个字节不动（数据不会因为搬失败而丢）。
    func testMigrationReportsAWriteFailureAndLeavesTheLegacyFileAlone() async throws {
        let legacy = path("legacy-notes.json")
        _ = try await NoteStore(fileURL: legacy).upsert(NoteDraft(title: "搬不动的"))
        let before = try Data(contentsOf: legacy)
        // 目标目录的位置被一个**文件**占着：建目录必然失败。
        let blocked = path("blocked")
        try Data("占位".utf8).write(to: blocked)
        let target = blocked.appendingPathComponent("notes.json")

        let report = NoteStoreMigration.migrateIfNeeded(legacyURL: legacy, targetURL: target)

        XCTAssertEqual(report.outcome, .writeFailed)
        XCTAssertTrue(report.needsAttention)
        XCTAssertNotNil(report.failure)
        XCTAssertEqual(try Data(contentsOf: legacy), before, "搬失败时旧文件必须原样")
    }

    /// 生效的 `DOYAH_NOTES_DIR`：迁移**主动让路** —— 否则会把真实用户的笔记搬进临时目录。
    func testMigrationDeclinesWhenTheEnvironmentOverrideIsInEffect() {
        let report = NoteStoreMigration.migrateIfNeeded(environment: ["DOYAH_NOTES_DIR": sandbox.path])

        XCTAssertEqual(report.outcome, .skippedOverridden)
        XCTAssertFalse(report.didMigrate)
        XCTAssertFalse(report.needsAttention, "让路不是事故，不该弹东西给用户")
        XCTAssertEqual(report.targetURL.path, sandbox.appendingPathComponent("notes.json").path)
    }

    /// 走**默认位置**的那条重载：两边一致时就不会把同一份文件"搬到自己头上"。
    func testMigrationThroughDefaultsIsANoOpWhenTheLegacyFileIsAbsent() {
        let report = NoteStoreMigration.migrateIfNeeded(legacyURL: sandbox.appendingPathComponent("none.json"),
                                                        targetURL: sandbox.appendingPathComponent("none.json"))
        XCTAssertEqual(report.outcome, .nothingToMigrate)
    }

    // MARK: - 读盘结果的如实报告

    /// `load()` 的旧行为不变（坏文件回退空列表），但 `loadOutcome()` 要能把三种情形分开。
    func testLoadOutcomeSeparatesAbsentFromUnreadable() async throws {
        let file = path("notes.json")
        let store = NoteStore(fileURL: file)

        let missing = await store.loadOutcome()
        XCTAssertEqual(missing, .absent)
        let emptyBefore = try await store.load()
        XCTAssertEqual(emptyBefore, [])

        try Data("坏掉的内容".utf8).write(to: file)
        let unreadable = await store.loadOutcome()
        guard case .unreadable(let failure) = unreadable else {
            return XCTFail("文件在但读不出来时必须是 .unreadable，实际是 \(unreadable)")
        }
        XCTAssertFalse(failure.isEmpty, "原因要能给人看")
        let emptyAfter = try await store.load()
        XCTAssertEqual(emptyAfter, [], "既有调用方的行为不变：回退空列表")

        _ = try await store.upsert(NoteDraft(title: "还能写"))
        let reloaded = await store.loadOutcome()
        guard case .loaded(let notes) = reloaded else {
            return XCTFail("写回去之后必须能读出来，实际是 \(reloaded)")
        }
        XCTAssertEqual(notes.map(\.title), ["还能写"])
    }
}
