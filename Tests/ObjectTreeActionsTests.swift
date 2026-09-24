import XCTest
@testable import DoyahCore

/// FR-META-14 / FR-DATA-01 / FR-META-13（表部分）：对象树动作 → SQL。
final class ObjectTreeActionsTests: XCTestCase {

    private let pg = PostgresDialect()
    private let gbase = GBaseDialect()

    private let columns = [
        ColumnMeta(id: 0, name: "id", typeName: "integer", isNullable: false),
        ColumnMeta(id: 1, name: "total", typeName: "numeric", isNullable: true)
    ]

    private func table(_ name: String = "orders", schema: String? = "public", withColumns: Bool = true) -> ObjectTreeTarget {
        ObjectTreeTarget(kind: .table, name: name, schema: schema, columns: withColumns ? columns : [])
    }

    // MARK: - 菜单可用性

    func testAvailabilityPerNodeKind() {
        // 表：全套
        for action in [ObjectTreeAction.browseRows, .selectTemplate, .insertTemplate,
                       .copyQualifiedName, .viewDDL, .truncateTable, .dropTable] {
            XCTAssertTrue(ObjectTreeActions.isAvailable(action, for: .table), "\(action) 应可用于表")
        }
        // 视图：可浏览 / 生成 SELECT / 复制名 / **查看 DDL**；不能插入模板或删改。
        //
        // 视图的 DDL 此前往 `columns` 里找，而视图定义体根本不在列信息里，于是只能返回 nil、
        // 菜单项也一并禁用。FR-META-13 改成由 `ObjectDDL` 走方言查询取回（视图 / 函数），
        // 因此这条断言随之更新 —— 表仍走"读列 + 拼装"的老路。
        XCTAssertTrue(ObjectTreeActions.isAvailable(.browseRows, for: .view))
        XCTAssertTrue(ObjectTreeActions.isAvailable(.selectTemplate, for: .view))
        XCTAssertTrue(ObjectTreeActions.isAvailable(.copyQualifiedName, for: .view))
        XCTAssertTrue(ObjectTreeActions.isAvailable(.viewDDL, for: .view))
        XCTAssertTrue(ObjectTreeActions.isAvailable(.viewDDL, for: .function))
        XCTAssertFalse(ObjectTreeActions.isAvailable(.insertTemplate, for: .view))
        XCTAssertFalse(ObjectTreeActions.isAvailable(.dropTable, for: .view))
        XCTAssertFalse(ObjectTreeActions.isAvailable(.viewDDL, for: .column))
        // 列：只复制列名
        XCTAssertTrue(ObjectTreeActions.isAvailable(.copyColumnName, for: .column))
        XCTAssertFalse(ObjectTreeActions.isAvailable(.browseRows, for: .column))
        // 服务器 / 库 / schema：无动作
        for kind in [DatabaseObject.Kind.server, .database, .schema] {
            for action in ObjectTreeAction.allCases {
                XCTAssertFalse(ObjectTreeActions.isAvailable(action, for: kind), "\(action) 不该出现在 \(kind)")
            }
        }
    }

    // MARK: - 浏览前 N 行（FR-DATA-01）

    func testBrowseRowsUsesDialectLimitClause() throws {
        let pgSQL = try XCTUnwrap(ObjectTreeActions.sql(for: .browseRows, target: table(), dialect: pg))
        XCTAssertEqual(pgSQL, "SELECT * FROM \"public\".\"orders\" LIMIT 200 OFFSET 0;")
        XCTAssertTrue(pgSQL.hasSuffix(";"))

        let gbaseSQL = try XCTUnwrap(ObjectTreeActions.sql(for: .browseRows, target: table(), dialect: gbase))
        XCTAssertEqual(gbaseSQL, "SELECT * FROM `orders` LIMIT 0, 200;")
    }

    func testBrowseRowsHonoursCustomLimit() throws {
        let sql = try XCTUnwrap(
            ObjectTreeActions.sql(for: .browseRows, target: table(), dialect: pg, browseLimit: 50)
        )
        XCTAssertTrue(sql.contains("LIMIT 50"))
    }

    /// 浏览不需要列信息 —— 未展开的表节点也能直接双击。
    func testBrowseRowsWorksWithoutLoadedColumns() {
        XCTAssertNotNil(ObjectTreeActions.sql(for: .browseRows, target: table(withColumns: false), dialect: pg))
    }

