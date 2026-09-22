import XCTest
@testable import DoyahCore

/// FR-EXEC-14：运行范围控制（整篇 / 光标所在语句 / 选中片段）。
final class ExecutionScopeTests: XCTestCase {

    private let sql = """
    -- 两条独立语句
    SELECT 1;
    SELECT * FROM orders WHERE id = 2;
    UPDATE orders SET total = 0 WHERE id = 3;
    """

    // MARK: - 整篇

    func testAllRunsWholeText() {
        let resolution = ExecutionScope.resolve(text: sql, mode: .all)

        XCTAssertEqual(resolution.mode, .all)
        XCTAssertEqual(resolution.sql, sql)
        XCTAssertNil(resolution.issue)
    }

    func testAllOnEmptyTextReportsIssue() {
        let resolution = ExecutionScope.resolve(text: "   \n  ", mode: .all)

        XCTAssertEqual(resolution.issue, .emptyText)
        XCTAssertTrue(resolution.sql.isEmpty)
    }

    // MARK: - 选中片段

    func testSelectionRunsOnlySelectedFragment() {
        let ns = sql as NSString
        let target = "UPDATE orders SET total = 0 WHERE id = 3;"
        let range = ns.range(of: target)

        let resolution = ExecutionScope.resolve(text: sql, mode: .selection, selection: range)

        XCTAssertEqual(resolution.mode, .selection)
        XCTAssertEqual(resolution.sql, target)
        XCTAssertNil(resolution.issue)
    }

    func testSelectionTrimsSurroundingWhitespace() {
        let ns = sql as NSString
        let range = ns.range(of: "SELECT 1;")

        let resolution = ExecutionScope.resolve(text: sql, mode: .selection, selection: range)

        XCTAssertEqual(resolution.sql, "SELECT 1;")
    }

    /// 选了「选中片段」但没有选中内容：**不静默改成跑整篇**（那会把小操作放大）。
    func testEmptySelectionReportsIssueInsteadOfRunningEverything() {
        for selection in [nil, NSRange(location: 5, length: 0)] {
            let resolution = ExecutionScope.resolve(text: sql, mode: .selection, selection: selection)
            XCTAssertEqual(resolution.issue, .emptySelection)
            XCTAssertTrue(resolution.sql.isEmpty)
        }
    }

    func testSelectionOutOfBoundsIsTreatedAsEmpty() {
        let resolution = ExecutionScope.resolve(
            text: sql,
            mode: .selection,
            selection: NSRange(location: 10_000, length: 5)
        )
        XCTAssertEqual(resolution.issue, .emptySelection)
    }

    /// 选区越过文末时按实际长度夹取，不越界崩溃。
    func testSelectionIsClampedToTextLength() {
        let text = "SELECT 1;"
        let resolution = ExecutionScope.resolve(
            text: text,
            mode: .selection,
            selection: NSRange(location: 0, length: 9_999)
        )
        XCTAssertEqual(resolution.sql, text)
    }

    func testWhitespaceOnlySelectionReportsIssue() {
        let text = "SELECT 1;      SELECT 2;"
        let resolution = ExecutionScope.resolve(
            text: text,
            mode: .selection,
            selection: NSRange(location: 9, length: 6)
        )
        XCTAssertEqual(resolution.issue, .emptySelection)
    }

    // MARK: - 光标所在语句

    func testCurrentStatementPicksStatementUnderCursor() {
        let ns = sql as NSString
        // 光标落在第 3 条语句内部
        let location = ns.range(of: "SET total").location

        let resolution = ExecutionScope.resolve(
            text: sql,
            mode: .currentStatement,
            selection: NSRange(location: location, length: 0)
        )

        XCTAssertEqual(resolution.mode, .currentStatement)
        XCTAssertEqual(resolution.statementNumber, 3)
        // 拆分器不含末尾分号，`resolve` 只做 trim。
        XCTAssertEqual(resolution.sql, "UPDATE orders SET total = 0 WHERE id = 3")
    }

    func testCurrentStatementForSecondStatement() {
        let ns = sql as NSString
        let location = ns.range(of: "FROM orders").location

        let resolution = ExecutionScope.resolve(
            text: sql,
            mode: .currentStatement,
            selection: NSRange(location: location, length: 0)
        )

        XCTAssertEqual(resolution.statementNumber, 2)
        XCTAssertEqual(resolution.sql, "SELECT * FROM orders WHERE id = 2")
    }

