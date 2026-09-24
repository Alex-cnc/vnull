import XCTest
@testable import DoyahCore

final class ResultExporterTests: XCTestCase {

    private func makeResult(
        columns: [String] = ["id", "name"],
        rows: [[String?]] = [["1", "Alice"], ["2", nil]]
    ) -> QueryResult {
        QueryResult(
            columns: columns.enumerated().map {
                ColumnMeta(id: $0.offset, name: $0.element, typeName: "TEXT")
            },
            rows: rows
        )
    }

    func testCSVHasBOMHeaderAndCRLFLines() {
        let text = ResultExporter.csv(for: makeResult())

        XCTAssertTrue(text.hasPrefix("\u{FEFF}"))
        XCTAssertEqual(
            text.dropFirst(),
            "id,name\r\n1,Alice\r\n2,\r\n"
        )
    }

    func testCSVCanOmitBOM() {
        let text = ResultExporter.csv(for: makeResult(rows: [["1", "a"]]), includeByteOrderMark: false)
        XCTAssertEqual(text, "id,name\r\n1,a\r\n")
    }

    func testCSVEscapesCommasQuotesAndNewlines() {
        XCTAssertEqual(ResultExporter.escapeCSVField("plain"), "plain")
        XCTAssertEqual(ResultExporter.escapeCSVField("a,b"), "\"a,b\"")
        XCTAssertEqual(ResultExporter.escapeCSVField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ResultExporter.escapeCSVField("line1\nline2"), "\"line1\nline2\"")

        let text = ResultExporter.csv(
            for: makeResult(columns: ["c"], rows: [["a,b"]])
        )
        XCTAssertTrue(text.hasSuffix("\"a,b\"\r\n"))
    }

    func testCSVOfResultWithoutColumnsIsEmpty() {
        let empty = QueryResult()
        XCTAssertEqual(ResultExporter.csv(for: empty), "\u{FEFF}")
        XCTAssertFalse(ResultExporter.hasExportableContent(empty))
    }

    func testJSONContainsColumnsAndRows() {
        let json = ResultExporter.json(for: makeResult())

        XCTAssertTrue(json.contains("\"column\": 2") == false)
        XCTAssertTrue(json.contains("\"rowCount\": 2"))
        XCTAssertTrue(json.contains("{ \"name\": \"id\", \"type\": \"TEXT\" }"))
        XCTAssertTrue(json.contains("{ \"id\": \"1\", \"name\": \"Alice\" }"))
        XCTAssertTrue(json.contains("{ \"id\": \"2\", \"name\": null }"))
    }

    func testJSONDisambiguatesDuplicateColumnNames() {
        let result = makeResult(columns: ["value", "value"], rows: [["a", "b"]])
        let json = ResultExporter.json(for: result)

        XCTAssertTrue(json.contains("\"value\": \"a\""))
        XCTAssertTrue(json.contains("\"value_2\": \"b\""))
    }