    // MARK: - 模板

    func testSelectTemplateListsColumns() throws {
        let sql = try XCTUnwrap(ObjectTreeActions.sql(for: .selectTemplate, target: table(), dialect: pg))
        XCTAssertEqual(sql, "SELECT \"id\", \"total\" FROM \"public\".\"orders\";")
    }

    func testSelectTemplateFallsBackToStarWithoutColumns() throws {
        let sql = try XCTUnwrap(
            ObjectTreeActions.sql(for: .selectTemplate, target: table(withColumns: false), dialect: pg)
        )
        XCTAssertEqual(sql, "SELECT * FROM \"public\".\"orders\";")
    }

    /// 没有列信息时不生成 INSERT 模板（宁可禁用菜单项，也不生成一条没用的语句）。
    func testInsertTemplateRequiresColumns() {
        XCTAssertNil(ObjectTreeActions.sql(for: .insertTemplate, target: table(withColumns: false), dialect: pg))

        let sql = ObjectTreeActions.sql(for: .insertTemplate, target: table(), dialect: pg)
        XCTAssertEqual(sql, "INSERT INTO \"public\".\"orders\" (\"id\", \"total\") VALUES (?, ?);")
    }

    // MARK: - 查看 DDL（FR-META-13 表部分）

    func testViewDDLBuildsCreateTable() throws {
        let sql = try XCTUnwrap(ObjectTreeActions.sql(for: .viewDDL, target: table(), dialect: pg))
        XCTAssertTrue(sql.hasPrefix("CREATE TABLE \"public\".\"orders\" ("))
        XCTAssertTrue(sql.contains("\"id\" integer NOT NULL"))
        XCTAssertTrue(sql.contains("\"total\" numeric"))
        XCTAssertFalse(sql.contains("\"total\" numeric NOT NULL"), "可空列不该带 NOT NULL")
    }

    func testViewDDLRequiresColumns() {
        XCTAssertNil(ObjectTreeActions.sql(for: .viewDDL, target: table(withColumns: false), dialect: pg))
    }

    // MARK: - 破坏性动作（只生成，不执行）

    func testTruncateAndDropGenerateStatementsOnly() throws {
        let truncate = try XCTUnwrap(ObjectTreeActions.sql(for: .truncateTable, target: table(), dialect: pg))
        XCTAssertEqual(truncate, "TRUNCATE TABLE \"public\".\"orders\";")

        let drop = try XCTUnwrap(ObjectTreeActions.sql(for: .dropTable, target: table(), dialect: pg))
        XCTAssertEqual(drop, "DROP TABLE IF EXISTS \"public\".\"orders\";")

        XCTAssertTrue(ObjectTreeAction.truncateTable.isDestructive)
        XCTAssertTrue(ObjectTreeAction.dropTable.isDestructive)
        // 破坏性动作也属于"生成 SQL"类，绝不由这里执行。
        XCTAssertTrue(ObjectTreeAction.dropTable.producesSQL)
    }

    // MARK: - 复制类

    func testCopyQualifiedNameUsesDialectQuoting() {
        let target = table()
        XCTAssertEqual(
            ObjectTreeActions.copiedText(for: .copyQualifiedName, target: target, dialect: pg),
            "\"public\".\"orders\""
        )
        XCTAssertEqual(
            ObjectTreeActions.copiedText(for: .copyQualifiedName, target: target, dialect: gbase),
            "`orders`"
        )
        XCTAssertNil(ObjectTreeActions.copiedText(for: .browseRows, target: target, dialect: pg))
    }

    func testCopyColumnName() {
        let column = ObjectTreeTarget(kind: .column, name: "total", schema: "public")

        XCTAssertEqual(ObjectTreeActions.copiedText(for: .copyColumnName, target: column, dialect: pg), "total")
        XCTAssertNil(ObjectTreeActions.copiedText(for: .copyColumnName, target: table(), dialect: pg))
    }

    // MARK: - 非法输入 / 方言一致性

    func testRejectsInvalidIdentifiers() {
        XCTAssertNil(ObjectTreeActions.sql(for: .browseRows, target: table("bad name"), dialect: pg))
        XCTAssertNil(ObjectTreeActions.sql(for: .browseRows, target: table("orders", schema: "bad schema"), dialect: pg))
        XCTAssertNil(ObjectTreeActions.copiedText(for: .copyQualifiedName, target: table(""), dialect: pg))
    }

