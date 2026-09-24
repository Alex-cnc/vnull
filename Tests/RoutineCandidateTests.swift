import XCTest
@testable import DoyahCore

/// 参数化与技能候选（FR-AI-14）。
///
/// 这一层最容易做错的地方**不是"能不能算出候选"**，而是：
/// ① 判据被悄悄放宽（于是把一次性排障脚本建议去定时 —— 误判代价不对称，危险的那一侧）；
/// ② 粗指纹碰撞被当成"只改参数"；
/// ③ 输出不确定（同一输入两次运行给出不同顺序，报告就没人信）。
/// 所以下面的用例大体按这三件事分。
final class RoutineCandidateTests: XCTestCase {

    // MARK: 参数模板

    func testAlignFindsOneSlotAndRendersQuestionMark() {
        let parameterization = RoutineCandidate.align([
            "SELECT * FROM orders WHERE status = 'paid'",
            "SELECT * FROM orders WHERE status = 'refunded'"
        ])
        let unwrapped = try? XCTUnwrap(parameterization)
        XCTAssertNotNil(unwrapped)
        guard let parameterization = unwrapped else { return }
        XCTAssertEqual(parameterization.slotCount, 1)
        XCTAssertEqual(parameterization.samples.count, 1)
        XCTAssertEqual(parameterization.samples[0], ["'paid'", "'refunded'"])   // 排序后
        XCTAssertEqual(
            parameterization.template(),
            "SELECT * FROM orders WHERE status = ?"
        )
    }

    /// 所有原文里取值相同的字面量**保持字面量**，不该被当成槽位（否则模板全是 `?`，没人看得懂）。
    func testAlignKeepsIdenticalLiteralFixed() {
        let parameterization = RoutineCandidate.align([
            "SELECT * FROM orders WHERE status = 'paid' AND id = 1",
            "SELECT * FROM orders WHERE status = 'paid' AND id = 2"
        ])
        guard let parameterization else { return XCTFail("应当能对齐") }
        XCTAssertEqual(parameterization.slotCount, 1)
        XCTAssertEqual(
            parameterization.template(),
            "SELECT * FROM orders WHERE status = 'paid' AND id = ?"
        )
    }

    func testAlignRejectsDifferentStructure() {
        // 字面量个数不同 = 结构不同，不能逐字还原。
        XCTAssertNil(RoutineCandidate.align([
            "SELECT * FROM orders WHERE id = 1",
            "SELECT * FROM orders WHERE id = 1 AND status = 'paid'"
        ]))
    }

    /// **粗指纹碰撞必须被挡下**：`SELECT` 与 `select` 的粗指纹相同（骨架整体小写化），
    /// 但两者不可能由同一个模板逐字还原 —— 若放过去，"只改参数"这条判据就是假的。
    func testAlignRejectsCaseDifferenceDespiteSameFingerprint() {
        let upper = "SELECT * FROM orders WHERE id = 1"
        let lower = "select * from orders where id = 1"
        XCTAssertEqual(
            QueryMemory.coarseFingerprint(upper),
            QueryMemory.coarseFingerprint(lower),
            "前提：粗指纹确实把这两种写法归成同一个骨架"
        )
        XCTAssertNil(RoutineCandidate.align([upper, lower]), "结构不同（大小写）必须对不齐")
    }

    /// 输入顺序不影响结果（集合遍历顺序也不许影响）—— 否则"两次运行逐字一致"会破。
    func testAlignIsOrderIndependent() {
        let a = "SELECT * FROM t WHERE a = 1 AND b = 'x'"
        let b = "SELECT * FROM t WHERE a = 2 AND b = 'y'"
        XCTAssertEqual(RoutineCandidate.align([a, b]), RoutineCandidate.align([b, a]))
    }

    func testAlignSamplesBoundedAndSorted() {
        let sqls = (1...8).map { "SELECT * FROM t WHERE a = \($0)" }
        guard let parameterization = RoutineCandidate.align(sqls, maximumSamples: 3) else {
            return XCTFail("应当能对齐")
        }
        XCTAssertEqual(parameterization.samples[0].count, 3, "样例必须**有界**")
        XCTAssertEqual(parameterization.samples[0], parameterization.samples[0].sorted())
    }

    // MARK: 时刻集中度

