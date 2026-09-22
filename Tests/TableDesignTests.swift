import XCTest
@testable import DoyahCore

/// 表设计与 `CREATE TABLE` 生成的测试（FR-DDL-03）。
final class TableDesignTests: XCTestCase {

    private let pg = SQLDialectFactory.make(for: .postgresql)

    private func column(
        _ name: String,
        _ type: String = "text",
        nullable: Bool = true,
        primaryKey: Bool = false,
        defaultValue: String = ""
    ) -> TableColumnDefinition {
        TableColumnDefinition(
            name: name,
            typeName: type,
            isNullable: nullable,
            defaultValue: defaultValue,
            isPrimaryKey: primaryKey
        )
    }

    // MARK: 校验

    func testValidDesignHasNoIssues() {
        let issues = TableDesign.validate(
            tableName: "users",
            columns: [column("id", "bigint", primaryKey: true), column("name", "text", nullable: false)]
        )
        XCTAssertTrue(issues.isEmpty)
    }

    func testEmptyTableName() {
        XCTAssertEqual(TableDesign.validate(tableName: "   ", columns: [column("a")]), [.tableNameEmpty])
    }

    func testInvalidTableName() {
        XCTAssertEqual(
            TableDesign.validate(tableName: "2 bad;drop", columns: [column("a")]),
            [.tableNameInvalid("2 bad;drop")]
        )
    }

    func testNoColumns() {
        XCTAssertEqual(TableDesign.validate(tableName: "t", columns: []), [.noColumns])
    }

    /// 空列名的报错要指出**第几列**找起来才快。
    func testEmptyColumnNameReportsPosition() {
        let issues = TableDesign.validate(
            tableName: "t",
            columns: [column("a"), column("   ")]
        )
        XCTAssertEqual(issues, [.columnNameEmpty(2)])
    }

    func testInvalidColumnName() {
        let issues = TableDesign.validate(tableName: "t", columns: [column("bad name")])
        XCTAssertEqual(issues, [.columnNameInvalid("bad name")])
    }

    /// 判重不区分大小写：服务端折叠未加引号的标识符，`Name` 与 `name` 实际是同一列。
    func testDuplicateColumnNameIsCaseInsensitive() {
        let issues = TableDesign.validate(
            tableName: "t",
            columns: [column("Name"), column("name")]
        )
        XCTAssertEqual(issues, [.columnNameDuplicate("name")])
    }

    func testMissingColumnType() {
        let issues = TableDesign.validate(tableName: "t", columns: [column("a", "  ")])
        XCTAssertEqual(issues, [.columnTypeEmpty("a")])
    }

    func testIssuesCarryLocalizedTextKeys() {
        XCTAssertEqual(TableDesign.Issue.tableNameEmpty.textKey, .tableIssueNameEmpty)
        XCTAssertEqual(TableDesign.Issue.columnNameEmpty(3).argument as? Int, 3)
        XCTAssertNil(TableDesign.Issue.noColumns.argument)
    }

    // MARK: CREATE TABLE 生成

    func testCreateTableQuotesIdentifiersAndNullability() {
        let sql = SQLGenerator.createTable(
            table: "users",
            columns: [column("id", "bigint", nullable: false), column("name", "text")],
            dialect: pg
        )
        XCTAssertEqual(sql, """
        CREATE TABLE "users" (
            "id" bigint NOT NULL,
            "name" text
        );
        """)
    }

    func testCreateTableWithSchema() {
        let sql = SQLGenerator.createTable(
            table: "users",
            columns: [column("id", "int")],
            schema: "app",
            dialect: pg
        )
        XCTAssertTrue(sql.hasPrefix("CREATE TABLE \"app\".\"users\" ("), sql)
    }

    func testSinglePrimaryKeyIsInlineAndForcesNotNull() {
        // 勾了主键又勾可空：服务端不接受可空主键，生成器应强制 NOT NULL
        let sql = SQLGenerator.createTable(
            table: "t",
            columns: [column("id", "bigint", nullable: true, primaryKey: true)],
            dialect: pg
        )
        XCTAssertTrue(sql.contains("\"id\" bigint NOT NULL PRIMARY KEY"), sql)
    }

    func testCompositePrimaryKeyBecomesTableLevelConstraint() {
        let sql = SQLGenerator.createTable(
            table: "t",
            columns: [
                column("a", "int", primaryKey: true),
                column("b", "int", primaryKey: true)
            ],
            dialect: pg
        )
        XCTAssertTrue(sql.contains("PRIMARY KEY (\"a\", \"b\")"), sql)
        XCTAssertFalse(sql.contains("NOT NULL PRIMARY KEY"), "复合主键不该写成行内主键：\(sql)")
    }

    func testDefaultValueIsWrittenVerbatim() {
        let sql = SQLGenerator.createTable(
            table: "t",
            columns: [
                column("created_at", "timestamptz", defaultValue: "now()"),
                column("state", "text", defaultValue: "'active'")
            ],
            dialect: pg
        )
        XCTAssertTrue(sql.contains("DEFAULT now()"), sql)
        XCTAssertTrue(sql.contains("DEFAULT 'active'"), sql)
    }

    func testEmptyColumnsStillProducesValidStatement() {
        let sql = SQLGenerator.createTable(table: "t", columns: [], dialect: pg)
        XCTAssertEqual(sql, "CREATE TABLE \"t\" ();")
    }

    /// 老的 `[ColumnMeta]` 版本是「查看建表 DDL」用的，不能被这次改动带坏。
    func testLegacyColumnMetaOverloadStillWorks() {
        let sql = SQLGenerator.createTableDDL(
            table: "legacy",
            columns: [ColumnMeta(id: 0, name: "id", typeName: "int", isNullable: false)],
            dialect: pg
        )
        XCTAssertEqual(sql, """
        CREATE TABLE "legacy" (
            "id" int NOT NULL
        );
        """)
    }
}
