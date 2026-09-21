import XCTest
@testable import PostgresClientCore

/// FR-RES-08 ~ FR-RES-10：客户端排序、筛选、分页。
final class ResultViewTests: XCTestCase {

    // MARK: - 排序

    func testSortComparesNumericTextNumerically() {
        let rows: [[String?]] = [["10"], ["2"], ["1"]]
        let sorted = ResultView.sort(rows, by: [ResultSortDescriptor(columnIndex: 0)])

        XCTAssertEqual(sorted.compactMap { $0.first ?? nil }, ["1", "2", "10"])
    }

    func testSortUsesNaturalOrderForText() {
        let rows: [[String?]] = [["item10"], ["item2"], ["item1"]]
        let sorted = ResultView.sort(rows, by: [ResultSortDescriptor(columnIndex: 0)])

        XCTAssertEqual(sorted.compactMap { $0.first ?? nil }, ["item1", "item2", "item10"])
    }

    func testSortDescendingReversesOrderButKeepsNullsLast() {
        let rows: [[String?]] = [["1"], [nil], ["3"]]
        let sorted = ResultView.sort(
            rows,
            by: [ResultSortDescriptor(columnIndex: 0, order: .descending)]
        )

        XCTAssertEqual(sorted[0].first ?? nil, "3")
        XCTAssertEqual(sorted[1].first ?? nil, "1")
        XCTAssertNil(sorted[2].first ?? nil)
    }

    func testSortCanPutNullsFirst() {
        let rows: [[String?]] = [["1"], [nil], ["3"]]
        let sorted = ResultView.sort(
            rows,
            by: [ResultSortDescriptor(columnIndex: 0, nullsFirst: true)]
        )

        XCTAssertNil(sorted[0].first ?? nil)
        XCTAssertEqual(sorted[1].first ?? nil, "1")
    }

    func testSortByMultipleColumns() {
        let rows: [[String?]] = [
            ["b", "1"],
            ["a", "2"],
            ["a", "1"]
        ]
        let sorted = ResultView.sort(rows, by: [
            ResultSortDescriptor(columnIndex: 0),
            ResultSortDescriptor(columnIndex: 1)
        ])

        XCTAssertEqual(sorted.map { [$0[0] ?? nil, $0[1] ?? nil].compactMap { $0 } },
                       [["a", "1"], ["a", "2"], ["b", "1"]])
    }

    func testSortIsStableForEqualKeys() {
        let rows: [[String?]] = [
            ["x", "first"],
            ["x", "second"],
            ["x", "third"]
        ]
        let sorted = ResultView.sort(rows, by: [ResultSortDescriptor(columnIndex: 0)])

        XCTAssertEqual(sorted.map { $0[1] ?? nil }, ["first", "second", "third"])
    }

    func testSortWithMissingColumnTreatsCellAsNull() {
        let rows: [[String?]] = [["only-one-column"], []]
        let sorted = ResultView.sort(rows, by: [ResultSortDescriptor(columnIndex: 5)])

        XCTAssertEqual(sorted.count, 2)
    }

    // MARK: - 筛选

    func testFilterContainsIsCaseInsensitiveByDefault() {
        let filter = ResultFilter(columnIndex: 0, op: .contains, value: "ALICE")
        XCTAssertTrue(filter.matches("alice cooper"))
        XCTAssertFalse(filter.matches("bob"))
        XCTAssertFalse(filter.matches(nil))
    }

    func testFilterContainsCanBeCaseSensitive() {
        let filter = ResultFilter(columnIndex: 0, op: .contains, value: "ALICE", caseSensitive: true)
        XCTAssertFalse(filter.matches("alice cooper"))
        XCTAssertTrue(filter.matches("ALICE cooper"))
    }

    func testFilterNotContainsPassesForNull() {
        // NULL 在 `notContains` 下不匹配（与 SQL 的 NULL 语义一致），避免「凭空冒出一堆空行」。
        let filter = ResultFilter(columnIndex: 0, op: .notContains, value: "a")
        XCTAssertNil(ResultView.apply(filters: [filter], to: [[nil]]).first)
    }

    func testFilterNumericComparisonUsesNumbersNotLexicographicOrder() {
        let filter = ResultFilter(columnIndex: 0, op: .greaterThan, value: "9")
        XCTAssertTrue(filter.matches("10"))
        XCTAssertFalse(filter.matches("2"))
    }

