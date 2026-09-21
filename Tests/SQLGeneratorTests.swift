import XCTest
@testable import PostgresClientCore

/// FR-DATA-01 ~ FR-DATA-03、FR-DDL-01 ~ FR-DDL-02、FR-DIAG-01：SQL 生成器。
final class SQLGeneratorTests: XCTestCase {

    private let pg = PostgresDialect()
    private let gbase = GBaseDialect()

    // MARK: - 表数据浏览

    func testSelectRowsForPostgres() {
        let sql = SQLGenerator.selectRows(table: "users", schema: "public", dialect: pg)
        XCTAssertEqual(sql, "SELECT * FROM \"public\".\"users\" LIMIT 200 OFFSET 0;")
    }

    func testSelectRowsWithoutSchema() {
        let sql = SQLGenerator.selectRows(table: "users", dialect: pg)
        XCTAssertEqual(sql, "SELECT * FROM \"users\" LIMIT 200 OFFSET 0;")
    }

    func testSelectRowsUsesDialectLimitSyntax() {
        // GBase 无 schema 层，schema 参数被忽略，分页语法是 LIMIT offset, count。
        let sql = SQLGenerator.selectRows(
            table: "users",
            schema: "public",
            limit: 50,
            offset: 100,
            dialect: gbase
        )
        XCTAssertEqual(sql, "SELECT * FROM `users` LIMIT 100, 50;")
    }

    func testSelectRowsClampsNegativeNumbers() {
        let sql = SQLGenerator.selectRows(table: "t", limit: -5, offset: -1, dialect: pg)
        XCTAssertEqual(sql, "SELECT * FROM \"t\" LIMIT 0 OFFSET 0;")
    }

    func testCountRows() {
        XCTAssertEqual(
            SQLGenerator.countRows(table: "users", schema: "public", dialect: pg),
            "SELECT count(*) FROM \"public\".\"users\";"
        )
    }

    // MARK: - 模板生成

    func testInsertTemplate() {
        let sql = SQLGenerator.insertTemplate(table: "users", columns: ["id", "name"], dialect: pg)
        XCTAssertEqual(sql, "INSERT INTO \"users\" (\"id\", \"name\") VALUES (?, ?);")
    }

    func testInsertTemplateWithoutColumnsFallsBackToDefaultValues() {
        let sql = SQLGenerator.insertTemplate(table: "users", columns: [], dialect: pg)
        XCTAssertEqual(sql, "INSERT INTO \"users\" DEFAULT VALUES;")
    }

    func testSelectTemplateListsQuotedColumns() {
        let sql = SQLGenerator.selectTemplate(table: "users", columns: ["id", "name"], dialect: gbase)
        XCTAssertEqual(sql, "SELECT `id`, `name` FROM `users`;")
    }

    func testSelectTemplateWithoutColumnsUsesStar() {
        XCTAssertEqual(SQLGenerator.selectTemplate(table: "users", columns: [], dialect: pg),
                       "SELECT * FROM \"users\";")
    }

    // MARK: - DDL

    func testCreateTableRespectsNullability() {
        let columns = [
            ColumnMeta(id: 0, name: "id", typeName: "integer", isNullable: false),
            ColumnMeta(id: 1, name: "name", typeName: "text", isNullable: true)
        ]
        let sql = SQLGenerator.createTable(table: "users", columns: columns, schema: "public", dialect: pg)

        XCTAssertEqual(
            sql,
            "CREATE TABLE \"public\".\"users\" (\n    \"id\" integer NOT NULL,\n    \"name\" text\n);"
        )
    }

    func testCreateTableWithoutColumns() {
        XCTAssertEqual(SQLGenerator.createTable(table: "t", columns: [], dialect: pg),
                       "CREATE TABLE \"t\" ();")
    }

    func testDropTableHasIfExistsByDefault() {
        XCTAssertEqual(SQLGenerator.dropTable(table: "users", dialect: pg),
                       "DROP TABLE IF EXISTS \"users\";")
        XCTAssertEqual(SQLGenerator.dropTable(table: "users", schema: "public", ifExists: false, dialect: pg),
                       "DROP TABLE \"public\".\"users\";")
    }

    func testTruncateTable() {
        XCTAssertEqual(SQLGenerator.truncateTable(table: "users", schema: "public", dialect: pg),
                       "TRUNCATE TABLE \"public\".\"users\";")
    }

    // MARK: - 执行计划语句

    func testExplainWithoutOptions() {
        XCTAssertEqual(SQLGenerator.explain(sql: "SELECT 1;", dialect: pg), "EXPLAIN SELECT 1;")
    }

    func testExplainWithAnalyzeAndJSON() {
        let sql = SQLGenerator.explain(sql: "SELECT * FROM t", analyze: true, formatJSON: true, dialect: pg)
        XCTAssertEqual(sql, "EXPLAIN (ANALYZE, FORMAT JSON) SELECT * FROM t;")
    }

    func testExplainWithBuffers() {
        let sql = SQLGenerator.explain(sql: "SELECT 1", analyze: true, buffers: true, dialect: pg)
        XCTAssertEqual(sql, "EXPLAIN (ANALYZE, BUFFERS) SELECT 1;")
    }

    func testExplainStripsTrailingSemicolonsAndWhitespace() {
        let sql = SQLGenerator.explain(sql: "  SELECT 1 ;;  ", analyze: true, dialect: pg)
        XCTAssertEqual(sql, "EXPLAIN (ANALYZE) SELECT 1;")
    }

    func testExplainFallsBackForDialectsWithoutJSONSupport() {
        // GBase 不支持 FORMAT JSON / BUFFERS，退化为普通 EXPLAIN。
        let sql = SQLGenerator.explain(sql: "SELECT 1", analyze: true, buffers: true, formatJSON: true, dialect: gbase)
        XCTAssertEqual(sql, "EXPLAIN SELECT 1;")
    }
}
