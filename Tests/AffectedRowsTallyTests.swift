import XCTest
@testable import DoyahCore

/// 影响行数计数的回归测试（R-32）。
///
/// 缺陷原貌（2026-09-23 评审确认）：同一条 DML 既发 `.resultSet(携带 affectedRows)`
/// 又发 `.affectedRows`，App 侧两条分支都累加 ⇒ 写进当天归档与 `task-runs.jsonl`
/// 的**行数系统性翻倍**。归档是复盘与审计的依据，数字翻倍比没有数字更糟。
///
/// 修复分两层：① 事件通道收成一条（`.affectedRows` 这个 case 已从 `QueryEvent` 删除）；
/// ② 计数收进 `AffectedRowsTally` 这唯一入口。这组测试钉住第 ② 层的行为。
final class AffectedRowsTallyTests: XCTestCase {

    private func result(affected: Int? = nil, rowCount: Int = 0) -> QueryResult {
        QueryResult(
            columns: rowCount > 0 ? [ColumnMeta(id: 0, name: "c")] : [],
            rows: Array(repeating: ["v"], count: rowCount),
            affectedRows: affected
        )
    }

    /// 回归主用例：**一条 DML 只累加一次**。
    ///
    /// 用的是驱动现在真正会发的事件序列（DML 路径：started → resultSet(带行数) → finished）。
    func testSingleStatementCountsExactlyOnce() {
        var tally = AffectedRowsTally()
        let events: [QueryEvent] = [
            .started(statementIndex: 0),
            .resultSet(result(affected: 3)),
            .finished(QuerySummary(statementCount: 1, duration: 0.01))
        ]
        events.forEach { tally.absorb($0) }

        XCTAssertEqual(tally.value, 3, "一条 DML 的影响行数只能是 3，不能因为多一条通道变成 6")
        XCTAssertEqual(tally.total, 3)
    }

    /// 多语句累加：三条 DML 各 2 / 5 / 1 行 → 8。
    func testSumsAcrossStatements() throws {
        var tally = AffectedRowsTally()
        for affected in [2, 5, 1] {
            tally.absorb(.started(statementIndex: 0))
            tally.absorb(.resultSet(result(affected: affected)))
        }
        XCTAssertEqual(tally.value, 8)
    }

    /// 「一条都没报过」必须是 `nil` 而不是 0。
    ///
    /// 归档里「0 行受影响」与「这条语句不报行数」（例如 SELECT、DDL）是两件事；
    /// 混成一个 0 就等于在归档里编造事实。
    func testNilWhenNothingWasReported() {
        var tally = AffectedRowsTally()
        tally.absorb(.started(statementIndex: 0))
        tally.absorb(.resultSet(result(rowCount: 10)))
        tally.absorb(.notice("some notice"))
        tally.absorb(.finished(QuerySummary(statementCount: 1, duration: 0.02)))

        XCTAssertNil(tally.value)
        XCTAssertFalse(tally.sawAny)
    }

    /// 真的报 0 行时，要如实给出 0（与上一条区分开）。
    func testReportedZeroIsZeroNotNil() {
        var tally = AffectedRowsTally()
        tally.absorb(.resultSet(result(affected: 0)))

        XCTAssertEqual(tally.value, 0)
        XCTAssertTrue(tally.sawAny)
    }

    /// 无结果集通知、失败前的部分结果都要能算进去（失败分支同样要写归档）。
    func testPartialResultsBeforeFailureAreKept() {
        var tally = AffectedRowsTally()
        tally.absorb(.started(statementIndex: 0))
        tally.absorb(.resultSet(result(affected: 4)))
        tally.absorb(.started(statementIndex: 1))

        XCTAssertEqual(tally.value, 4, "第 2 条语句失败时，第 1 条已写下的 4 行仍要进归档")
    }
}