    /// 跨午夜的窗口要算在一起：23 点起的三小时窗口含 23 / 0 / 1。
    func testConcentrationPicksBestWindowAcrossMidnight() {
        var histogram = Array(repeating: 0, count: 24)
        histogram[23] = 3
        histogram[0] = 2
        histogram[1] = 1
        let concentration = RoutineCandidate.concentration(histogram: histogram, windowHours: 3)
        XCTAssertEqual(concentration.startHour, 23)
        XCTAssertEqual(concentration.windowRunCount, 6)
        XCTAssertEqual(concentration.ratio, 1.0, accuracy: 0.0001)
    }

    func testConcentrationIsZeroWithoutEvidence() {
        let concentration = RoutineCandidate.concentration(histogram: Array(repeating: 0, count: 24))
        XCTAssertEqual(concentration.totalRunCount, 0)
        XCTAssertEqual(concentration.ratio, 0, "没有证据就不算集中")
    }

    /// 并列时取**最小起点**：数据稀疏时大量窗口都是 0，不定死规则报告就会每次不一样。
    func testConcentrationTieBreaksToSmallestStartHour() {
        let concentration = RoutineCandidate.concentration(histogram: Array(repeating: 0, count: 24))
        XCTAssertEqual(concentration.startHour, 0)
    }

    // MARK: 四条判据（每条都要单独验一次）

    private func memory(
        variants: [String],
        runCount: Int,
        dayCount: Int,
        hours: [Int: Int],
        connections: Set<String> = ["生产库"]
    ) -> QueryMemory.Memory {
        var histogram = Array(repeating: 0, count: 24)
        for (hour, count) in hours { histogram[hour] = count }
        let days = Set((0..<dayCount).map { "2026-09-\(String(format: "%02d", $0 + 1))" })
        return QueryMemory.Memory(
            fingerprint: QueryMemory.coarseFingerprint(variants[0]),
            latestSQL: variants.last ?? "",
            variantCount: Set(variants).count,
            runCount: runCount,
            days: days,
            connections: connections,
            lastExecutedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hourHistogram: histogram,
            parameterization: RoutineCandidate.align(variants)
        )
    }

    /// 四条齐全 → 是候选。
    func testAllCriteriaSatisfiedYieldsCandidate() {
        let index = QueryMemory.Index(memories: [
            memory(
                variants: [
                    "SELECT count(*) FROM orders WHERE status = 'paid'",
                    "SELECT count(*) FROM orders WHERE status = 'refunded'"
                ],
                runCount: 12, dayCount: 5, hours: [9: 5, 10: 5, 11: 2]
            )
        ])
        let report = RoutineCandidate.evaluate(index: index)
        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(report.candidates[0].template, "SELECT count(*) FROM orders WHERE status = ?")
        XCTAssertEqual(report.assessments.count, 1)
        XCTAssertTrue(report.assessments[0].reasons.isEmpty)
    }

    /// 逐条否掉：**每条判据单独验一次**，证明它真的在起作用（不是摆设）。
    func testEachCriterionAloneBlocksPromotion() {
        let variants = [
            "SELECT * FROM orders WHERE id = 1",
            "SELECT * FROM orders WHERE id = 2"
        ]
        // 只有「跨天频次」不达标
        let lowFrequency = QueryMemory.Index(memories: [
            memory(variants: variants, runCount: 4, dayCount: 5, hours: [9: 2, 10: 2])
        ])
        assertBlocks(lowFrequency, reasonContains: "跨天频次")

        // 只有「跨越天数」不达标
        let fewDays = QueryMemory.Index(memories: [
            memory(variants: variants, runCount: 20, dayCount: 2, hours: [9: 10, 10: 10])
        ])
        assertBlocks(fewDays, reasonContains: "跨越天数")

        // 只有「时刻集中度」不达标：一天里摊平在 12 个不同小时
        let scattered = QueryMemory.Index(memories: [
            memory(variants: variants, runCount: 12, dayCount: 5, hours: [0: 1, 2: 1, 4: 1, 6: 1, 8: 1, 10: 1, 12: 1, 14: 1, 16: 1, 18: 1, 20: 1, 22: 1])
        ])
        assertBlocks(scattered, reasonContains: "时刻集中度")

        // 只有「只改参数」不达标：单条原文重复执行（不是参数化，只是重复）
        let single = QueryMemory.Index(memories: [
            memory(variants: ["SELECT * FROM orders WHERE id = 1"], runCount: 12, dayCount: 5, hours: [9: 6, 10: 6])
        ])
        assertBlocks(single, reasonContains: "只改参数")
    }

    private func assertBlocks(
        _ index: QueryMemory.Index,
        reasonContains needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let report = RoutineCandidate.evaluate(index: index)
        XCTAssertTrue(report.candidates.isEmpty, "不该成为候选（原因应含「\(needle)」）", file: file, line: line)
        let reasons = report.assessments.flatMap(\.reasons)
        XCTAssertTrue(
            reasons.contains { $0.contains(needle) },
            "原因里应出现「\(needle)」，实际：\(reasons)",
            file: file, line: line
        )
    }

