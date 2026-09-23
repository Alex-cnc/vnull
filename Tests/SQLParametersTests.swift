import XCTest
@testable import DoyahCore

/// 查询参数（FR-EXEC-17）：提取、类型化转义、缺值报错。
///
/// 最要紧的两条：**字符串里的 `:name` 不是参数**、**恶意输入只能变成数据**。
final class SQLParametersTests: XCTestCase {

    // MARK: 提取

    func testExtractNamedAndPositional() {
        let sql = "SELECT * FROM t WHERE a = :alpha AND b = $2 AND c = :beta AND d = $1"
        let parameters = SQLParameters.extract(from: sql)
        XCTAssertEqual(parameters.map(\.identifier), ["alpha", "beta", "$1", "$2"])
        XCTAssertTrue(parameters[0].isPositional == false)
        XCTAssertTrue(parameters[2].isPositional)
    }

    func testDuplicatePlaceholdersAreMerged() {
        let sql = "SELECT * FROM t WHERE a = :x OR b = :x OR c = :x"
        XCTAssertEqual(SQLParameters.extract(from: sql).map(\.identifier), ["x"])
    }

    /// **字符串里的 `:name` 不是参数** —— 这条错了就会悄悄改掉用户的数据。
    func testPlaceholderInsideStringIsIgnored() {
        let sql = "SELECT 'a :name b' AS note FROM t WHERE id = :id"
        XCTAssertEqual(SQLParameters.extract(from: sql).map(\.identifier), ["id"])

        // 只有字符串里的"占位符"：整条语句不应被当成需要填值。
        XCTAssertFalse(SQLParameters.hasParameters("SELECT ':not_a_param' AS x"))
    }

    func testPlaceholderInsideCommentsAndDollarQuotesIsIgnored() {
        XCTAssertFalse(SQLParameters.hasParameters("SELECT 1 -- :commented"))
        XCTAssertFalse(SQLParameters.hasParameters("SELECT /* :blocked */ 1"))
        XCTAssertFalse(SQLParameters.hasParameters("SELECT f($$ :in_dollar $$)"))
        XCTAssertFalse(SQLParameters.hasParameters("SELECT \"col:name\" FROM t"))
    }

    /// `::` 是类型转换，不是参数（`x::text` 里没有参数 `:text`）。
    func testCastOperatorIsNotAParameter() {
        XCTAssertFalse(SQLParameters.hasParameters("SELECT id::text FROM t"))
        XCTAssertEqual(SQLParameters.extract(from: "SELECT id::text, :real FROM t").map(\.identifier), ["real"])
    }

    // MARK: 绑定：文本

    func testTextBindingQuotesAndEscapes() throws {
        let bound = try SQLParameters.bind(sql: "SELECT * FROM t WHERE name = :name", textValues: ["name": "O'Brien"])
            .get()
        XCTAssertEqual(bound.sql, "SELECT * FROM t WHERE name = 'O''Brien'")
    }

    /// **核心断言**：恶意输入只能变成数据，不能变成语法。
    func testMaliciousTextBecomesDataOnly() throws {
        let attack = "x'; DROP TABLE users; --"
        let bound = try SQLParameters.bind(sql: "SELECT * FROM t WHERE name = :name", textValues: ["name": attack]).get()

        XCTAssertEqual(bound.sql, "SELECT * FROM t WHERE name = 'x''; DROP TABLE users; --'")
        // 单引号被双写后，整条语句里的引号数量应当是偶数（没有悬空引号 = 没有逃逸）
        XCTAssertEqual(bound.sql.filter { $0 == "'" }.count % 2, 0)
        // 不能只搜 "'; DROP" 就算数：它**可以**作为字符串内容出现（`'x''; DROP…'`）。
        // 真正要证的是"它落在字面量里面"，所以用词法器判定 —— 这也正是执行时的行为。
        let dropIndex = try XCTUnwrap(bound.sql.range(of: "DROP TABLE")).lowerBound
        XCTAssertFalse(SQLLexer.isCode(at: dropIndex, in: bound.sql), "DROP 必须落在字符串字面量里")

        // 更强的证据在脚本里：真机上把同样的值插进去，然后确认表还在（`Scripts/test-query-parameters.sh`）。
    }

    func testEmptyTextIsAllowed() throws {
        let bound = try SQLParameters.bind(sql: "WHERE a = :a", textValues: ["a": ""]).get()
        XCTAssertEqual(bound.sql, "WHERE a = ''")
    }

