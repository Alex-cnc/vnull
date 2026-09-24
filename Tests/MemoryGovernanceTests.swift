import XCTest
@testable import DoyahCore

/// 记忆治理（FR-AI-15）：生命周期按类型分、可解释、环境层/通用层分离、删除即时生效。
///
/// 这一层最容易被做松的是**生命周期**：一旦写成"按天数清理"，第一个被清掉的就是
/// 「一年只用一次但很关键」的巡检脚本（验收①）。所以下面的用例把"永不遗忘"这条钉死，
/// 并且要求理由里必须出现实际数字（不能只写"太久没用"）。
final class MemoryGovernanceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    private func stats(runCount: Int, dayCount: Int = 5, idleDays: Int) -> MemoryStats {
        MemoryStats(
            runCount: runCount,
            dayCount: dayCount,
            variantCount: 2,
            lastExecutedAt: daysAgo(idleDays),
            connections: ["生产库"]
        )
    }

    // MARK: 生命周期（验收①）

    /// 巡检类（人工钉住）与例行类**永不因时间遗忘** —— 哪怕闲置五年、只跑过一次。
    func testPinnedAndRoutineAreNeverForgottenByTime() {
        let policy = RetentionPolicy.standard
        for kind in [MemoryKind.pinned, .routine, .general] {
            let verdict = policy.evaluate(kind: kind, stats: stats(runCount: 1, idleDays: 365 * 5), now: now)
            XCTAssertFalse(verdict.shouldForget, "\(kind) 不该因为时间被清掉")
            XCTAssertTrue(verdict.reason.contains("1825"), "理由里要有实际闲置天数：\(verdict.reason)")
            XCTAssertTrue(verdict.reason.contains("1 次"), "理由里要有实际执行次数：\(verdict.reason)")
        }
    }

    /// 排障类：**闲置够久且用得少**两条同时成立才遗忘。
    func testTroubleshootingForgetsOnlyWhenIdleAndLowUse() {
        let policy = RetentionPolicy.standard
        let forget = policy.evaluate(kind: .troubleshooting, stats: stats(runCount: 1, idleDays: 400), now: now)
        XCTAssertTrue(forget.shouldForget)
        XCTAssertTrue(forget.reason.contains("400") && forget.reason.contains("180"),
                      "理由要带实际天数与阈值：\(forget.reason)")

        // 用得不少 → 留
        let busy = policy.evaluate(kind: .troubleshooting, stats: stats(runCount: 9, idleDays: 400), now: now)
        XCTAssertFalse(busy.shouldForget)
        XCTAssertTrue(busy.reason.contains("9 次"), busy.reason)

        // 闲置不够久 → 留
        let recent = policy.evaluate(kind: .troubleshooting, stats: stats(runCount: 1, idleDays: 10), now: now)
        XCTAssertFalse(recent.shouldForget)
        XCTAssertTrue(recent.reason.contains("10"), recent.reason)
    }

    /// 阈值是可配的，不是写死的天数 —— 换一组参数行为跟着变（"不按固定天数一刀切"的另一种体现）。
    func testPolicyThresholdsAreConfigurable() {
        let strict = RetentionPolicy(idleDays: 30, lowUseRunCount: 2)
        let verdict = strict.evaluate(kind: .troubleshooting, stats: stats(runCount: 1, idleDays: 40), now: now)
        XCTAssertTrue(verdict.shouldForget)
        XCTAssertTrue(verdict.reason.contains("30"), verdict.reason)
    }

    // MARK: 可解释（验收③）

    func testExplanationCoversSourceClusteringAndVerdict() {
        let memory = QueryMemory.Memory(
            fingerprint: "select count(*) from orders where status = '?'",
            latestSQL: "SELECT count(*) FROM orders WHERE status = 'paid'",
            variantCount: 2,
            runCount: 12,
            days: ["2026-09-21", "2026-09-22", "2026-09-23"],
            connections: ["生产库"],
            lastExecutedAt: daysAgo(3)
        )
        let verdict = RetentionPolicy.standard.evaluate(kind: .routine, stats: MemoryStats(memory: memory), now: now)
        let lines = MemoryExplanation.describe(memory: memory, kind: .routine, verdict: verdict)

        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("select count(*)"), "要给出聚类依据：\(lines[0])")
        XCTAssertTrue(lines[1].contains("生产库") && lines[1].contains("12 次") && lines[1].contains("3 天"),
                      "来源行要含连接、次数、天数：\(lines[1])")
        XCTAssertTrue(lines[2].contains("status = 'paid'"), "要能回看最近原文：\(lines[2])")
        XCTAssertTrue(lines[3].hasPrefix("为什么记了它："), lines[3])
    }

    func testExplanationSaysWhyForgotten() {
        let memory = QueryMemory.Memory(
            fingerprint: "select * from tmp_diag where id = ?",
            latestSQL: "SELECT * FROM tmp_diag WHERE id = 7",
            variantCount: 1,
            runCount: 1,
            days: ["2025-01-01"],
            connections: ["生产库"],
            lastExecutedAt: daysAgo(400)
        )
        let verdict = RetentionPolicy.standard.evaluate(kind: .troubleshooting, stats: MemoryStats(memory: memory), now: now)
        XCTAssertTrue(verdict.shouldForget)
        let lines = MemoryExplanation.describe(memory: memory, kind: .troubleshooting, verdict: verdict)
        XCTAssertTrue(lines[3].hasPrefix("为什么它被忘了："), lines[3])
    }

    // MARK: 环境层 / 通用层与脱敏闸（验收④）

    private let dialect: SQLDialect = SQLDialectFactory.make(for: .postgresql)

    func testGeneralizeReplacesUserIdentifiersAndLiteralsButKeepsDialectVocabulary() {
        let sql = "SELECT count(*) FROM orders WHERE status = 'paid' AND id > 100"
        guard let generalized = MemoryPromotion.generalize(sql: sql, dialect: dialect) else {
            return XCTFail("应当能通用化")
        }
        XCTAssertTrue(generalized.contains("‹标识符›"), generalized)
        XCTAssertFalse(generalized.lowercased().contains("orders"), generalized)
        XCTAssertFalse(generalized.contains("paid"), generalized)
        XCTAssertFalse(generalized.contains("100"), generalized)
        XCTAssertTrue(generalized.contains("SELECT"), "关键字要保留：\(generalized)")
        XCTAssertTrue(generalized.lowercased().contains("count"), "内置函数属于方言写法，要保留：\(generalized)")
    }

    func testPromotionPassesWhenNothingLeaks() {
        let sql = "SELECT count(*) FROM orders WHERE status = 'paid'"
        let generalized = MemoryPromotion.generalize(sql: sql, dialect: dialect) ?? ""
        let verdict = MemoryPromotion.check(original: sql, generalized: generalized, dialect: dialect)
        XCTAssertTrue(verdict.isAllowed, verdict.reason)
        XCTAssertTrue(verdict.leakedTerms.isEmpty)
    }

    /// 表名漏进通用写法 → 拒绝（这正是"不得携带具体库表名"的闸）。
    func testPromotionRejectsLeakedIdentifier() {
        let sql = "SELECT count(*) FROM orders WHERE status = 'paid'"
        let leaked = "SELECT count(*) FROM orders WHERE ‹标识符› = ?"
        let verdict = MemoryPromotion.check(original: sql, generalized: leaked, dialect: dialect)
        XCTAssertFalse(verdict.isAllowed)
        XCTAssertTrue(verdict.leakedTerms.contains("orders"), verdict.reason)
    }

    func testPromotionRejectsLeakedLiteralValue() {
        let sql = "SELECT count(*) FROM orders WHERE status = 'paid'"
        let leaked = "SELECT count(*) FROM ‹标识符› WHERE ‹标识符› = 'paid'"
        let verdict = MemoryPromotion.check(original: sql, generalized: leaked, dialect: dialect)
        XCTAssertFalse(verdict.isAllowed)
        XCTAssertTrue(verdict.leakedTerms.contains("paid"), verdict.reason)
    }

    /// 大小写不敏感：`ORDERS` 同样是泄漏。
    func testPromotionLeakCheckIsCaseInsensitive() {
        let sql = "SELECT count(*) FROM orders"
        let leaked = "SELECT count(*) FROM ‹标识符› -- ORDERS"
        let verdict = MemoryPromotion.check(original: sql, generalized: leaked, dialect: dialect)
        XCTAssertFalse(verdict.isAllowed, verdict.reason)
    }

    func testEnvironmentAndGeneralLayersExist() {
        XCTAssertEqual(Set(MemoryLayer.allCases), [.environment, .general])
        XCTAssertEqual(MemoryLayer.environment.rawValue, "environment")
    }

    // MARK: 删除 / 清空（验收②）

    private func makeArchiveDirectory(_ entries: [(String, String)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doyah-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let archiveEntries = entries.map { sql, connection in
            SQLArchiveEntry(
                sql: sql,
                firstExecutedAt: day,
                lastExecutedAt: day,
                runCount: 1,
                connection: connection,
                database: "postgres",
                durationSeconds: 0.1,
                affectedRows: nil,
                succeeded: true,
                note: nil
            )
        }
        let text = SQLArchive.render(archiveEntries, day: day)
        try text.write(to: directory.appendingPathComponent("2026-09-21.sql"), atomically: true, encoding: .utf8)
        return directory
    }

    /// 删一条，另一条必须原样留着（保格式：`parse(render(x))` 往返）。
    func testRemoveEntriesByFingerprintKeepsOtherEntries() throws {
        let keepSQL = "SELECT * FROM customers WHERE id = 1"
        let dropSQL = "SELECT * FROM orders WHERE id = 1"
        let directory = try makeArchiveDirectory([(keepSQL, "生产库"), (dropSQL, "生产库")])
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = try SQLArchiveEditor.removeEntries(
            matchingFingerprint: QueryMemory.coarseFingerprint(dropSQL),
            in: directory
        )
        XCTAssertEqual(report.removedEntryCount, 1)
        XCTAssertEqual(report.remainingEntryCount, 1)
        XCTAssertEqual(report.changedFiles, ["2026-09-21.sql"])

        let text = try String(contentsOf: directory.appendingPathComponent("2026-09-21.sql"), encoding: .utf8)
        let kept = SQLArchive.parse(text)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].sql, keepSQL, "留下的那条必须原样")
        XCTAssertEqual(kept[0].connection, "生产库")
    }

    /// 验收②：「删除**立即生效**且可验证（重建索引后不再出现）」的端到端。
    func testRemovedMemoryIsGoneAfterIndexRebuild() throws {
        let keepSQL = "SELECT * FROM customers WHERE id = 1"
        let dropSQL = "SELECT * FROM orders WHERE id = 1"
        let directory = try makeArchiveDirectory([(keepSQL, "生产库"), (dropSQL, "生产库")])
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = QueryMemory.buildIndex(directory: directory)
        XCTAssertEqual(before.memories.count, 2, "前提：重建出两条记忆")

        _ = try SQLArchiveEditor.removeEntries(
            matchingFingerprint: QueryMemory.coarseFingerprint(dropSQL),
            in: directory
        )
        let after = QueryMemory.buildIndex(directory: directory)
        XCTAssertEqual(after.memories.count, 1)
        XCTAssertTrue(after.memories[0].latestSQL.contains("customers"))
    }

    func testRemoveAllDeletesArchiveFiles() throws {
        let directory = try makeArchiveDirectory([("SELECT 1", "生产库"), ("SELECT 2", "生产库")])
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = try SQLArchiveEditor.removeAll(in: directory)
        XCTAssertEqual(report.removedEntryCount, 2)
        XCTAssertEqual(report.remainingEntryCount, 0)
        XCTAssertEqual(report.changedFiles, ["2026-09-21.sql"])

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(remaining.isEmpty, "清空后不该留下空文件：\(remaining)")
    }

    /// **只认归档文件名**：用户自己写的 `.sql` 不能被当成归档删掉。
    func testEditorIgnoresNonArchiveSQL() throws {
        let directory = try makeArchiveDirectory([("SELECT 1", "生产库")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = directory.appendingPathComponent("my-notes.sql")
        try "SELECT 'my own script'".write(to: notes, atomically: true, encoding: .utf8)

        _ = try SQLArchiveEditor.removeAll(in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path), "非归档 .sql 必须原样保留")
    }

    /// 回归：删除条目后当天文件只剩文件头 —— 那是**合法空归档**，不该被报成"跳过（疑似损坏）"。
    func testEmptyArchiveIsNotReportedAsSkipped() throws {
        let directory = try makeArchiveDirectory([("SELECT 1", "生产库")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        try SQLArchive.render([], day: day)
            .write(to: directory.appendingPathComponent("2026-09-22.sql"), atomically: true, encoding: .utf8)

        let index = QueryMemory.buildIndex(directory: directory)
        XCTAssertTrue(index.skippedFiles.isEmpty, "空归档不该被当成可疑文件：\(index.skippedFiles)")
        XCTAssertEqual(index.memories.count, 1)
    }

    /// 但**真正的非归档文件**仍要被如实报出来（别把判据修过头）。
    func testGarbageFileIsStillReportedAsSkipped() throws {
        let directory = try makeArchiveDirectory([("SELECT 1", "生产库")])
        defer { try? FileManager.default.removeItem(at: directory) }
        try "这不是归档".write(
            to: directory.appendingPathComponent("notes.sql"),
            atomically: true,
            encoding: .utf8
        )
        let index = QueryMemory.buildIndex(directory: directory)
        XCTAssertEqual(index.skippedFiles, ["notes.sql"])
    }

    // MARK: 「本次执行不记录」

    func testRecordingPolicy() {
        XCTAssertTrue(MemoryRecordingPolicy(isArchiveEnabled: true).shouldRecord)
        XCTAssertFalse(MemoryRecordingPolicy(isArchiveEnabled: false).shouldRecord)
        let suppressed = MemoryRecordingPolicy(isArchiveEnabled: true, suppressesCurrentRun: true)
        XCTAssertFalse(suppressed.shouldRecord)
        XCTAssertTrue(suppressed.reason.contains("不记录"), suppressed.reason)
        XCTAssertTrue(MemoryRecordingPolicy(isArchiveEnabled: false).reason.contains("未开启"))
    }
}
