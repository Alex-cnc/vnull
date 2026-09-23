import XCTest
@testable import DoyahCore

/// 结果区客户端视图状态（FR-RES-08 / 09 / 10）：表头排序循环、筛选条、分页条。
///
/// 这里钉住的都是**容易在界面上悄悄做错**的耦合：
/// 改筛选 / 改每页行数要回第 1 页；数据变少时页码要被夹取；排序三下要回到原始顺序。
final class ResultGridStateTests: XCTestCase {

    private let rows: [[String?]] = [
        ["3", "charlie"],
        ["1", "alpha"],
        ["2", "bravo"],
        ["10", "delta"],
    ]

    // MARK: 排序（FR-RES-08）

    /// 表头连点三下：升序 → 降序 → 取消（回到服务端顺序）。
    func testHeaderClickCyclesAscendingDescendingOff() {
        var state = ResultGridState()
        XCTAssertNil(state.order(forColumn: 0))

        state.toggleSort(columnIndex: 0)
        XCTAssertEqual(state.order(forColumn: 0), .ascending)
        XCTAssertEqual(state.page(of: rows).rows.map { $0[1] }, ["alpha", "bravo", "charlie", "delta"])

        state.toggleSort(columnIndex: 0)
        XCTAssertEqual(state.order(forColumn: 0), .descending)
        XCTAssertEqual(state.page(of: rows).rows.map { $0[1] }, ["delta", "charlie", "bravo", "alpha"])

        state.toggleSort(columnIndex: 0)
        XCTAssertNil(state.order(forColumn: 0))
        // 取消排序 = 回到原始顺序，而不是停在降序。
        XCTAssertEqual(state.page(of: rows).rows.map { $0[1] }, ["charlie", "alpha", "bravo", "delta"])
    }

    /// 数字列按数值排序（`2 < 10`），不是字符串序。
    func testNumericColumnSortsNumerically() {
        var state = ResultGridState()
        state.toggleSort(columnIndex: 0)
        XCTAssertEqual(state.page(of: rows).rows.map { $0[0] }, ["1", "2", "3", "10"])
    }

    /// 点另一列（不加 Shift）= 替换整组排序键。
    func testPlainClickReplacesSortKeys() {
        var state = ResultGridState()
        state.toggleSort(columnIndex: 0)
        state.toggleSort(columnIndex: 1)
        XCTAssertEqual(state.sortDescriptors.count, 1)
        XCTAssertEqual(state.sortDescriptors.first?.columnIndex, 1)
    }

    /// Shift 点击 = 追加次要排序键，并在界面上能标出次序。
    func testAdditiveClickAppendsSecondaryKey() {
        var state = ResultGridState()
        state.toggleSort(columnIndex: 1)
        state.toggleSort(columnIndex: 0, additive: true)

        XCTAssertEqual(state.sortDescriptors.count, 2)
        XCTAssertEqual(state.sortRank(forColumn: 1), 1)
        XCTAssertEqual(state.sortRank(forColumn: 0), 2)
        XCTAssertNil(state.sortRank(forColumn: 2))

        // 次要键上继续点击只翻它自己的方向。
        state.toggleSort(columnIndex: 0, additive: true)
        XCTAssertEqual(state.order(forColumn: 0), .descending)
        XCTAssertEqual(state.sortDescriptors.count, 2)

        // 再翻一轮把它移出排序键，主键不受影响。
        state.toggleSort(columnIndex: 0, additive: true)
        XCTAssertNil(state.order(forColumn: 0))
        XCTAssertEqual(state.sortDescriptors.count, 1)
        XCTAssertEqual(state.sortDescriptors.first?.columnIndex, 1)
    }

    func testSortRankIsOneBasedAcrossThreeKeys() {
        var state = ResultGridState()
        state.toggleSort(columnIndex: 2)
        state.toggleSort(columnIndex: 0, additive: true)
        state.toggleSort(columnIndex: 1, additive: true)
        XCTAssertEqual(state.sortRank(forColumn: 2), 1)
        XCTAssertEqual(state.sortRank(forColumn: 0), 2)
        XCTAssertEqual(state.sortRank(forColumn: 1), 3)
    }

    // MARK: 筛选（FR-RES-09）

    func testFilterNarrowsRowsAndResetsToFirstPage() throws {
        var state = ResultGridState(pageIndex: 1, pageSize: 2)
        state.addFilter(columnIndex: 1, op: .contains, value: "l")

        // 加条件后必须回第 1 页：否则「筛出 3 行却停在原来的第 2 页」会显示空白。
        XCTAssertEqual(state.pageIndex, 0)
        let page = state.page(of: rows)
        XCTAssertEqual(page.totalRows, 3, "charlie / alpha / delta 含 l")
        XCTAssertEqual(page.rows.map { $0[1] }, ["charlie", "alpha"], "每页 2 行，只看第一页")
    }

