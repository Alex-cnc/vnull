import XCTest
@testable import DoyahCore

/// 视图 / 函数的 DDL 取回与装配（FR-META-13）。
///
/// 重点在两处容易出错的地方：**标识符到字面量的转换**（带引号的怪名字要能正确落到同一个对象）
/// 与**装配**（视图定义体要包成 `CREATE OR REPLACE VIEW`，且不能出现两个结尾分号）。
final class ObjectDDLTests: XCTestCase {

    private let postgres = PostgresDialect()
    private let gbase = GBaseDialect()

    // MARK: 查询构造

    func testPostgresViewQueryUsesRegclassWithQuotedTarget() throws {
        let query = try XCTUnwrap(ObjectDDL.view(schema: "public", name: "v_orders", dialect: postgres))
        XCTAssertTrue(query.sql.contains("pg_get_viewdef"), query.sql)
        // regclass 走标识符解析：名字要以**带引号的限定名**的字符串形式传进去。
        XCTAssertTrue(query.sql.contains("'\"public\".\"v_orders\"'::regclass"), query.sql)
        XCTAssertEqual(query.assembly, .wrapView(schema: "public", name: "v_orders"))
    }

    /// 名字里带单引号时，字面量必须转义 —— 否则生成的是一条语法错误的查询（甚至注入）。
    func testViewQueryEscapesQuotesInName() throws {
        let query = try XCTUnwrap(ObjectDDL.view(schema: "s", name: "we'ird", dialect: postgres))
        XCTAssertTrue(query.sql.contains("''"), query.sql)
        XCTAssertFalse(query.sql.contains("'we'ird'"), query.sql)
    }

    func testPostgresFunctionQueryCoversOverloadsAndSchema() throws {
        let scoped = try XCTUnwrap(ObjectDDL.function(schema: "public", name: "fn", dialect: postgres))
        XCTAssertTrue(scoped.sql.contains("pg_get_functiondef"), scoped.sql)
        XCTAssertTrue(scoped.sql.contains("n.nspname = 'public'"), scoped.sql)
        // 不 LIMIT 1：同名函数可能有多个重载，丢掉任何一个都会误导使用者。
        XCTAssertFalse(scoped.sql.lowercased().contains("limit 1"), scoped.sql)
        XCTAssertEqual(scoped.assembly, .asIs)

        let unscoped = try XCTUnwrap(ObjectDDL.function(schema: nil, name: "fn", dialect: postgres))
        XCTAssertTrue(unscoped.sql.contains("pg_function_is_visible"), unscoped.sql)
        XCTAssertFalse(unscoped.sql.contains("n.nspname ="), unscoped.sql)
    }

    func testGBaseUsesShowCreate() throws {
        let view = try XCTUnwrap(ObjectDDL.view(schema: nil, name: "v", dialect: gbase))
        XCTAssertTrue(view.sql.uppercased().hasPrefix("SHOW CREATE VIEW"), view.sql)

        let function = try XCTUnwrap(ObjectDDL.function(schema: nil, name: "f", dialect: gbase))
        XCTAssertTrue(function.sql.uppercased().hasPrefix("SHOW CREATE FUNCTION"), function.sql)
    }

    /// 不支持时返回 nil（**而不是**给一条跑不通的语句）—— 界面据此不呈现该项。
    func testUnsupportedDialectReturnsNil() {
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

        // 默认实现给出 nil —— 新接方言不必为了编译而写空方法。
        XCTAssertNil(ObjectDDL.view(schema: nil, name: "v", dialect: BareDialect()))
        XCTAssertNil(ObjectDDL.function(schema: nil, name: "f", dialect: BareDialect()))
    }

    // MARK: 装配

    func testAssembleWrapsViewDefinition() throws {
        let query = try XCTUnwrap(ObjectDDL.view(schema: "public", name: "v_orders", dialect: postgres))
        let text = try XCTUnwrap(ObjectDDL.assemble(
            query,
            columns: ["view_definition"],
            rows: [[" SELECT o.id,\n    o.total\n   FROM orders o;"]],
            dialect: postgres
        ))

        XCTAssertTrue(text.hasPrefix("CREATE OR REPLACE VIEW \"public\".\"v_orders\" AS\n"), text)
        XCTAssertTrue(text.hasSuffix(";"), text)
        // 定义体自带的分号要去掉，否则生成两条语句。
        XCTAssertEqual(text.filter { $0 == ";" }.count, 1, text)
        XCTAssertFalse(text.contains("o;;"), text)
    }