    /// 中文标识符同样走方言引用、不被拒。
    func testUnicodeIdentifiers() throws {
        let target = ObjectTreeTarget(kind: .table, name: "订单", schema: "销售")

        let sql = try XCTUnwrap(ObjectTreeActions.sql(for: .browseRows, target: target, dialect: pg))
        XCTAssertTrue(sql.contains("\"销售\".\"订单\""))
    }

    // MARK: - 列定义解析

    private func columnResult(_ rows: [[String?]]) -> QueryResult {
        let columns = ["column_name", "data_type", "is_nullable", "column_default"]
            .enumerated()
            .map { ColumnMeta(id: $0.offset, name: $0.element, typeName: "text") }
        return QueryResult(columns: columns, rows: rows)
    }

    /// 可空性必须被解析出来：否则生成的建表语句会悄悄丢掉 NOT NULL。
    func testColumnSpecParserKeepsNullability() {
        let specs = ColumnSpecParser.columns(from: columnResult([
            ["id", "integer", "NO", nil],
            ["total", "numeric", "YES", "0"],
            ["note", "text", nil, nil]
        ]))

        XCTAssertEqual(specs.count, 3)
        XCTAssertEqual(specs[0].name, "id")
        XCTAssertEqual(specs[0].typeName, "integer")
        XCTAssertFalse(specs[0].isNullable)
        XCTAssertTrue(specs[1].isNullable)
        // is_nullable 缺失时按可空处理（不擅自加 NOT NULL）。
        XCTAssertTrue(specs[2].isNullable)
    }

    func testColumnSpecParserSkipsRowsWithoutNameAndDefaultsType() {
        let specs = ColumnSpecParser.columns(from: columnResult([
            [nil, "integer", "NO", nil],
            ["  ", "integer", "NO", nil],
            ["weird", nil, "NO", nil]
        ]))

        XCTAssertEqual(specs.map(\.name), ["weird"])
        XCTAssertEqual(specs[0].typeName, "text")
    }

    /// 解析出的列可直接喂给 DDL / 模板生成（端到端一致性）。
    func testParsedColumnsFeedIntoDDL() throws {
        let specs = ColumnSpecParser.columns(from: columnResult([
            ["id", "integer", "NO", nil],
            ["total", "numeric", "YES", nil]
        ]))
        let target = ObjectTreeTarget(kind: .table, name: "orders", schema: "public", columns: specs)

        let ddl = try XCTUnwrap(ObjectTreeActions.sql(for: .viewDDL, target: target, dialect: pg))
        XCTAssertTrue(ddl.contains("\"id\" integer NOT NULL"))
        XCTAssertTrue(ddl.contains("\"total\" numeric"))

        let insert = try XCTUnwrap(ObjectTreeActions.sql(for: .insertTemplate, target: target, dialect: pg))
        XCTAssertTrue(insert.contains("(\"id\", \"total\")"))
    }
    /// 哪些节点该有右键菜单（FR-META-14 / FR-META-11）—— 漏一个就有一项点不到。
    ///
    /// 这条规则的来源是一次实测缺陷：需求提出者「右键点数据库弹出的是服务器菜单」，
    /// 排查时发现 `database` / `schema`（新建表的入口）与 `function`（查看 DDL）都没在这份集合里，
    /// 于是那两个功能**在界面上根本点不到**。
    func testMenuKindsCoverEveryActionableNode() {
        XCTAssertTrue(ObjectTreeActions.hasContextMenu(.server))
        XCTAssertTrue(ObjectTreeActions.hasContextMenu(.database))
        XCTAssertTrue(ObjectTreeActions.hasContextMenu(.schema))
        XCTAssertTrue(ObjectTreeActions.hasContextMenu(.table))
        XCTAssertTrue(ObjectTreeActions.hasContextMenu(.view))
        XCTAssertTrue(ObjectTreeActions.hasContextMenu(.function))
        XCTAssertTrue(ObjectTreeActions.hasContextMenu(.column))
        // 反向：没有动作可做的类型不该有菜单（空菜单比没有菜单更让人困惑）。
        XCTAssertFalse(ObjectTreeActions.hasContextMenu(.sequence))
    }

}