    func testMultipleFiltersCombineWithAnd() {
        var state = ResultGridState()
        state.addFilter(columnIndex: 1, op: .contains, value: "a")
        state.addFilter(columnIndex: 1, op: .notContains, value: "l")
        // charlie / alpha / delta 都含 "l" 被第二条排除，只剩 bravo。
        XCTAssertEqual(state.page(of: rows).rows.map { $0[1] }, ["bravo"])
    }

    func testRemoveFilterGoesBackToFirstPage() {
        var state = ResultGridState()
        state.addFilter(columnIndex: 0, op: .equals, value: "1")
        state.updateFilter(at: 0, to: ResultFilter(columnIndex: 0, op: .equals, value: "2"))
        XCTAssertEqual(state.page(of: rows).rows.map { $0[1] }, ["bravo"])

        state.removeFilter(at: 0)
        XCTAssertTrue(state.filters.isEmpty)
        XCTAssertEqual(state.pageIndex, 0)
        XCTAssertEqual(state.page(of: rows).totalRows, 4)
    }

    func testOutOfRangeFilterEditsAreIgnored() {
        var state = ResultGridState()
        state.removeFilter(at: 3)
        state.updateFilter(at: 3, to: ResultFilter(columnIndex: 0, op: .equals, value: "x"))
        XCTAssertTrue(state.filters.isEmpty)
    }

    // MARK: 分页（FR-RES-10）

    func testPagingSlicesRowsAndReportsTotals() {
        var state = ResultGridState(pageSize: 2)
        let first = state.page(of: rows)
        XCTAssertEqual(first.rows.map { $0[1] }, ["charlie", "alpha"])
        XCTAssertEqual(first.pageCount, 2)
        XCTAssertEqual(first.totalRows, 4)

        state.adopt(pageIndex: state.nextPageIndex(after: first))
        let second = state.page(of: rows)
        XCTAssertEqual(second.rows.map { $0[1] }, ["bravo", "delta"])
        XCTAssertEqual(second.pageIndex, 1)

        // 末页再点「下一页」不动。
        XCTAssertEqual(state.nextPageIndex(after: second), 1)
        XCTAssertEqual(state.previousPageIndex(after: second), 0)
    }

    /// 数据变少后页码被夹取：不能停在越界页显示空白。
    func testPageIndexIsClampedWhenRowsShrink() {
        var state = ResultGridState(pageIndex: 99, pageSize: 2)
        let page = state.page(of: rows)
        XCTAssertEqual(page.pageIndex, 1, "越界页码应夹取到最后一页")
        XCTAssertEqual(page.rows.count, 2)

        state.adopt(pageIndex: page.pageIndex)
        state.addFilter(columnIndex: 0, op: .equals, value: "1")
        let filtered = state.page(of: rows)
        XCTAssertEqual(filtered.pageIndex, 0)
        XCTAssertEqual(filtered.rows.count, 1)
    }

    func testChangingPageSizeResetsToFirstPage() {
        var state = ResultGridState(pageIndex: 3, pageSize: 50)
        state.setPageSize(500)
        XCTAssertEqual(state.pageIndex, 0)
        XCTAssertEqual(state.pageSize, 500)
    }

    /// `pageSize == 0` = 不分页，整段返回（界面上属于「全部」档）。
    func testZeroPageSizeMeansNoPaging() {
        var state = ResultGridState(pageSize: 0)
        state.adopt(pageIndex: 3)
        let page = state.page(of: rows)
        XCTAssertEqual(page.rows.count, 4)
        XCTAssertEqual(page.pageIndex, 0)
        XCTAssertEqual(page.pageCount, 1)
        XCTAssertFalse(state.isPaged)
    }

    /// 每页行数档位与需求一致（FR-RES-10：50 / 100 / 200 / 500 / 1000）。
    func testPageSizeOptionsMatchRequirement() {
        XCTAssertEqual(ResultView.pageSizeOptions, [50, 100, 200, 500, 1_000])
        XCTAssertTrue(ResultView.pageSizeOptions.contains(ResultGridState.defaultPageSize))
    }

    // MARK: R-21 提示条的出现条件

    /// 「仅对已加载的 N 行生效」只在真的做了客户端操作时出现。
    func testClientViewActiveFlag() {
        var state = ResultGridState()
        XCTAssertFalse(state.isClientViewActive)

        state.toggleSort(columnIndex: 0)
        XCTAssertTrue(state.isClientViewActive)

        state.clearAll()
        XCTAssertFalse(state.isClientViewActive)

        state.addFilter(columnIndex: 0, op: .isEmpty)
        XCTAssertTrue(state.isClientViewActive)
    }
}
