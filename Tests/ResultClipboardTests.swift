import XCTest
@testable import DoyahCore

/// 复制为多格式（FR-RES-12）：范围是**选中的行**，渲染复用导出层。
///
/// 重点在"贴进去不能错位"：TSV 里的制表符 / 换行、Markdown 里的 `|`、
/// 以及各格式对**空值**的不同表达（这是有意差异，必须钉住）。
final class ResultClipboardTests: XCTestCase {

    private let columns = [
        ColumnMeta(id: 0, name: "id", typeName: "integer"),
        ColumnMeta(id: 1, name: "note", typeName: "text"),
        ColumnMeta(id: 2, name: "amount", typeName: "numeric"),
    ]

    private let rows: [[String?]] = [
        ["1", "alpha", "10.5"],
        ["2", "be|ta", "20"],
        ["3", "line\twith\ttabs\nand newline", nil],
    ]

    private func text(_ format: ResultClipboard.Format, rows: [[String?]]? = nil) -> String {
        ResultClipboard.text(rows: rows ?? self.rows, columns: columns, format: format, tableName: "t")
    }

    // MARK: 基本形状

    func testTSVHasHeaderAndTabsAsDelimiters() {
        let output = text(.tsv)
        XCTAssertTrue(output.hasPrefix("id\tnote\tamount\n"), output)
        XCTAssertTrue(output.contains("1\talpha\t10.5\n"))
    }

    func testMarkdownIsATableWithSeparator() {
        let lines = text(.markdown).split(separator: "\n")
        XCTAssertEqual(lines.first.map(String.init), "| id | note | amount |")
        XCTAssertEqual(lines.dropFirst().first.map(String.init), "| --- | --- | --- |")
    }

    func testInsertUsesDialectQuoting() {
        let output = text(.insert)
        XCTAssertTrue(output.contains("INSERT INTO \"t\""), output)
        XCTAssertTrue(output.contains("(\"id\", \"note\", \"amount\")"), output)
        XCTAssertTrue(output.contains("VALUES"), output)
    }

    func testCSVHasHeader() {
        XCTAssertTrue(text(.csv).hasPrefix("id,note,amount"), text(.csv))
    }

    // MARK: 范围

    /// **只渲染传进来的那些行**（用户只选了三行，不该把整表复制走）。
    func testOnlyGivenRowsAreRendered() {
        let subset = Array(rows.prefix(1))
        let output = text(.tsv, rows: subset)
        XCTAssertTrue(output.contains("alpha"))
        XCTAssertFalse(output.contains("be|ta"))
        XCTAssertEqual(output.split(separator: "\n").count, 2, "表头 + 1 行")
    }

    func testEmptySelectionProducesNothing() {
        XCTAssertEqual(ResultClipboard.text(rows: [], columns: columns, format: .tsv), "")
        XCTAssertEqual(ResultClipboard.text(rows: rows, columns: [], format: .tsv), "")
    }

    // MARK: 不能错位

    /// TSV 里的制表符与换行必须被替换 —— 否则一行会被拆成两行、列也会错位。
    func testTSVSsanitizesTabsAndNewlines() {
        let output = text(.tsv)
        let thirdLine = output.split(separator: "\n").first { $0.hasPrefix("3\t") }
        XCTAssertNotNil(thirdLine, "第三行应当存在且以 `3` 开头")
        XCTAssertTrue(thirdLine!.contains("line with tabs and newline"), "制表符与换行都被替换成空格：\(thirdLine!)")
        // 整个输出只有 4 行（表头 + 3 行数据）—— 值里的换行没有把行数撑破
        XCTAssertEqual(output.split(separator: "\n").count, 4)
    }

    /// Markdown 里的 `|` 必须转义，否则表格会多出一列。
    func testMarkdownEscapesPipesAndNewlines() {
        let output = text(.markdown)
        XCTAssertTrue(output.contains("be\\|ta"), "竖线要转义：\(output)")
        XCTAssertTrue(output.contains("<br>"), "换行写成 <br>：\(output)")
    }

    /// CSV 的引号规则：含逗号 / 引号 / 换行的值要被引号包裹。
    func testCSVQuotesWhenNeeded() {
        let rows: [[String?]] = [["1", "a,b", "x\"y"]]
        let output = ResultClipboard.text(rows: rows, columns: columns, format: .csv)
        XCTAssertTrue(output.contains("\"a,b\""), output)
        XCTAssertTrue(output.contains("\"x\"\"y\""), output)
    }

    // MARK: 空值的有意差异

    /// 各格式对空值的表达**不同且是有意的**：贴进表格要空着，贴进文档 / SQL 要写 `NULL`。
    func testNullRenderingDiffersByFormat() {
        let rows: [[String?]] = [["3", "x", nil]]
        XCTAssertFalse(ResultClipboard.text(rows: rows, columns: columns, format: .tsv).contains("NULL"))
        XCTAssertTrue(ResultClipboard.text(rows: rows, columns: columns, format: .markdown).contains("NULL"))
        XCTAssertTrue(ResultClipboard.text(rows: rows, columns: columns, format: .insert).contains("NULL"))
        // 文档化的口径要与实现一致
        XCTAssertEqual(ResultClipboard.nullRendering(for: .tsv), "")
        XCTAssertEqual(ResultClipboard.nullRendering(for: .markdown), "NULL")
        XCTAssertEqual(ResultClipboard.nullRendering(for: .insert), "NULL")
    }

    /// 数值列在 INSERT 里不加引号（加引号会让 `numeric` 比较走文本路径）。
    func testInsertKeepsNumbersUnquoted() {
        let output = ResultClipboard.text(rows: [["1", "a", "10.5"]], columns: columns, format: .insert)
        XCTAssertTrue(output.contains("10.5"), output)
        XCTAssertFalse(output.contains("'10.5'"), "数字不该被引号包裹：\(output)")
    }

    /// 默认格式是 TSV（贴表格 / 工单都直接成列），且四种格式都在。
    func testDefaultFormatAndCoverage() {
        XCTAssertEqual(ResultClipboard.defaultFormat, .tsv)
        XCTAssertEqual(
            ResultClipboard.Format.allCases.map(\.rawValue).sorted(),
            ["csv", "insert", "markdown", "tsv"]
        )
    }

    /// 含单引号的值在 INSERT 里必须转义（与查询参数同一纪律：值只能是数据）。
    func testInsertEscapesQuotes() {
        let output = ResultClipboard.text(rows: [["1", "O'Brien", "1"]], columns: columns, format: .insert)
        XCTAssertTrue(output.contains("'O''Brien'"), output)
        let dropIndex = output.range(of: "O''Brien")!.lowerBound
        XCTAssertFalse(SQLLexer.isCode(at: dropIndex, in: output), "值必须落在字面量里")
    }
}
