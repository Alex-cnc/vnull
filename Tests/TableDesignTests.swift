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

    func testExactDuplicateColumnNameIsReported() {
        let issues = TableDesign.validate(
            tableName: "t",
            columns: [column("name"), column("name")]
        )
        XCTAssertEqual(issues, [.columnNameDuplicate("name")])
    }

    /// 判重**大小写敏感**：生成器始终给标识符加引号，`Name` 与 `name` 是两列。
    /// （早先按不敏感判重会把这种合法设计误判成重复。）
    func testCaseDifferingColumnNamesAreAllowed() {
        let issues = TableDesign.validate(
            tableName: "t",
            columns: [column("Name"), column("name")]
        )
        XCTAssertTrue(issues.isEmpty, "\(issues)")
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
    // MARK: 列级差异（改已有表）

    func testNoChangesWhenNothingEdited() {
        let original = [column("id", "bigint", nullable: false, primaryKey: true), column("name", "text")]
        XCTAssertTrue(TableDesign.columnChanges(original: original, edited: original).isEmpty)
    }

    /// 类型写法的大小写 / 空格差异不算改类型，否则会凭空生成 ALTER。
    func testTypeComparisonIgnoresCaseAndSpacing() {
        let original = [column("name", "text")]
        let edited = [column("name", "  TEXT ")]
        XCTAssertTrue(TableDesign.columnChanges(original: original, edited: edited).isEmpty)
    }

    func testAddColumn() {
        let original = [column("id", "bigint")]
        let added = column("nickname", "text")
        let edited = original + [added]
        // 注意复用同一个定义实例：TableColumnDefinition 带随机 id（列表身份用），
        // 重建同内容的定义 UUID 不同，直接比会假失败。
        XCTAssertEqual(TableDesign.columnChanges(original: original, edited: edited), [.add(added)])
    }

    func testDropColumn() {
        let original = [column("id", "bigint"), column("tmp", "text")]
        let edited = [column("id", "bigint")]
        XCTAssertEqual(TableDesign.columnChanges(original: original, edited: edited), [.drop(name: "tmp")])
    }

    /// 改名在差异里表现为「删一列 + 加一列」，且删除那步是破坏性的 —— 不假装支持 rename。
    func testRenameShowsUpAsDropPlusAdd() {
        let renamed = column("new_name", "text")
        let changes = TableDesign.columnChanges(
            original: [column("old_name", "text")],
            edited: [renamed]
        )
        XCTAssertEqual(changes, [.drop(name: "old_name"), .add(renamed)])
        XCTAssertTrue(changes[0].isDestructive)
    }

    func testNullabilityAndDefaultChanges() {
        let original = [column("state", "text", nullable: true, defaultValue: "'a'")]
        let edited = [column("state", "text", nullable: false, defaultValue: "'b'")]
        XCTAssertEqual(
            TableDesign.columnChanges(original: original, edited: edited),
            [.setNotNull(name: "state"), .setDefault(name: "state", value: "'b'")]
        )
    }

    func testClearingDefaultEmitsDropDefault() {
        let changes = TableDesign.columnChanges(
            original: [column("state", "text", defaultValue: "'a'")],
            edited: [column("state", "text", defaultValue: "  ")]
        )
        XCTAssertEqual(changes, [.dropDefault(name: "state")])
    }

    func testChangeTypeIsDestructiveButAddIsNot() {
        XCTAssertTrue(TableDesign.ColumnChange.changeType(name: "a", to: "int").isDestructive)
        XCTAssertTrue(TableDesign.ColumnChange.drop(name: "a").isDestructive)
        XCTAssertFalse(TableDesign.ColumnChange.add(column("a", "int")).isDestructive)
        XCTAssertFalse(TableDesign.ColumnChange.setNotNull(name: "a").isDestructive)
    }

    // MARK: ALTER TABLE 语句

    func testAlterStatementsCoverEveryChangeKind() {
        let changes: [TableDesign.ColumnChange] = [
            .add(column("c1", "int", nullable: false, defaultValue: "0")),
            .drop(name: "c2"),
            .changeType(name: "c3", to: "bigint"),
            .setNotNull(name: "c4"),
            .dropNotNull(name: "c5"),
            .setDefault(name: "c6", value: "now()"),
            .dropDefault(name: "c7")
        ]
        let statements = SQLGenerator.alterTableStatements(
            table: "users",
            schema: "app",
            changes: changes,
            dialect: pg
        )
        XCTAssertEqual(statements, [
            "ALTER TABLE \"app\".\"users\" ADD COLUMN \"c1\" int NOT NULL DEFAULT 0;",
            "ALTER TABLE \"app\".\"users\" DROP COLUMN \"c2\";",
            "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"c3\" TYPE bigint;",
            "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"c4\" SET NOT NULL;",
            "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"c5\" DROP NOT NULL;",
            "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"c6\" SET DEFAULT now();",
            "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"c7\" DROP DEFAULT;"
        ])
    }

    func testAlterStatementsEmptyWhenNoChanges() {
        XCTAssertTrue(
            SQLGenerator.alterTableStatements(table: "t", changes: [], dialect: pg).isEmpty
        )
    }
}
