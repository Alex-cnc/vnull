import XCTest
@testable import DoyahCore

/// FR-SESS-04 / FR-SESS-05：已授权限解析与服务端错误归类。
final class DatabaseAdminTests: XCTestCase {

    private let columns = [
        "object_kind", "object_name", "schema_name", "grantee", "privilege_type", "is_grantable"
    ].enumerated().map { ColumnMeta(id: $0.offset, name: $0.element, typeName: "text") }

    private func result(_ rows: [[String?]]) -> QueryResult {
        QueryResult(columns: columns, rows: rows)
    }

    // MARK: - 权限解析

    func testParsesPrivilegeRows() throws {
        let privileges = ObjectPrivilegeParser.privileges(from: result([
            ["database", "appdb", nil, "app", "CONNECT", "f"],
            ["schema", "public", nil, "app", "USAGE", "t"],
            ["table", "orders", "public", "app", "SELECT", "f"],
            ["sequence", "orders_id_seq", "public", "app", "USAGE", "f"]
        ]))

        XCTAssertEqual(privileges.count, 4)
        let select = try XCTUnwrap(privileges.first { $0.privilege == "SELECT" })
        XCTAssertEqual(select.objectKind, .table)
        XCTAssertEqual(select.objectName, "orders")
        XCTAssertEqual(select.schema, "public")
        XCTAssertEqual(select.grantee, "app")
        XCTAssertFalse(select.isGrantable)
        XCTAssertEqual(select.qualifiedObjectName, "public.orders")
        XCTAssertEqual(select.displayName, "table public.orders · SELECT")

        // 库级权限没有 schema。
        let connect = try XCTUnwrap(privileges.first { $0.privilege == "CONNECT" })
        XCTAssertNil(connect.schema)
        XCTAssertEqual(connect.qualifiedObjectName, "appdb")
    }

    /// `is_grantable` 的 `t` / `1` / `true` 都要认，缺失按 false。
    func testGrantableFlagParsing() {
        let privileges = ObjectPrivilegeParser.privileges(from: result([
            ["table", "a", "public", "app", "SELECT", "t"],
            ["table", "b", "public", "app", "SELECT", "1"],
            ["table", "c", "public", "app", "SELECT", "true"],
            ["table", "d", "public", "app", "SELECT", nil],
            ["table", "e", "public", "app", "SELECT", "f"]
        ]))

        XCTAssertEqual(privileges.filter(\.isGrantable).map(\.objectName), ["a", "b", "c"])
    }

    /// 缺列 / 空值的行跳过，不产生「空权限」条目。
    func testRowsWithoutObjectOrPrivilegeAreSkipped() {
        let privileges = ObjectPrivilegeParser.privileges(from: result([
            [nil, nil, nil, "app", "SELECT", "f"],
            ["table", "  ", "public", "app", "SELECT", "f"],
            ["table", "orders", "public", "app", nil, "f"],
            ["table", "orders", "public", "app", "   ", "f"],
            ["table", "ok", "public", "app", "SELECT", "f"]
        ]))

        XCTAssertEqual(privileges.map(\.objectName), ["ok"])
    }

    /// `grantee` 缺失归一为 `PUBLIC`（与查询里的 COALESCE 语义一致）。
    func testMissingGranteeBecomesPublic() {
        let privileges = ObjectPrivilegeParser.privileges(from: result([
            ["table", "orders", "public", nil, "SELECT", "f"]
        ]))

        XCTAssertEqual(privileges.first?.grantee, "PUBLIC")
    }

    /// 未知的对象类别归入 `other`，不丢行。
    func testUnknownObjectKindFallsBackToOther() {
        let privileges = ObjectPrivilegeParser.privileges(from: result([
            ["foreign_table", "remote", "public", "app", "SELECT", "f"],
            ["table", "orders", "public", "app", "SELECT", "f"]
        ]))

        XCTAssertEqual(privileges.map(\.objectKind), [.table, .other])
    }

    func testEmptyResultYieldsNoPrivileges() {
        XCTAssertTrue(ObjectPrivilegeParser.privileges(from: result([])).isEmpty)
    }