    /// 列名按大小写不敏感匹配：PG 给 `function_definition`，GBase 给 `Create Function`。
    func testAssembleFindsColumnCaseInsensitively() throws {
        let query = try XCTUnwrap(ObjectDDL.function(schema: nil, name: "f", dialect: gbase))
        let text = try XCTUnwrap(ObjectDDL.assemble(
            query,
            columns: ["Function", "sql_mode", "Create Function"],
            rows: [["f", "STRICT", "CREATE FUNCTION f() RETURNS int RETURN 1"]],
            dialect: gbase
        ))
        XCTAssertEqual(text, "CREATE FUNCTION f() RETURNS int RETURN 1")
    }

    /// 全部列名都对不上时退回第一列（比返回空更有用，也不会静默失败）。
    func testAssembleFallsBackToFirstColumn() throws {
        let query = try XCTUnwrap(ObjectDDL.view(schema: nil, name: "v", dialect: gbase))
        let text = try XCTUnwrap(ObjectDDL.assemble(
            query,
            columns: ["View", "Character_set_client"],
            rows: [["CREATE VIEW v AS SELECT 1", "utf8mb4"]],
            dialect: gbase
        ))
        XCTAssertTrue(text.contains("CREATE VIEW v AS SELECT 1"), text)
    }

    /// 函数重载：多行结果全部保留，按顺序拼接。
    func testAssembleKeepsEveryOverload() throws {
        let query = try XCTUnwrap(ObjectDDL.function(schema: "public", name: "fn", dialect: postgres))
        let text = try XCTUnwrap(ObjectDDL.assemble(
            query,
            columns: ["function_definition"],
            rows: [
                ["CREATE OR REPLACE FUNCTION fn(a int) RETURNS int AS $$ SELECT a $$ LANGUAGE sql;"],
                ["CREATE OR REPLACE FUNCTION fn(a int, b int) RETURNS int AS $$ SELECT a + b $$ LANGUAGE sql;"],
            ],
            dialect: postgres
        ))
        XCTAssertEqual(text.components(separatedBy: "CREATE OR REPLACE FUNCTION").count - 1, 2)
        XCTAssertTrue(text.contains("fn(a int, b int)"), text)
    }

    /// 空结果 / 全空值 → nil（由界面给出可读提示，通常是权限不足）。
    func testAssembleReturnsNilWhenNothingToAssemble() throws {
        let query = try XCTUnwrap(ObjectDDL.view(schema: nil, name: "v", dialect: postgres))
        XCTAssertNil(ObjectDDL.assemble(query, columns: ["view_definition"], rows: [], dialect: postgres))
        XCTAssertNil(ObjectDDL.assemble(query, columns: ["view_definition"], rows: [[nil]], dialect: postgres))
        XCTAssertNil(ObjectDDL.assemble(query, columns: ["view_definition"], rows: [["   "]], dialect: postgres))
    }

    // MARK: 动作可用性

    /// 视图与函数现在也能「查看 DDL」；插入模板等仍然只对表。
    func testViewDDLAvailableForTableViewAndFunction() {
        XCTAssertTrue(ObjectTreeActions.isAvailable(.viewDDL, for: .table))
        XCTAssertTrue(ObjectTreeActions.isAvailable(.viewDDL, for: .view))
        XCTAssertTrue(ObjectTreeActions.isAvailable(.viewDDL, for: .function))
        XCTAssertFalse(ObjectTreeActions.isAvailable(.viewDDL, for: .schema))
        XCTAssertFalse(ObjectTreeActions.isAvailable(.viewDDL, for: .column))

        XCTAssertFalse(ObjectTreeActions.isAvailable(.insertTemplate, for: .view))
        XCTAssertFalse(ObjectTreeActions.isAvailable(.truncateTable, for: .view))
    }

    /// 表仍走「读列 + 拼装」；视图 / 函数在这一层返回 nil（由 AppState 走 ObjectDDL 查询）。
    func testTableDDLStillBuiltFromColumns() throws {
        let target = ObjectTreeTarget(
            kind: .table,
            name: "t",
            schema: "public",
            columns: [
                ColumnMeta(id: 0, name: "id", typeName: "integer", isNullable: false),
                ColumnMeta(id: 1, name: "note", typeName: "text", isNullable: true),
            ]
        )
        let sql = try XCTUnwrap(ObjectTreeActions.sql(for: .viewDDL, target: target, dialect: postgres))
        XCTAssertTrue(sql.contains("\"id\" integer NOT NULL"), sql)
        XCTAssertTrue(sql.contains("\"note\" text"), sql)

        let viewTarget = ObjectTreeTarget(kind: .view, name: "v", schema: "public")
        XCTAssertNil(ObjectTreeActions.sql(for: .viewDDL, target: viewTarget, dialect: postgres))
    }
}
