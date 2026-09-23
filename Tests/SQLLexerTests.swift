import XCTest
@testable import DoyahCore

/// 词法切分（`SQLLexer`）：任何"在 SQL 文本里找东西"的功能都依赖它。
///
/// 这一层写错的后果不是报错，而是**悄悄改掉用户的数据**（把字符串里的 `:name` 当参数替换掉），
/// 所以边界一条条钉住。
final class SQLLexerTests: XCTestCase {

    private func code(_ sql: String) -> [String] {
        SQLLexer.codeRanges(in: sql).map { String(sql[$0]) }
    }

    func testPlainStatementIsAllCode() {
        XCTAssertEqual(code("SELECT 1 FROM t"), ["SELECT 1 FROM t"])
    }

    /// 字符串是数据，不是代码。
    func testSingleQuotedStringIsNotCode() {
        let sql = "SELECT 'a :name b' AS x FROM t"
        let ranges = SQLLexer.codeRanges(in: sql)
        XCTAssertEqual(ranges.count, 2, "应当被字符串切成两段代码")
        // 字符串内部的位置不在代码区
        let inside = sql.range(of: ":name")!.lowerBound
        XCTAssertFalse(SQLLexer.isCode(at: inside, in: sql))
    }

    /// `''` 是转义，字符串不该在第一个引号处就被判结束。
    func testDoubledQuoteEscapes() {
        let sql = "SELECT 'it''s :name here' FROM t"
        let inside = sql.range(of: ":name")!.lowerBound
        XCTAssertFalse(SQLLexer.isCode(at: inside, in: sql), "双写引号后仍在字符串里")
        XCTAssertTrue(SQLLexer.isCode(at: sql.range(of: "FROM")!.lowerBound, in: sql))
    }

    /// `E'…\''` 的反斜杠转义。
    func testBackslashEscapeInsideString() {
        let sql = #"SELECT E'a\':name b' FROM t"#
        XCTAssertEqual(code(sql).count, 2, "反斜杠转义后字符串应继续到真正的结尾")
    }

    /// 双引号标识符里的内容也算非代码（`"col:name"` 是列名的一部分）。
    func testQuotedIdentifierIsNotCode() {
        let sql = "SELECT \"col:name\" FROM t"
        let inside = sql.range(of: ":name")!.lowerBound
        XCTAssertFalse(SQLLexer.isCode(at: inside, in: sql))
    }

    func testLineCommentIsNotCode() {
        let sql = "SELECT 1 -- 这里 :name 是注释\nFROM t"
        let inside = sql.range(of: ":name")!.lowerBound
        XCTAssertFalse(SQLLexer.isCode(at: inside, in: sql))
        XCTAssertTrue(SQLLexer.isCode(at: sql.range(of: "FROM")!.lowerBound, in: sql))
    }

    func testBlockCommentIncludingNestedIsNotCode() {
        let sql = "SELECT /* 外层 /* 内层 :name */ 还是注释 */ 1 FROM t"
        let inside = sql.range(of: ":name")!.lowerBound
        XCTAssertFalse(SQLLexer.isCode(at: inside, in: sql))
        XCTAssertTrue(SQLLexer.isCode(at: sql.range(of: "FROM")!.lowerBound, in: sql))
    }

    func testDollarQuotedBodyIsNotCode() {
        let tagged = "SELECT f($tag$ :name $tag$) FROM t"
        let inside = tagged.range(of: ":name")!.lowerBound
        XCTAssertFalse(SQLLexer.isCode(at: inside, in: tagged))

        let plain = "SELECT f($$ :name $$) FROM t"
        let insidePlain = plain.range(of: ":name")!.lowerBound
        XCTAssertFalse(SQLLexer.isCode(at: insidePlain, in: plain))
    }

    /// `$1` 这种位置参数**不是** dollar-quote —— 别把它吞掉（这是最容易写错的一条）。
    func testPositionalParameterIsNotDollarQuote() {
        let sql = "SELECT * FROM t WHERE id = $1"
        XCTAssertEqual(code(sql), ["SELECT * FROM t WHERE id = $1"])
    }

    func testUnterminatedStringRunsToEnd() {
        let sql = "SELECT 'oops FROM t"
        XCTAssertEqual(code(sql), ["SELECT "], "未闭合字符串之后没有代码区")
    }

    func testRealisticStatementHasExpectedCodeSegments() {
        let sql = """
        -- 查最近订单
        SELECT * FROM orders
        WHERE note = 'a -- b'   /* 注释里的 FROM */
          AND id = :id
        """
        let segments = code(sql)
        XCTAssertFalse(segments.contains { $0.contains(":name") })
        // `:id` 必须落在代码区里，否则参数功能就失效了
        let idIndex = sql.range(of: ":id")!.lowerBound
        XCTAssertTrue(SQLLexer.isCode(at: idIndex, in: sql))
    }
}
