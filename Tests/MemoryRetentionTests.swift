import XCTest
@testable import DoyahCore

/// 记忆的生命周期**执行者**（FR-AI-15）：分类推断、计划生成、以及"计划与执行分开"。
///
/// 背景：`RetentionPolicy.evaluate` 早就会判定"该不该忘"，但**没有执行者** ——
/// 判定只被打印，没人照着动手。这里钉住执行者这一层：谁该被忘、为什么、以及
/// 默认**不删任何东西**。
final class MemoryRetentionTests: XCTestCase {

    private func memory(
        _ fingerprint: String,
        sql: String = "SELECT 1",
        runs: Int = 1,
        days: [String] = ["2026-09-01"],
        last: Date = Date(timeIntervalSince1970: 1_790_000_000)
    ) -> QueryMemory.Memory {
        QueryMemory.Memory(
            fingerprint: fingerprint,
            latestSQL: sql,
            variantCount: 1,
            runCount: runs,
            days: Set(days),
            connections: ["生产库"],
            lastExecutedAt: last,
            hourHistogram: Array(repeating: 0, count: 24)
        )
    }

    // MARK: - 分类推断

    func testCrossDayOrFrequentlyUsedIsRoutine() {
        XCTAssertEqual(MemoryGovernance.classify(memory: memory("a", runs: 1, days: ["d1", "d2"])).kind, .routine)
        XCTAssertEqual(MemoryGovernance.classify(memory: memory("b", runs: 5, days: ["d1"])).kind, .routine)
        // 理由要带实际数字，用户才能判断推断对不对
        XCTAssertTrue(MemoryGovernance.classify(memory: memory("a", runs: 1, days: ["d1", "d2"])).reason.contains("2 天"))
    }

    func testSingleDayLowUseIsTroubleshooting() {
        let classification = MemoryGovernance.classify(memory: memory("c", runs: 2, days: ["d1"]))
        XCTAssertEqual(classification.kind, .troubleshooting)
        XCTAssertTrue(classification.reason.contains("1 天"), classification.reason)
    }

    // MARK: - 计划

    func testPlanSeparatesForgettableFromRetained() {
        // 1_815_000_000 ≈ 2027-07-08：距 1_790_000_000（≈2026-09-21）约 289 天 > 180 天阈值。
        let now = Date(timeIntervalSince1970: 1_815_000_000)
        let oldDate = Date(timeIntervalSince1970: 1_790_000_000)      // 约 2026-09-21
        let plan = MemoryGovernance.plan(
            memories: [
                memory("routine", runs: 9, days: ["d1", "d2"], last: oldDate),
                memory("diag", runs: 1, days: ["d1"], last: oldDate),
                memory("fresh", runs: 1, days: ["d1"], last: now),
            ],
            now: now
        )
        XCTAssertEqual(plan.forgettable.map(\.fingerprint), ["diag"], "只有闲置够久的排障类才该被忘")
        XCTAssertEqual(plan.retained.map(\.fingerprint), ["fresh", "routine"])
        XCTAssertTrue(plan.forgettable[0].classificationReason.contains("排障"))
        XCTAssertTrue(plan.forgettable[0].verdict.reason.contains("180"), "判定理由要带阈值数字")
    }

    func testPlanIsDeterministicAndEmptyWhenNothingToForget() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = MemoryGovernance.plan(memories: [memory("a"), memory("b")], now: now)
        XCTAssertEqual(first.forgettable.count, 0)
        XCTAssertEqual(first.retained.count, 2, "闲不够久的一条都不删")

        let ordered = MemoryGovernance.plan(memories: [memory("b"), memory("a")], now: now)
        XCTAssertEqual(ordered.retained.map(\.fingerprint), ["a", "b"], "输出顺序稳定")
    }

    /// 计划只是数据：生成计划**不许**碰归档（"默认不删"这条纪律）。
    func testPlanDoesNotTouchTheArchive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doyah-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let entries = [
            SQLArchiveEntry(
                sql: "SELECT * FROM tmp_diag WHERE id = 7",
                firstExecutedAt: day, lastExecutedAt: day, runCount: 1,
                connection: "生产库", database: "postgres", durationSeconds: 0.1,
                affectedRows: nil, succeeded: true, note: nil
            )
        ]
        let file = directory.appendingPathComponent("2026-09-21.sql")
        try SQLArchive.render(entries, day: day).write(to: file, atomically: true, encoding: .utf8)
        let before = try String(contentsOf: file, encoding: .utf8)

        _ = MemoryGovernance.plan(
            memories: [memory("diag", runs: 1, days: ["d1"], last: day)],
            now: Date(timeIntervalSince1970: 1_815_000_000)
        )

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before, "生成计划不该动归档一个字节")
        try? FileManager.default.removeItem(at: directory)
    }

    func testDescribeMentionsPolicyAndCounts() {
        let plan = MemoryGovernance.plan(
            memories: [memory("diag", runs: 1, days: ["d1"], last: Date(timeIntervalSince1970: 1_790_000_000))],
            now: Date(timeIntervalSince1970: 1_815_000_000)
        )
        let text = plan.describe().joined(separator: "\n")
        XCTAssertTrue(text.contains("生命周期计划"), text)
        XCTAssertTrue(text.contains("将被删除 1 条"), text)
        XCTAssertTrue(text.contains("原文："), "要给出原文，人才知道删的是什么")
    }
}

