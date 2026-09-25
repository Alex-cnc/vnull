import XCTest
@testable import DoyahCore

/// 表设计的索引 / 外键 / 约束（FR-DDL-03 扩写）：
/// 读取解析、语句生成，以及**变更集的执行顺序**（顺序错了就会有"某个组合就是跑不过"）。
final class TableDesignChangeSetTests: XCTestCase {

    private let dialect = PostgresDialect()

    private func column(_ name: String, type: String = "text", pk: Bool = false) -> TableColumnDefinition {
        TableColumnDefinition(name: name, typeName: type, isNullable: !pk, defaultValue: "", isPrimaryKey: pk)
    }

    private func result(columns: [String], rows: [[String?]]) -> QueryResult {
        QueryResult(
            columns: columns.enumerated().map { ColumnMeta(id: $0.offset, name: $0.element) },
            rows: rows,
            affectedRows: nil,
            executionTime: 0,
            isTruncated: false,
            truncationLimit: nil
        )
    }

    // MARK: 通用 ADD CONSTRAINT

    func testAddConstraintBuildsStatement() throws {
        let sql = try XCTUnwrap(SQLGenerator.addConstraint(
            name: "t_email_key",
            table: "t",
            schema: "public",
            definition: "UNIQUE (email)",
            dialect: dialect
        ))
        XCTAssertEqual(sql, "ALTER TABLE \"public\".\"t\" ADD CONSTRAINT \"t_email_key\" UNIQUE (email);")
    }

    /// 定义里出现分号 = 想塞第二条语句，一律拒绝。
    func testAddConstraintRefusesSemicolonAndEmpty() {
        XCTAssertNil(SQLGenerator.addConstraint(
            name: "c", table: "t", definition: "CHECK (a > 0); DROP TABLE t", dialect: dialect
        ))
        XCTAssertNil(SQLGenerator.addConstraint(name: "c", table: "t", definition: "   ", dialect: dialect))
        XCTAssertNil(SQLGenerator.addConstraint(
            name: "bad name", table: "t", definition: "CHECK (a > 0)", dialect: dialect
        ))
    }

    // MARK: 读取解析

    func testIndexesParsedFromQueryResult() {
        let result = self.result(
            columns: ["indexname", "indexdef"],
            rows: [
                ["t_pkey", "CREATE UNIQUE INDEX t_pkey ON public.t USING btree (id)"],
                ["t_email_idx", "CREATE INDEX t_email_idx ON public.t USING btree (email)"],
                [nil, "没有名字的行要丢掉"],
            ]
        )
        let indexes = TableDesignChangeSet.indexes(from: result)
        XCTAssertEqual(indexes.map(\.name), ["t_pkey", "t_email_idx"])
        XCTAssertTrue(indexes[1].definition.contains("t_email_idx"))
    }

    func testConstraintsParsedWithKinds() {
        let result = self.result(
            columns: ["conname", "contype", "pg_get_constraintdef"],
            rows: [
                ["t_pkey", "p", "PRIMARY KEY (id)"],
                ["t_email_key", "u", "UNIQUE (email)"],
                ["t_owner_fkey", "f", "FOREIGN KEY (owner_id) REFERENCES public.u(id)"],
                ["t_age_check", "c", "CHECK (age > 0)"],
                ["weird", "x", "SOMETHING"],
            ]
        )
        let constraints = TableDesignChangeSet.constraints(from: result)
        XCTAssertEqual(constraints.map(\.kind), [.primaryKey, .unique, .foreignKey, .check, .other])
        // 主键标成不可删：删主键要走显式操作，界面不该让人顺手点掉。
        XCTAssertFalse(constraints[0].kind.isRemovable)
        XCTAssertTrue(constraints[1].kind.isRemovable)
        XCTAssertTrue(constraints[4].kind.isRemovable, "未知类型按可删处理，由服务端最终裁决")
    }

    // MARK: 变更集与执行顺序

    func testEmptyChangeSetIsEmpty() {
        let columns = [column("id", type: "bigint", pk: true)]
        XCTAssertTrue(TableDesignChangeSet(originalColumns: columns, editedColumns: columns).isEmpty)
        XCTAssertFalse(TableDesignChangeSet(originalColumns: columns, editedColumns: columns + [column("note")]).isEmpty)
    }

