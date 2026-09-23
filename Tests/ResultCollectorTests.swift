import XCTest
@testable import DoyahCore

/// 结果截断的回归测试（R-33）。
///
/// 缺陷原貌：取行循环里 `if let maxRows, rows.count >= maxRows { break }` —— 截断**静默**发生，
/// `QueryResult` 里没有任何标记。用户看到 10000 行就会以为那就是全部；
/// 元数据查询（表/列清单）同样有上限，静默截断会让人以为"库里就这么多表"。
final class ResultCollectorTests: XCTestCase {

    func testCollectsAllRowsWhenUnderLimit() {
        var collector = ResultCollector(maxRows: 10)
        for index in 0..<5 {
            XCTAssertTrue(collector.append(["row\(index)"]))
        }
        XCTAssertEqual(collector.rowCount, 5)
        XCTAssertFalse(collector.isTruncated)
    }

    /// 恰好等于上限：**不算截断**（宁可多拉一行来区分，也不给一个含糊的数字）。
    func testExactlyAtLimitIsNotTruncation() {
        var collector = ResultCollector(maxRows: 3)
        for index in 0..<3 {
            XCTAssertTrue(collector.append(["row\(index)"]))
        }
        XCTAssertFalse(collector.isTruncated)
        XCTAssertEqual(collector.makeResult(columns: []).isTruncated, false)
    }

    /// 超过上限：第 N+1 行到达 → 标记截断、停止拉取、结果里带上事实。
    func testExceedingLimitMarksTruncationAndStops() {
        var collector = ResultCollector(maxRows: 3)
        for index in 0..<3 {
            XCTAssertTrue(collector.append(["row\(index)"]))
        }
        XCTAssertFalse(collector.append(["row4"]), "第 N+1 行到达后应让调用方停止拉取")

        let result = collector.makeResult(columns: [ColumnMeta(id: 0, name: "c")])
        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(result.truncationLimit, 3)
        XCTAssertEqual(result.rowCount, 3, "超限的那一行不进入结果")
    }

    /// 无上限时永不截断（显式要求全量的调用方仍然得到全量）。
    func testNoLimitNeverTruncates() {
        var collector = ResultCollector(maxRows: nil)
        for index in 0..<100 {
            XCTAssertTrue(collector.append(["row\(index)"]))
        }
        XCTAssertFalse(collector.isTruncated)
        XCTAssertEqual(collector.rowCount, 100)
    }

    /// 默认选项必须带上限 —— 这条钉住「App 从不设上限」不再复发。
    func testDefaultOptionsCarryARowLimit() {
        XCTAssertEqual(QueryOptions.default.maxRows, QueryLimits.defaultMaxRows)
        XCTAssertNotNil(QueryOptions.default.maxRows, "默认不设上限会让一条 SELECT * 把内存吃满")
    }
}