    func testJSONEscapesSpecialCharacters() {
        XCTAssertEqual(ResultExporter.quote("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(ResultExporter.quote("tab\there"), "\"tab\\there\"")
        XCTAssertEqual(ResultExporter.quote("换行\n结束"), "\"换行\\n结束\"")
        XCTAssertEqual(ResultExporter.quote("中文"), "\"中文\"")
    }

    func testJSONReportsAffectedRows() {
        let result = QueryResult(affectedRows: 7)
        let json = ResultExporter.json(for: result)

        XCTAssertTrue(json.contains("\"affectedRows\": 7"))
        XCTAssertTrue(ResultExporter.hasExportableContent(result))
    }

    func testTextDispatchesByFormat() {
        let result = makeResult(rows: [["1", "a"]])
        XCTAssertTrue(ResultExporter.text(for: result, format: .csv).contains("\u{FEFF}"))
        XCTAssertTrue(ResultExporter.text(for: result, format: .json).hasPrefix("{"))
    }

    // MARK: - FR-RES-11：TSV / Markdown / INSERT

    func testTSVSeparatesFieldsWithTabs() {
        let text = ResultExporter.tsv(for: makeResult())

        XCTAssertEqual(text, "id\tname\n1\tAlice\n2\t\n")
        XCTAssertFalse(text.hasPrefix("\u{FEFF}"), "TSV 不带 BOM")
    }

    func testTSVReplacesEmbeddedTabsAndNewlines() {
        let text = ResultExporter.tsv(for: makeResult(columns: ["c"], rows: [["a\tb\nc"]]))
        XCTAssertEqual(text, "c\na b c\n")
    }

    func testMarkdownTableShape() {
        let text = ResultExporter.markdown(for: makeResult())

        XCTAssertEqual(
            text,
            "| id | name |\n| --- | --- |\n| 1 | Alice |\n| 2 | NULL |\n"
        )
    }

    func testMarkdownEscapesPipesAndNewlines() {
        let text = ResultExporter.markdown(for: makeResult(columns: ["c"], rows: [["a|b\nc"]]))
        XCTAssertTrue(text.contains("| a\\|b<br>c |"))
    }

    func testMarkdownOfResultWithoutColumnsIsEmpty() {
        XCTAssertEqual(ResultExporter.markdown(for: QueryResult()), "")
    }

    private func typedResult() -> QueryResult {
        let columns = [
            ColumnMeta(id: 0, name: "id", typeName: "integer"),
            ColumnMeta(id: 1, name: "name", typeName: "text"),
            ColumnMeta(id: 2, name: "ratio", typeName: "numeric"),
            ColumnMeta(id: 3, name: "active", typeName: "boolean")
        ]
        let rows: [[String?]] = [
            ["1", "O'Brien", "3.50", "t"],
            ["2", nil, nil, "f"]
        ]
        return QueryResult(columns: columns, rows: rows)
    }

    func testInsertStatementsQuoteTextAndKeepNumbersRaw() {
        let text = ResultExporter.insertStatements(for: typedResult(), tableName: "users")

        XCTAssertEqual(
            text,
            """
            INSERT INTO "users" ("id", "name", "ratio", "active") VALUES (1, 'O''Brien', 3.50, TRUE);
            INSERT INTO "users" ("id", "name", "ratio", "active") VALUES (2, NULL, NULL, FALSE);

            """
        )
    }

    func testInsertStatementsUseDialectIdentifierQuoting() {
        let text = ResultExporter.insertStatements(
            for: typedResult(),
            tableName: "users",
            dialect: GBaseDialect()
        )
        XCTAssertTrue(text.hasPrefix("INSERT INTO `users` (`id`, `name`, `ratio`, `active`) VALUES"))
    }

    func testInsertStatementsFallBackToQuotedTextForUnparseableNumbers() {
        let columns = [ColumnMeta(id: 0, name: "n", typeName: "integer")]
        let result = QueryResult(columns: columns, rows: [["abc"]])
        let text = ResultExporter.insertStatements(for: result, tableName: "t")

        XCTAssertTrue(text.contains("('abc')"), "解析不出数字时应退回字符串写法，而不是产生非法 SQL")
    }

    func testInsertStatementsEmptyWithoutRows() {
        let result = QueryResult(columns: [ColumnMeta(id: 0, name: "n", typeName: "text")], rows: [])
        XCTAssertEqual(ResultExporter.insertStatements(for: result, tableName: "t"), "")
    }

    func testTextDispatchesExtendedFormats() {
        let result = makeResult(rows: [["1", "a"]])

        XCTAssertTrue(ResultExporter.text(for: result, format: .tsv).hasPrefix("id\tname"))
        XCTAssertTrue(ResultExporter.text(for: result, format: .markdown).hasPrefix("| id |"))
        XCTAssertTrue(
            ResultExporter.text(for: result, format: .sqlInsert, tableName: "t")
                .hasPrefix("INSERT INTO \"t\"")
        )
    }

    func testExportFormatMetadata() {
        XCTAssertEqual(ResultExportFormat.markdown.fileExtension, "md")
        XCTAssertEqual(ResultExportFormat.tsv.fileExtension, "tsv")
        XCTAssertEqual(ResultExportFormat.sqlInsert.fileExtension, "sql")
        XCTAssertEqual(ResultExportFormat.xlsx.fileExtension, "xlsx")
        XCTAssertTrue(ResultExportFormat.sqlInsert.requiresTableName)
        XCTAssertFalse(ResultExportFormat.csv.requiresTableName)
        XCTAssertFalse(ResultExportFormat.xlsx.requiresTableName)

        // 不写死"一共几个"（加了格式就要改一次的断言没什么信息量），
        // 改成钉住**真正要守的性质**：扩展名互不重复、二进制格式只有 xlsx。
        XCTAssertEqual(Set(ResultExportFormat.allCases.map(\.fileExtension)).count, ResultExportFormat.allCases.count)
        XCTAssertEqual(ResultExportFormat.allCases.filter(\.isBinary), [.xlsx])
    }
}
