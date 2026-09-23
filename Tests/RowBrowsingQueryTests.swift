import XCTest
@testable import DoyahCore

/// 按条件浏览 / 计数（FR-DATA-02）：条件在**服务端**执行，因此生成规则要与 SQL 语义一致，
/// 且**多语句必须被拒绝**（一个"浏览"按钮不该执行 `; DROP TABLE`）。
final class RowBrowsingQueryTests: XCTestCase {

    private let postgres = PostgresDialect()
    private let gbase = GBaseDialect()

    private func browse(_ filter: RowBrowsingQuery.Filter, dialect: any SQLDialect = PostgresDialect()) -> String? {
        guard case .success(let sql) = RowBrowsingQuery.browse(table: "t", schema: "public", filter: filter, dialect: dialect) else { return nil }
        return sql
    }

    private func browseError(_ filter: RowBrowsingQuery.Filter) -> RowBrowsingQuery.BuildError? {
        guard case .failure(let error) = RowBrowsingQuery.browse(table: "t", schema: "public", filter: filter, dialect: postgres) else { return nil }
        return error
    }

    // MARK: 基本形状

    func testBrowseWithoutConditions() {
        XCTAssertEqual(
            browse(RowBrowsingQuery.Filter()),
            "SELECT * FROM \"public\".\"t\" LIMIT 200 OFFSET 0;"
        )
    }

    /// 子句顺序固定 WHERE → ORDER BY → 分页：分页放最后，否则语法就错。
    func testBrowseKeepsClauseOrder() {
        let sql = browse(RowBrowsingQuery.Filter(whereClause: "id > 10", orderBy: "id DESC", limit: 50, offset: 100))
        XCTAssertEqual(sql, "SELECT * FROM \"public\".\"t\" WHERE id > 10 ORDER BY id DESC LIMIT 50 OFFSET 100;")
    }

    /// GBase 的分页写法不同（`LIMIT offset, count`），必须走方言而不是硬编码。
    func testBrowseUsesDialectLimitClause() {
        let sql = browse(RowBrowsingQuery.Filter(limit: 20, offset: 5), dialect: gbase)
        // GBase 用反引号引用标识符 —— 这条断言本身就是"必须走方言"的证据。
        XCTAssertEqual(sql, "SELECT * FROM `t` LIMIT 5, 20;")
    }

    func testNegativeLimitAndOffsetAreClampedToZero() {
        let sql = browse(RowBrowsingQuery.Filter(limit: -5, offset: -3))
        XCTAssertEqual(sql, "SELECT * FROM \"public\".\"t\" LIMIT 0 OFFSET 0;")
    }

    // MARK: 关键字与分号

    /// 用户把 `WHERE` 一起粘进来也接受（`WHERE a = 1` 与 `a = 1` 等价）。
    func testLeadingKeywordsAreTolerated() {
        XCTAssertEqual(
            browse(RowBrowsingQuery.Filter(whereClause: "WHERE id = 1")),
            "SELECT * FROM \"public\".\"t\" WHERE id = 1 LIMIT 200 OFFSET 0;"
        )
        XCTAssertEqual(
            browse(RowBrowsingQuery.Filter(orderBy: "ORDER BY id")),
            "SELECT * FROM \"public\".\"t\" ORDER BY id LIMIT 200 OFFSET 0;"
        )
    }

    /// 独立的列名不能被误当成关键字：`wherever` 不是 `where`。
    func testKeywordMustBeStandalone() {
        XCTAssertEqual(
            browse(RowBrowsingQuery.Filter(whereClause: "wherever = 1")),
            "SELECT * FROM \"public\".\"t\" WHERE wherever = 1 LIMIT 200 OFFSET 0;"
        )
    }

    func testSingleTrailingSemicolonIsAccepted() {
        XCTAssertEqual(
            browse(RowBrowsingQuery.Filter(whereClause: "id = 1;")),
            "SELECT * FROM \"public\".\"t\" WHERE id = 1 LIMIT 200 OFFSET 0;"
        )
    }