    // MARK: 绑定：数字 / 布尔 / NULL

    func testNumberIsWrittenWithoutQuotes() throws {
        let values: [String: (type: SQLParameters.ValueType, raw: String)] = ["n": (.number, "42")]
        let bound = try SQLParameters.bind(sql: "WHERE n = :n", values: values).get()
        XCTAssertEqual(bound.sql, "WHERE n = 42", "数字不加引号，否则索引会失效")
    }

    func testInvalidNumberIsRejected() {
        let values: [String: (type: SQLParameters.ValueType, raw: String)] = ["n": (.number, "42; DROP TABLE t")]
        guard case .failure(.invalidNumber(let name, let value)) = SQLParameters.bind(sql: "WHERE n = :n", values: values) else {
            return XCTFail("非法数字应当被拒绝")
        }
        XCTAssertEqual(name, "n")
        XCTAssertTrue(value.contains("DROP"))
    }

    func testBooleanAndNullRendering() throws {
        let booleans: [String: (type: SQLParameters.ValueType, raw: String)] = ["b": (.boolean, "yes")]
        XCTAssertEqual(try SQLParameters.bind(sql: "WHERE b = :b", values: booleans).get().sql, "WHERE b = TRUE")

        let falsy: [String: (type: SQLParameters.ValueType, raw: String)] = ["b": (.boolean, "0")]
        XCTAssertEqual(try SQLParameters.bind(sql: "WHERE b = :b", values: falsy).get().sql, "WHERE b = FALSE")

        let nulls: [String: (type: SQLParameters.ValueType, raw: String)] = ["v": (.null, "忽略")]
        XCTAssertEqual(try SQLParameters.bind(sql: "WHERE v IS NOT DISTINCT FROM :v", values: nulls).get().sql,
                       "WHERE v IS NOT DISTINCT FROM NULL")

        let badBoolean: [String: (type: SQLParameters.ValueType, raw: String)] = ["b": (.boolean, "也许")]
        guard case .failure(.invalidBoolean) = SQLParameters.bind(sql: "WHERE b = :b", values: badBoolean) else {
            return XCTFail("非法布尔应当被拒绝")
        }
    }

    // MARK: 缺值 / 多余

    func testMissingValuesAreReportedTogether() {
        guard case .failure(.missingValues(let names)) = SQLParameters.bind(sql: "WHERE a = :a AND b = :b", textValues: [:]) else {
            return XCTFail("缺值应当报错")
        }
        XCTAssertEqual(names, ["a", "b"], "一次把缺的都说出来，别填一个报一个")
    }

    func testUnusedValuesAreReportedNotRejected() throws {
        let bound = try SQLParameters.bind(sql: "WHERE a = :a", textValues: ["a": "1", "typo": "2"]).get()
        XCTAssertEqual(bound.unusedNames, ["typo"])
        XCTAssertEqual(bound.sql, "WHERE a = '1'")
    }

    func testNoParametersMeansNoChange() throws {
        let bound = try SQLParameters.bind(sql: "SELECT 1", textValues: [:]).get()
        XCTAssertEqual(bound.sql, "SELECT 1")
    }

    /// 同一个占位符出现多次要全部替换。
    func testAllOccurrencesAreReplaced() throws {
        let bound = try SQLParameters.bind(sql: "WHERE a = :x OR b = :x", textValues: ["x": "v"]).get()
        XCTAssertEqual(bound.sql, "WHERE a = 'v' OR b = 'v'")
    }

    /// 字符串里的"假占位符"必须原样保留，只替换代码区的真占位符。
    func testStringContentSurvivesBinding() throws {
        let sql = "SELECT ':x' AS literal FROM t WHERE id = :x"
        let bound = try SQLParameters.bind(sql: sql, textValues: ["x": "real"]).get()
        XCTAssertEqual(bound.sql, "SELECT ':x' AS literal FROM t WHERE id = 'real'")
    }

    // MARK: 类型清单

    /// **故意没有 raw / 原样插入类型** —— 那是把注入入口重新打开。
    func testNoRawValueTypeExists() {
        XCTAssertEqual(SQLParameters.ValueType.allCases.map(\.rawValue).sorted(), ["boolean", "null", "number", "text"])
        XCTAssertFalse(SQLParameters.ValueType.allCases.contains { $0.rawValue == "raw" })
    }
}