    /// 排序稳定：类别 → 对象名 → 权限名。
    func testPrivilegesAreSortedStably() {
        let privileges = ObjectPrivilegeParser.privileges(from: result([
            ["table", "orders", "public", "app", "UPDATE", "f"],
            ["database", "appdb", nil, "app", "CONNECT", "f"],
            ["table", "orders", "public", "app", "SELECT", "f"],
            ["table", "customers", "public", "app", "SELECT", "f"]
        ]))

        XCTAssertEqual(privileges.map { "\($0.objectKind.rawValue)|\($0.objectName)|\($0.privilege)" }, [
            "database|appdb|CONNECT",
            "table|customers|SELECT",
            "table|orders|SELECT",
            "table|orders|UPDATE"
        ])
    }

    func testGroupingByObject() {
        let privileges = ObjectPrivilegeParser.privileges(from: result([
            ["table", "orders", "public", "app", "SELECT", "f"],
            ["table", "orders", "public", "app", "UPDATE", "f"],
            ["table", "customers", "public", "app", "SELECT", "f"]
        ]))

        let groups = ObjectPrivilegeParser.groupedByObject(privileges)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].object.qualifiedObjectName, "public.customers")
        XCTAssertEqual(groups[1].object.qualifiedObjectName, "public.orders")
        XCTAssertEqual(groups[1].privileges.map(\.privilege), ["SELECT", "UPDATE"])
    }

    /// 权限名统一大写，避免服务端大小写差异造成同一条权限显示两次。
    func testPrivilegeNameIsUppercased() {
        let privileges = ObjectPrivilegeParser.privileges(from: result([
            ["table", "orders", "public", "app", "select", "f"]
        ]))

        XCTAssertEqual(privileges.first?.privilege, "SELECT")
    }

    // MARK: - 布尔解析（共用一处）

    func testBooleanValueParsing() {
        XCTAssertEqual(PrivilegeProbe.booleanValue(from: "t"), true)
        XCTAssertEqual(PrivilegeProbe.booleanValue(from: "1"), true)
        XCTAssertEqual(PrivilegeProbe.booleanValue(from: "YES"), true)
        XCTAssertEqual(PrivilegeProbe.booleanValue(from: "f"), false)
        XCTAssertEqual(PrivilegeProbe.booleanValue(from: " 0 "), false)
        XCTAssertNil(PrivilegeProbe.booleanValue(from: nil))
        XCTAssertNil(PrivilegeProbe.booleanValue(from: "maybe"))
        // 建库权限解析仍走同一处实现。
        XCTAssertEqual(PrivilegeProbe.databaseCreationAllowed(from: "t"), true)
    }

    // MARK: - 服务端错误归类（验收要点的可读提示）

    func testClassifiesActiveConnections() {
        XCTAssertEqual(
            DatabaseAdminHint.classify(
                serverMessage: #"ERROR: database "appdb" is being accessed by other users"#
            ),
            .activeConnections
        )
    }

    func testClassifiesPrivilegeProblems() {
        XCTAssertEqual(
            DatabaseAdminHint.classify(serverMessage: #"ERROR: must be owner of database appdb"#),
            .insufficientPrivilege
        )
        XCTAssertEqual(
            DatabaseAdminHint.classify(serverMessage: #"ERROR: permission denied for database appdb"#),
            .insufficientPrivilege
        )
        XCTAssertEqual(
            DatabaseAdminHint.classify(serverMessage: #"ERROR: must be superuser to alter this"#),
            .insufficientPrivilege
        )
    }

    func testClassifiesMissingAndCurrentDatabase() {
        XCTAssertEqual(
            DatabaseAdminHint.classify(serverMessage: #"ERROR: database "nope" does not exist"#),
            .databaseDoesNotExist
        )
        XCTAssertEqual(
            DatabaseAdminHint.classify(
                serverMessage: #"ERROR: cannot drop the currently open database"#
            ),
            .currentDatabase
        )
    }

    /// 不认识的错误返回 nil，由界面回退显示原文（不硬编原因）。
    func testUnknownErrorIsNotGuessed() {
        XCTAssertNil(DatabaseAdminHint.classify(serverMessage: "ERROR: connection reset by peer"))
        XCTAssertNil(DatabaseAdminHint.classify(serverMessage: ""))
    }

    func testEveryHintIsDistinct() {
        XCTAssertEqual(Set(DatabaseAdminHint.allCases.map(\.rawValue)).count, DatabaseAdminHint.allCases.count)
    }
}