    /// **多语句必须拒绝**：一个"浏览"按钮不该执行 `; DROP TABLE`。
    func testMultipleStatementsAreRefused() {
        XCTAssertEqual(browseError(RowBrowsingQuery.Filter(whereClause: "id = 1; DROP TABLE t")), .multipleStatements)
        XCTAssertEqual(browseError(RowBrowsingQuery.Filter(whereClause: "id = 1; SELECT 2")), .multipleStatements)
        XCTAssertEqual(browseError(RowBrowsingQuery.Filter(orderBy: "id; DELETE FROM t")), .multipleStatements)
        XCTAssertNil(browse(RowBrowsingQuery.Filter(whereClause: "id = 1; DROP TABLE t")), "拒绝时不得给出语句")
    }

    /// 分号出现在字符串字面量里是数据，不是语句分隔 —— 但这里选择**一并拒绝**：
    /// 条件框里出现分号几乎总是放错了地方，宁可让人改写，也不猜。
    func testSemicolonInsideLiteralIsAlsoRefused() {
        XCTAssertEqual(browseError(RowBrowsingQuery.Filter(whereClause: "note = 'a;b'")), .multipleStatements)
    }

    // MARK: ORDER BY 放错框

    /// 把整段条件粘进 WHERE 框：只在他没另填 ORDER BY 时顺手拆开。
    func testOrderByInsideWhereBoxIsSplitOut() {
        let sql = browse(RowBrowsingQuery.Filter(whereClause: "id > 1 ORDER BY id DESC", limit: 10))
        XCTAssertEqual(sql, "SELECT * FROM \"public\".\"t\" WHERE id > 1 ORDER BY id DESC LIMIT 10 OFFSET 0;")
    }

    /// 两处都写了 ORDER BY：无法判断以哪个为准，明确拒绝（而不是生成两个 ORDER BY）。
    func testOrderByInBothBoxesIsRefused() {
        XCTAssertEqual(
            browseError(RowBrowsingQuery.Filter(whereClause: "id > 1 ORDER BY id", orderBy: "note")),
            .ambiguousOrderBy
        )
    }

    /// 字符串里的 `order by` 不该被当成子句。
    func testOrderByInsideQuotesIsNotSplit() {
        let sql = browse(RowBrowsingQuery.Filter(whereClause: "note = 'x order by y'"))
        XCTAssertEqual(sql, "SELECT * FROM \"public\".\"t\" WHERE note = 'x order by y' LIMIT 200 OFFSET 0;")
    }

    // MARK: 计数

    /// 计数不带 ORDER BY：对结果没有影响，带上只会让数据库白排序。
    func testCountDropsOrderBy() {
        guard case .success(let sql) = RowBrowsingQuery.count(
            table: "t",
            schema: "public",
            filter: RowBrowsingQuery.Filter(whereClause: "id > 1", orderBy: "id DESC"),
            dialect: postgres
        ) else { return XCTFail("应当生成成功") }
        XCTAssertEqual(sql, "SELECT count(*) FROM \"public\".\"t\" WHERE id > 1;")
        XCTAssertFalse(sql.contains("ORDER BY"), sql)
    }

    func testCountWithoutConditions() {
        guard case .success(let sql) = RowBrowsingQuery.count(
            table: "t", schema: nil, filter: RowBrowsingQuery.Filter(), dialect: postgres
        ) else { return XCTFail("应当生成成功") }
        XCTAssertEqual(sql, "SELECT count(*) FROM \"t\";")
    }

    func testCountAlsoRefusesMultipleStatements() {
        guard case .failure(let error) = RowBrowsingQuery.count(
            table: "t", schema: nil, filter: RowBrowsingQuery.Filter(whereClause: "1 = 1; DROP TABLE t"), dialect: postgres
        ) else { return XCTFail("应当拒绝") }
        XCTAssertEqual(error, .multipleStatements)
    }

    /// 错误标识要稳定：界面按它映射文案，改字符串等于改契约。
    func testErrorIdentifiersAreStable() {
        XCTAssertEqual(RowBrowsingQuery.BuildError.multipleStatements.identifier, "multipleStatements")
        XCTAssertEqual(RowBrowsingQuery.BuildError.ambiguousOrderBy.identifier, "ambiguousOrderBy")
    }
}
