import XCTest
@testable import DoyahCore

/// R-21 的「用当前条件生成 WHERE」：条件 → SQL 片段，以及**安全**（用户输入不得变成语法）。
final class ResultFilterSQLTests: XCTestCase {

    private let columns = [
        ResultFilterSQL.Column(name: "id", isNumeric: true),
        ResultFilterSQL.Column(name: "name", isNumeric: false),
    ]

    func testIdentifierAndLiteralQuoting() {
        XCTAssertEqual(ResultFilterSQL.quoteIdentifier("weird\"name"), "\"weird\"\"name\"")
        // 单引号双写 —— 用户输入里的引号只能是数据，不能提前闭合字符串。
        XCTAssertEqual(ResultFilterSQL.quoteLiteral("O'Brien"), "'O''Brien'")
        XCTAssertEqual(ResultFilterSQL.quoteLiteral("'; DROP TABLE t; --"), "'''; DROP TABLE t; --'")
    }

    /// LIKE 通配符必须转义：搜 `100%` 不能变成「以 100 开头」。
    func testLikePatternEscaping() {
        XCTAssertEqual(ResultFilterSQL.escapeLikePattern("100%"), "100\\%")
        XCTAssertEqual(ResultFilterSQL.escapeLikePattern("a_b"), "a\\_b")
        XCTAssertEqual(ResultFilterSQL.escapeLikePattern("c:\\tmp"), "c:\\\\tmp")
    }

    func testContainsUsesIlikeByDefaultAndLikeWhenCaseSensitive() {
        let insensitive = ResultFilter(columnIndex: 1, op: .contains, value: "ab")
        XCTAssertEqual(
            ResultFilterSQL.predicate(for: insensitive, column: columns[1]),
            "CAST(\"name\" AS TEXT) ILIKE '%ab%' ESCAPE '\\'"
        )

        let sensitive = ResultFilter(columnIndex: 1, op: .contains, value: "ab", caseSensitive: true)
        XCTAssertTrue(ResultFilterSQL.predicate(for: sensitive, column: columns[1]).contains(" LIKE "))
    }

    func testNotContainsWrapsInNotToKeepNullSemantics() {
        let filter = ResultFilter(columnIndex: 1, op: .notContains, value: "x")
        let sql = ResultFilterSQL.predicate(for: filter, column: columns[1])
        XCTAssertTrue(sql.hasPrefix("NOT ("), "否则 NULL 行的行为会与客户端不一致：\(sql)")
    }

    func testEqualsIsCaseInsensitiveByDefaultAndEscapes() {
        let filter = ResultFilter(columnIndex: 1, op: .equals, value: "O'Brien")
        XCTAssertEqual(
            ResultFilterSQL.predicate(for: filter, column: columns[1]),
            "LOWER(CAST(\"name\" AS TEXT)) = LOWER('O''Brien')"
        )
    }

    /// 空值语义要与客户端一致：NULL 与空字符串都算「为空」。
    func testEmptyOperatorsCoverNullAndEmptyString() {
        XCTAssertEqual(
            ResultFilterSQL.predicate(for: ResultFilter(columnIndex: 1, op: .isEmpty), column: columns[1]),
            "(\"name\" IS NULL OR CAST(\"name\" AS TEXT) = '')"
        )
        XCTAssertEqual(
            ResultFilterSQL.predicate(for: ResultFilter(columnIndex: 1, op: .isNotEmpty), column: columns[1]),
            "(\"name\" IS NOT NULL AND CAST(\"name\" AS TEXT) <> '')"
        )
    }

    /// 比较运算符：用户填数字 → 数值比较；文本列同理（客户端就是「两侧都是数字才按数值比」）。
    func testComparisonsUseNumericCastOnlyForNumericInput() {
        let numeric = ResultFilter(columnIndex: 0, op: .greaterThan, value: "10")
        XCTAssertEqual(
            ResultFilterSQL.predicate(for: numeric, column: columns[0]),
            "CAST(\"id\" AS NUMERIC) > '10'"
        )

        let text = ResultFilter(columnIndex: 1, op: .lessThanOrEqual, value: "m")
        XCTAssertEqual(
            ResultFilterSQL.predicate(for: text, column: columns[1]),
            "CAST(\"name\" AS TEXT) <= 'm'"
        )
    }

    func testAllOperatorsProduceNonEmptySQL() {
        for op in ResultFilterOperator.allCases {
            let filter = ResultFilter(columnIndex: 1, op: op, value: "v")
            let sql = ResultFilterSQL.predicate(for: filter, column: columns[1])
            XCTAssertFalse(sql.isEmpty, "\(op) 生成的片段不应为空")
            XCTAssertTrue(sql.contains("\"name\""), "\(op) 应引用列名：\(sql)")
        }
    }

    func testWhereClauseJoinsWithAndAndReturnsNilWhenEmpty() throws {
        XCTAssertNil(ResultFilterSQL.whereClause(filters: [], columns: columns))

        let clause = ResultFilterSQL.whereClause(
            filters: [
                ResultFilter(columnIndex: 0, op: .greaterThanOrEqual, value: "2"),
                ResultFilter(columnIndex: 1, op: .contains, value: "a"),
            ],
            columns: columns
        )
        let text = try XCTUnwrap(clause)
        XCTAssertTrue(text.hasPrefix("WHERE "))
        XCTAssertEqual(text.components(separatedBy: "AND").count, 2)
    }

    /// 结果集换过、列变少时，越界条件要丢弃而不是生成引用不存在列的 SQL。
    func testOutOfRangeFilterIsDropped() throws {
        let clause = ResultFilterSQL.whereClause(
            filters: [
                ResultFilter(columnIndex: 9, op: .equals, value: "x"),
                ResultFilter(columnIndex: 1, op: .equals, value: "ok"),
            ],
            columns: columns
        )
        let text = try XCTUnwrap(clause)
        XCTAssertEqual(text, "WHERE LOWER(CAST(\"name\" AS TEXT)) = LOWER('ok')")
    }

    func testNumericLiteralDetection() {
        XCTAssertTrue(ResultFilterSQL.isNumericLiteral("10"))
        XCTAssertTrue(ResultFilterSQL.isNumericLiteral(" -3.5 "))
        XCTAssertFalse(ResultFilterSQL.isNumericLiteral(""))
        XCTAssertFalse(ResultFilterSQL.isNumericLiteral("1,000"))
        XCTAssertFalse(ResultFilterSQL.isNumericLiteral("abc"))
    }
}