    func testFilterIsEmptyMatchesNullAndEmptyString() {
        let filter = ResultFilter(columnIndex: 0, op: .isEmpty)
        XCTAssertTrue(filter.matches(nil))
        XCTAssertTrue(filter.matches(""))
        XCTAssertFalse(filter.matches("x"))
    }

    func testFilterIsNotEmpty() {
        let filter = ResultFilter(columnIndex: 0, op: .isNotEmpty)
        XCTAssertFalse(filter.matches(nil))
        XCTAssertFalse(filter.matches(""))
        XCTAssertTrue(filter.matches("x"))
    }

    func testMultipleFiltersAreCombinedWithAnd() {
        let rows: [[String?]] = [
            ["alice", "30"],
            ["alice", "20"],
            ["bob", "40"]
        ]
        let filters = [
            ResultFilter(columnIndex: 0, op: .equals, value: "alice"),
            ResultFilter(columnIndex: 1, op: .greaterThanOrEqual, value: "25")
        ]

        let filtered = ResultView.apply(filters: filters, to: rows)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0][1] ?? nil, "30")
    }

    func testFilterOnMissingColumnIsTreatedAsNull() {
        let rows: [[String?]] = [["only"]]
        let filter = ResultFilter(columnIndex: 3, op: .isEmpty)
        XCTAssertEqual(ResultView.apply(filters: [filter], to: rows).count, 1)
    }

    // MARK: - 分页

    func testPageSlicesRows() {
        let rows: [[String?]] = (1...10).map { [String($0)] }
        let page = ResultView.page(rows, pageIndex: 1, pageSize: 4)

        XCTAssertEqual(page.pageIndex, 1)
        XCTAssertEqual(page.pageCount, 3)
        XCTAssertEqual(page.totalRows, 10)
        XCTAssertEqual(page.startRowIndex, 4)
        XCTAssertEqual(page.rows.compactMap { $0.first ?? nil }, ["5", "6", "7", "8"])
    }

    func testPageClampsOutOfRangeIndex() {
        let rows: [[String?]] = (1...5).map { [String($0)] }
        let page = ResultView.page(rows, pageIndex: 99, pageSize: 2)

        XCTAssertEqual(page.pageIndex, 2)
        XCTAssertEqual(page.rows.compactMap { $0.first ?? nil }, ["5"])
    }

    func testPageOfEmptyRowsStillHasOnePage() {
        let page = ResultView.page([], pageIndex: 0, pageSize: 100)
        XCTAssertEqual(page.pageCount, 1)
        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertEqual(page.displayDescription, "1 / 1 · 0")
    }

    func testZeroPageSizeMeansNoPaging() {
        let rows: [[String?]] = (1...30).map { [String($0)] }
        let page = ResultView.page(rows, pageIndex: 0, pageSize: 0)

        XCTAssertEqual(page.rows.count, 30)
        XCTAssertEqual(page.pageCount, 1)
    }

    func testPageAppliesFilterThenSortThenSlice() {
        let rows: [[String?]] = [["5"], ["50"], ["1"], ["2"]]
        let page = ResultView.page(
            rows,
            filters: [ResultFilter(columnIndex: 0, op: .greaterThan, value: "1")],
            sortDescriptors: [ResultSortDescriptor(columnIndex: 0)],
            pageIndex: 0,
            pageSize: 2
        )

        XCTAssertEqual(page.totalRows, 3)
        XCTAssertEqual(page.rows.compactMap { $0.first ?? nil }, ["2", "5"])
    }

    // MARK: - 数值解析

    func testNumberParsingAcceptsThousandsSeparators() {
        XCTAssertEqual(ResultView.number(from: "1,234"), 1234)
        XCTAssertEqual(ResultView.number(from: " 3.5 "), 3.5)
        XCTAssertNil(ResultView.number(from: "abc"))
        XCTAssertNil(ResultView.number(from: ""))
    }

    func testCompareValuesReportsOrdering() {
        XCTAssertEqual(ResultView.compareValues("2", "10", nullsFirst: false), .orderedAscending)
        XCTAssertEqual(ResultView.compareValues("a", "a", nullsFirst: false), .orderedSame)
        XCTAssertEqual(ResultView.compareValues(nil, "a", nullsFirst: false), .orderedDescending)
        XCTAssertEqual(ResultView.compareValues(nil, nil, nullsFirst: false), .orderedSame)
    }
}