/// 通用层的落盘（FR-AI-15 验收④）：与 `MemoryDecisionsStore` 同一套纪律 ——
/// 坏文件不抛、原子写、内容确定、**可检视可删除**。
final class GeneralMemoryStoreTests: XCTestCase {

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doyah-general-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testMissingFileIsEmptyLayerNotAnError() throws {
        let loaded = GeneralMemoryStore.load(from: try directory())
        XCTAssertTrue(loaded.layer.isEmpty)
        XCTAssertTrue(loaded.warnings.isEmpty, "文件不存在不是错误，不该报警告")
    }

    func testPromotePersistsAndDeduplicates() throws {
        let directory = try directory()
        var layer = GeneralMemoryLayer()
        let first = layer.promote(template: "select * from ‹标识符› where id = ?", dialect: "postgresql", sourceFingerprint: "fp1")
        XCTAssertEqual(first.useCount, 1)
        let again = layer.promote(template: "select * from ‹标识符› where id = ?", dialect: "postgresql", sourceFingerprint: "fp2")
        XCTAssertEqual(again.useCount, 2, "同一条写法重复提升要计数，而不是存两条")
        XCTAssertEqual(again.sourceFingerprints, ["fp1", "fp2"])
        XCTAssertEqual(layer.memories.count, 1)

        try GeneralMemoryStore.save(layer, to: directory)
        let reloaded = GeneralMemoryStore.load(from: directory)
        XCTAssertEqual(reloaded.layer.memories.count, 1)
        XCTAssertEqual(reloaded.layer.memories[0].useCount, 2)
    }

    func testSameTemplateDifferentDialectIsSeparate() {
        var layer = GeneralMemoryLayer()
        layer.promote(template: "select 1", dialect: "postgresql", sourceFingerprint: nil)
        layer.promote(template: "select 1", dialect: "gbase8a", sourceFingerprint: nil)
        XCTAssertEqual(layer.memories.count, 2, "方言是通用经验的一部分，不能混")
    }

    func testRemoveReportsWhetherItRemoved() {
        var layer = GeneralMemoryLayer()
        let promoted = layer.promote(template: "select 1", dialect: "postgresql", sourceFingerprint: nil)
        XCTAssertTrue(layer.remove(id: promoted.id))
        XCTAssertFalse(layer.remove(id: "不存在"), "删不存在的要如实返回 false")
        XCTAssertTrue(layer.isEmpty)
    }

    func testCorruptFileFallsBackWithWarning() throws {
        let directory = try directory()
        try "{ 这不是 JSON".write(
            to: GeneralMemoryStore.fileURL(in: directory),
            atomically: true,
            encoding: .utf8
        )
        let loaded = GeneralMemoryStore.load(from: directory)
        XCTAssertTrue(loaded.layer.isEmpty)
        XCTAssertEqual(loaded.warnings.count, 1, "坏文件要回退 + 报告，不静默也不让整层不可用")
    }

    func testSaveIsDeterministic() throws {
        let directory = try directory()
        var layer = GeneralMemoryLayer()
        layer.promote(template: "select b", dialect: "postgresql", sourceFingerprint: "x")
        layer.promote(template: "select a", dialect: "postgresql", sourceFingerprint: "y")
        try GeneralMemoryStore.save(layer, to: directory)
        let first = try Data(contentsOf: GeneralMemoryStore.fileURL(in: directory))
        try GeneralMemoryStore.save(layer, to: directory)
        let second = try Data(contentsOf: GeneralMemoryStore.fileURL(in: directory))
        XCTAssertEqual(first, second, "两次写盘逐字节一致（可 diff、可进版本库）")
        let text = String(decoding: first, as: UTF8.self)
        XCTAssertTrue(text.range(of: "select a")!.lowerBound < text.range(of: "select b")!.lowerBound, "按 id 排序")
    }
}