    // MARK: 人工决定

    func testVetoedFingerprintExcludedAndReported() {
        let variant = memory(
            variants: ["SELECT * FROM orders WHERE id = 1", "SELECT * FROM orders WHERE id = 2"],
            runCount: 12, dayCount: 5, hours: [9: 6, 10: 6]
        )
        let index = QueryMemory.Index(memories: [variant])
        XCTAssertEqual(RoutineCandidate.evaluate(index: index).candidates.count, 1, "前提：本来是候选")

        var decisions = MemoryDecisions()
        decisions.veto(fingerprint: variant.fingerprint)
        let report = RoutineCandidate.evaluate(index: index, decisions: decisions)
        XCTAssertTrue(report.candidates.isEmpty, "被否决后不该再出现")
        XCTAssertTrue(report.assessments.isEmpty, "否决项直接不进评估")
        XCTAssertEqual(report.vetoedFingerprints, [variant.fingerprint], "但要如实报告哪些被否决了")
    }

    /// 「保留字面量」**只改模板渲染**，不改聚类与频次（改了会与 FR-AI-13 的语义打架）。
    func testKeptLiteralChangesTemplateOnly() {
        let variant = memory(
            variants: [
                "SELECT * FROM orders WHERE status = 'paid' AND id = 1",
                "SELECT * FROM orders WHERE status = 'paid' AND id = 2"
            ],
            runCount: 12, dayCount: 5, hours: [9: 6, 10: 6]
        )
        let index = QueryMemory.Index(memories: [variant])
        XCTAssertEqual(
            RoutineCandidate.evaluate(index: index).candidates[0].template,
            "SELECT * FROM orders WHERE status = 'paid' AND id = ?"
        )

        // 把那个**槽位**的取值标成"这不是参数"：模板里它变回字面量
        var decisions = MemoryDecisions()
        decisions.keepLiteral(fingerprint: variant.fingerprint, literal: "2")
        let report = RoutineCandidate.evaluate(index: index, decisions: decisions)
        XCTAssertEqual(report.candidates.count, 1, "订正不该把候选本身取消掉")
        XCTAssertEqual(
            report.candidates[0].template,
            "SELECT * FROM orders WHERE status = 'paid' AND id = 2"
        )
        XCTAssertEqual(report.candidates[0].runCount, 12, "频次不许因为订正而变化")
        XCTAssertEqual(report.candidates[0].dayCount, 5, "天数同理")
    }

    func testEvaluationIsDeterministic() {
        let memories = (1...3).map { table in
            memory(
                variants: [
                    "SELECT * FROM t\(table) WHERE id = 1",
                    "SELECT * FROM t\(table) WHERE id = 2"
                ],
                runCount: 6 + table, dayCount: 4, hours: [8: 3, 9: 3]
            )
        }
        let index = QueryMemory.Index(memories: memories)
        XCTAssertEqual(
            RoutineCandidate.evaluate(index: index),
            RoutineCandidate.evaluate(index: index),
            "同一输入两次评估必须逐字一致"
        )
    }

    func testDecisionsRoundTripThroughStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doyah-decisions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var decisions = MemoryDecisions()
        decisions.veto(fingerprint: "fp-a")
        decisions.keepLiteral(fingerprint: "fp-b", literal: "'paid'")
        try MemoryDecisionsStore.save(decisions, to: directory)

        let loaded = MemoryDecisionsStore.load(from: directory)
        XCTAssertTrue(loaded.warnings.isEmpty, "\(loaded.warnings)")
        XCTAssertEqual(loaded.decisions, decisions, "往返后必须完全一致（含顺序）")
    }

    /// 坏文件 / 不存在都**不许炸掉调用方**：退回空决定集并报告原因。
    func testBadDecisionFileFallsBackWithWarning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doyah-decisions-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(MemoryDecisionsStore.load(from: directory).decisions.isEmpty, "文件不存在 → 空决定集")

        try "{ 这不是 JSON".write(
            to: MemoryDecisionsStore.fileURL(in: directory),
            atomically: true,
            encoding: .utf8
        )
        let loaded = MemoryDecisionsStore.load(from: directory)
        XCTAssertTrue(loaded.decisions.isEmpty)
        XCTAssertFalse(loaded.warnings.isEmpty, "坏文件必须报告，不许静默吞掉")
    }
}