    /// 光标在行首注释里时归给紧随其后的那条语句（脚本开头写注释是常态）。
    func testCursorInsideLeadingCommentBelongsToFollowingStatement() {
        let text = "-- 说明\nSELECT 1;\nSELECT 2;"
        let resolution = ExecutionScope.resolve(
            text: text,
            mode: .currentStatement,
            selection: NSRange(location: 2, length: 0)
        )

        XCTAssertEqual(resolution.statementNumber, 1)
    }

    /// 光标在两条语句之间的空白处：归给后面那条。
    func testCursorInGapBelongsToFollowingStatement() {
        let text = "SELECT 1;\n\n   \nSELECT 2;"
        let ns = text as NSString
        let location = ns.range(of: "SELECT 2").location - 2

        let hit = ExecutionScope.statement(containing: location, in: text)

        XCTAssertEqual(hit?.index, 1)
    }

    /// 光标在文末空白处：归给最后一条（用户刚敲完最后一句就按执行）。
    func testCursorAfterLastStatementBelongsToLastOne() {
        let text = "SELECT 1;\nSELECT 2;\n\n"
        let hit = ExecutionScope.statement(containing: (text as NSString).length - 1, in: text)

        XCTAssertEqual(hit?.index, 1)
        let raw = hit.map { (text as NSString).substring(with: $0.range) } ?? ""
        XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), "SELECT 2")
    }

    func testCurrentStatementOnEmptyTextReportsIssue() {
        let resolution = ExecutionScope.resolve(
            text: "",
            mode: .currentStatement,
            selection: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(resolution.issue, .noStatementAtCursor)
        XCTAssertTrue(resolution.sql.isEmpty)
    }

    /// 语句里含分号字符串时，边界仍按拆分器（不在这里重复实现规则）。
    func testSemicolonInsideStringDoesNotSplitStatement() {
        let text = "SELECT 'a;b';\nSELECT 2;"
        let ns = text as NSString
        let location = ns.range(of: "SELECT 2").location

        let hit = ExecutionScope.statement(containing: location, in: text)

        let raw = hit.map { ns.substring(with: $0.range) } ?? ""
        XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), "SELECT 2")
        XCTAssertEqual(hit?.index, 1)
    }

    /// 重复语句也必须定位到正确那一条（顺序查找而非全局查找）。
    func testRepeatedIdenticalStatementsLocateTheRightOne() {
        let text = "SELECT 1;\nSELECT 1;\nSELECT 1;"
        let ns = text as NSString
        // 第三条的开头
        let location = ns.range(of: "SELECT 1", options: [], range: NSRange(location: 20, length: 9)).location

        let hit = ExecutionScope.statement(containing: location, in: text)

        XCTAssertEqual(hit?.index, 2)
    }

    // MARK: - GBase 方言

    func testWorksWithGBaseDelimiterDirective() {
        let text = """
        DELIMITER $
        CREATE PROCEDURE p()
        BEGIN
          SELECT 1;
        END$
        DELIMITER ;
        SELECT 9;
        """

        let resolution = ExecutionScope.resolve(
            text: text,
            mode: .currentStatement,
            selection: NSRange(location: (text as NSString).range(of: "SELECT 9").location, length: 0),
            databaseType: .gbase8a
        )

        XCTAssertEqual(resolution.sql, "SELECT 9")
        XCTAssertNil(resolution.issue)
    }

    // MARK: - 与高危保护衔接

    /// 运行范围解析出来的 SQL 直接喂给 Safe Mode，只对真正要跑的那段判定。
    func testResolvedSQLFeedsSafetyCheck() {
        let text = "SELECT 1;\nDELETE FROM orders;"
        let ns = text as NSString

        let safe = ExecutionScope.resolve(
            text: text,
            mode: .currentStatement,
            selection: NSRange(location: 0, length: 0)
        )
        XCTAssertTrue(
            ExecutionSafety.check(sql: safe.sql, databaseType: .postgresql, policy: .default).isAllowed
        )

        let dangerous = ExecutionScope.resolve(
            text: text,
            mode: .currentStatement,
            selection: NSRange(location: ns.range(of: "DELETE").location, length: 0)
        )
        XCTAssertFalse(
            ExecutionSafety.check(sql: dangerous.sql, databaseType: .postgresql, policy: .default).isAllowed
        )
    }
}