    /// **顺序是契约**：删约束 → 删索引 → 列变更 → 新索引 → 新外键 → 新约束。
    func testStatementOrderIsFixed() {
        let changeSet = TableDesignChangeSet(
            originalColumns: [column("id", type: "bigint", pk: true)],
            editedColumns: [
                column("id", type: "bigint", pk: true),
                column("email"),
            ],
            newIndexes: [SQLGenerator.IndexDefinition(name: "t_email_idx", table: "t", schema: "public", columns: ["email"])],
            droppedIndexes: ["t_old_idx"],
            newForeignKeys: [
                SQLGenerator.ForeignKeyDefinition(
                    name: "t_owner_fkey",
                    table: "t",
                    schema: "public",
                    columns: ["owner_id"],
                    referencedTable: "u",
                    referencedSchema: "public",
                    referencedColumns: ["id"]
                )
            ],
            newConstraints: [TableConstraintDraft(name: "t_email_key", definition: "UNIQUE (email)")],
            droppedConstraints: ["t_legacy_check"]
        )

        let statements = TableDesignChangeSet.statements(for: changeSet, table: "t", schema: "public", dialect: dialect)
        XCTAssertEqual(statements.count, 6, statements.joined(separator: "\n"))

        XCTAssertTrue(statements[0].hasPrefix("ALTER TABLE \"public\".\"t\" DROP CONSTRAINT"), statements[0])
        XCTAssertTrue(statements[1].hasPrefix("DROP INDEX"), statements[1])
        XCTAssertTrue(statements[2].hasPrefix("ALTER TABLE \"public\".\"t\" ADD COLUMN \"email\""), statements[2])
        XCTAssertTrue(statements[3].hasPrefix("CREATE INDEX \"t_email_idx\""), statements[3])
        XCTAssertTrue(statements[4].contains("FOREIGN KEY"), statements[4])
        XCTAssertTrue(statements[5].contains("ADD CONSTRAINT \"t_email_key\""), statements[5])

        // 列变更必须在建索引之前：否则会在还不存在的列上建索引。
        let addColumnIndex = statements.firstIndex { $0.contains("ADD COLUMN") }!
        let createIndexIndex = statements.firstIndex { $0.hasPrefix("CREATE INDEX") }!
        XCTAssertLessThan(addColumnIndex, createIndexIndex)
    }

    /// 合并的改动（删列 + 改类型 + 加索引）也要按同一顺序排好。
    func testCombinedColumnAndIndexChanges() {
        let changeSet = TableDesignChangeSet(
            originalColumns: [column("id", type: "bigint", pk: true), column("note")],
            editedColumns: [column("id", type: "bigint", pk: true), column("note", type: "varchar(200)")],
            newIndexes: [SQLGenerator.IndexDefinition(name: "t_note_idx", table: "t", columns: ["note"])]
        )
        let statements = TableDesignChangeSet.statements(for: changeSet, table: "t", schema: nil, dialect: dialect)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].contains("ALTER COLUMN"), statements[0])
        XCTAssertTrue(statements[1].hasPrefix("CREATE INDEX"), statements[1])
    }

    /// 任一条非法 → **整批不生成**：宁可什么都不做，也不给一份残缺的执行计划。
    func testInvalidEntryMakesWholeBatchEmpty() {
        let changeSet = TableDesignChangeSet(
            editedColumns: [column("id")],
            newConstraints: [TableConstraintDraft(name: "c", definition: "CHECK (a > 0); DROP TABLE t")]
        )
        XCTAssertTrue(
            TableDesignChangeSet.statements(for: changeSet, table: "t", schema: nil, dialect: dialect).isEmpty
        )
    }

    func testNoChangeProducesNoStatements() {
        let columns = [column("id", type: "bigint", pk: true)]
        let empty = TableDesignChangeSet(originalColumns: columns, editedColumns: columns)
        XCTAssertTrue(TableDesignChangeSet.statements(for: empty, table: "t", schema: nil, dialect: dialect).isEmpty)
    }

    // MARK: 方言能力

    func testDialectQueries() throws {
        let indexes = try XCTUnwrap(dialect.tableIndexesQuery(table: "t", schema: "public"))
        XCTAssertTrue(indexes.contains("pg_indexes"), indexes)
        XCTAssertTrue(indexes.contains("'public'"), indexes)

        let constraints = try XCTUnwrap(dialect.tableConstraintsQuery(table: "t", schema: "public"))
        XCTAssertTrue(constraints.contains("pg_get_constraintdef"), constraints)
        XCTAssertTrue(constraints.contains("'p', 'u', 'f', 'c'"), constraints)

        // 不支持读取的方言返回 nil，界面据此明说，而不是给一份半对的清单。
        struct BareDialect: SQLDialect {
            let databaseType: DatabaseType = .postgresql
            let featureSet: SQLFeatureSet = []
            let identifierQuote = "\""
            let statementDelimiter = ";"
            func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
            func limitClause(offset: Int, count: Int) -> String { "LIMIT \(count)" }
            func listDatabasesQuery() -> String { "SELECT 1" }
            func databaseCreationPrivilegeQuery() -> String? { nil }
            func listSchemasQuery(database: String) -> String { "SELECT 1" }
            func listTablesQuery(database: String, schema: String?) -> String { "SELECT 1" }
            func listColumnsQuery(table: String, schema: String?) -> String { "SELECT 1" }
            func serverVersionQuery() -> String { "SELECT 1" }
            func currentDatabaseQuery() -> String { "SELECT 1" }
            func parseServerVersion(_ raw: String) -> DatabaseVersion { DatabaseVersion(major: 1, minor: 0, patch: 0, raw: raw) }
            var keywords: [String] { [] }
            var builtinFunctions: [String] { [] }
        }
        XCTAssertNil(BareDialect().tableIndexesQuery(table: "t", schema: nil))
        XCTAssertNil(BareDialect().tableConstraintsQuery(table: "t", schema: nil))
    }
}

/// **新建表的执行计划**（2026-09-25 需求提出者实测的真实缺陷）。
///
/// 症状：新建表时界面报「第 1 条变更执行失败：MySQL error: Server error: Duplicate column name 'id'」。
/// 真凶：**预览与执行不是同一份语句** —— 预览只拼了 `CREATE TABLE` + 索引 / 约束，
/// 而执行那条路把整份变更集（`editedColumns` = 全部列）交给了 `statements(...)`，
/// 于是每一列又发了一次 `ALTER TABLE … ADD COLUMN`，第一列就撞上"列已存在"。
///
/// 这一组测试钉的就是那条边界：**新建表的计划里不该出现任何列变更语句**。
final class TableDesignCreatePlanTests: XCTestCase {

    private let pg = PostgresDialect()
    private let mysql = MySQLDialect()

    private func column(_ name: String, type: String = "text", pk: Bool = false) -> TableColumnDefinition {
        TableColumnDefinition(name: name, typeName: type, isNullable: !pk, defaultValue: "", isPrimaryKey: pk)
    }

    private var twoColumns: [TableColumnDefinition] {
        [column("id", type: "integer", pk: true), column("name")]
    }

    /// 新建表：计划第一句是 `CREATE TABLE`，**且后面没有一句 ADD COLUMN**。
    func testCreatePlanNeverReAddsColumns() {
        let extras = TableDesignChangeSet(
            originalColumns: [],
            editedColumns: twoColumns,
            newIndexes: [SQLGenerator.IndexDefinition(name: "t_name_idx", table: "t", schema: nil, columns: ["name"], isUnique: false, whereClause: nil)]
        )
        let plan = TableDesignChangeSet.createTablePlan(
            table: "t", columns: twoColumns, schema: nil, extras: extras, dialect: pg
        )
        XCTAssertEqual(plan.count, 2, "应当是 CREATE TABLE + CREATE INDEX 两句")
        XCTAssertTrue(plan[0].hasPrefix("CREATE TABLE"), "第一句必须是建表：\(plan[0])")
        XCTAssertTrue(plan[0].contains("\"id\"") && plan[0].contains("\"name\""), "列要写进建表语句里")
        for statement in plan.dropFirst() {
            XCTAssertFalse(
                statement.contains("ADD COLUMN"),
                "列已经在 CREATE TABLE 里了，不该再 ADD 一次（这正是用户看到的 Duplicate column name）：\(statement)"
            )
        }
        XCTAssertTrue(plan[1].contains("CREATE INDEX"), "索引仍要补上：\(plan[1])")
    }

    /// **回归**：把"整份变更集"当 extras 传进来（界面之前就是这么传的），也不许产生 ADD COLUMN。
    func testFullChangeSetPassedAsExtrasIsStillSafe() {
        let full = TableDesignChangeSet(originalColumns: [], editedColumns: twoColumns)
        let plan = TableDesignChangeSet.createTablePlan(
            table: "t", columns: twoColumns, schema: nil, extras: full, dialect: mysql
        )
        XCTAssertEqual(plan.count, 1, "没有索引 / 约束时就只有建表一句：\(plan)")
        XCTAssertFalse(plan[0].contains("ADD COLUMN"))
    }

    /// `createTableExtras` 只留"新的"，把列变更与删除项都丢掉（新表没有东西可删）。
    func testCreateTableExtrasDropsColumnsAndDrops() {
        let set = TableDesignChangeSet(
            originalColumns: [column("old")],
            editedColumns: twoColumns,
            newIndexes: [SQLGenerator.IndexDefinition(name: "i", table: "t", schema: nil, columns: ["name"], isUnique: false, whereClause: nil)],
            droppedIndexes: ["gone"],
            newConstraints: [TableConstraintDraft(name: "ck", definition: "CHECK (true)")],
            droppedConstraints: ["also_gone"]
        )
        let extras = set.createTableExtras
        XCTAssertTrue(extras.originalColumns.isEmpty)
        XCTAssertTrue(extras.editedColumns.isEmpty)
        XCTAssertTrue(extras.droppedIndexes.isEmpty)
        XCTAssertTrue(extras.droppedConstraints.isEmpty)
        XCTAssertEqual(extras.newIndexes.count, 1)
        XCTAssertEqual(extras.newConstraints.count, 1)
        XCTAssertFalse(extras.isEmpty, "确实有东西要补，不能被当成空")
    }

    /// 没有任何 extras 时，计划就只有建表那一句。
    func testPlanWithoutExtrasIsJustCreate() {
        XCTAssertEqual(
            TableDesignChangeSet.createTablePlan(table: "t", columns: twoColumns, schema: nil, extras: nil, dialect: pg),
            [SQLGenerator.createTable(table: "t", columns: twoColumns, schema: nil, dialect: pg)]
        )
    }

    /// 索引非法（没有列）时**整批返回空** —— 与 `statements(...)` 同一口径：不给残缺计划。
    func testPlanIsEmptyWhenAnExtraCannotBeGenerated() {
        let bad = TableDesignChangeSet(
            newIndexes: [SQLGenerator.IndexDefinition(name: "i", table: "t", schema: nil, columns: [], isUnique: false, whereClause: nil)]
        )
        XCTAssertTrue(
            TableDesignChangeSet.createTablePlan(table: "t", columns: twoColumns, schema: nil, extras: bad, dialect: pg).isEmpty
        )
    }

    /// 编辑已有表那条路**不受影响**：列变更照旧生成（别把建表的规则误用到 ALTER 上）。
    func testEditingStillEmitsColumnChanges() {
        let edited = TableDesignChangeSet(originalColumns: [column("id", type: "integer", pk: true)], editedColumns: twoColumns)
        let statements = TableDesignChangeSet.statements(for: edited, table: "t", schema: nil, dialect: pg)
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].contains("ADD COLUMN"), "ALTER 路径该有的列变更不能少：\(statements[0])")
    }

    /// MySQL 方言下的建表计划同样干净（用户就是在 MySQL 上撞到的）。
    func testMySQLCreatePlanIsClean() {
        let plan = TableDesignChangeSet.createTablePlan(
            table: "t",
            columns: twoColumns,
            schema: nil,
            extras: TableDesignChangeSet(originalColumns: [], editedColumns: twoColumns),
            dialect: mysql
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertTrue(plan[0].contains("`id`"), "MySQL 用反引号：\(plan[0])")
        XCTAssertFalse(plan.joined().contains("ADD COLUMN"))
    }
}
