import XCTest
@testable import PostgresClientCore

/// FR-META-15：对象树按类型 / schema 分组视图。
final class ObjectTreeGroupingTests: XCTestCase {

    private func object(
        _ name: String,
        kind: DatabaseObject.Kind,
        schema: String? = "public"
    ) -> DatabaseObject {
        DatabaseObject(
            id: "\(schema ?? "-")/\(kind.rawValue)/\(name)",
            name: name,
            kind: kind,
            schema: schema
        )
    }

    private func mixedChildren() -> [DatabaseObject] {
        [
            object("orders", kind: .table),
            object("customers", kind: .table),
            object("active_orders", kind: .view),
            object("orders_id_seq", kind: .sequence),
            object("archive_orders", kind: .function)
        ]
    }

    // MARK: - 分组

    func testGroupsByKindInPreferredOrder() {
        // 故意打乱输入顺序：分组顺序应当由类型决定，而不是输入顺序。
        let groups = ObjectTreeGrouping.groupedByType(
            [
                object("archive_orders", kind: .function),
                object("orders_id_seq", kind: .sequence),
                object("active_orders", kind: .view),
                object("orders", kind: .table)
            ],
            parentID: "db/appdb/schema/public"
        )

        XCTAssertEqual(groups.map(\.kind), [.table, .view, .sequence, .function])
        XCTAssertEqual(groups.map(\.count), [1, 1, 1, 1])
    }

    func testEmptyInputYieldsNoGroups() {
        XCTAssertTrue(ObjectTreeGrouping.groupedByType([]).isEmpty)
    }

    /// 组内保持传入顺序（不额外排序，避免把服务端给的顺序打乱）。
    func testObjectsKeepInputOrderWithinGroup() {
        let groups = ObjectTreeGrouping.groupedByType(mixedChildren())

        XCTAssertEqual(groups.first?.objects.map(\.name), ["orders", "customers"])
    }

    func testGroupIDsAreStableAndIncludeParent() {
        let first = ObjectTreeGrouping.groupedByType(mixedChildren(), parentID: "schema/a")
        let second = ObjectTreeGrouping.groupedByType(mixedChildren(), parentID: "schema/a")
        let otherParent = ObjectTreeGrouping.groupedByType(mixedChildren(), parentID: "schema/b")

        XCTAssertEqual(first.map(\.id), second.map(\.id), "同一输入应当得到相同的分组 id")
        XCTAssertNotEqual(first.map(\.id), otherParent.map(\.id), "不同父节点的分组 id 必须不同，否则扁平化行会撞 id")
    }

    /// 未在优先类型里的对象归入「其他」兜底分组，不会丢失。
    func testUnknownKindsGoToFallbackGroup() {
        let groups = ObjectTreeGrouping.groupedByType([
            object("orders", kind: .table),
            object("appdb", kind: .database, schema: nil),
            object("pg_catalog", kind: .schema, schema: nil)
        ])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[1].kind, nil)
        XCTAssertEqual(groups[1].count, 2)
        XCTAssertEqual(
            ObjectTreeGrouping.headerKind(for: groups[1].kind),
            .column,
            "「其他」分组用中性图标"
        )
    }

    func testAllObjectsArePreserved() {
        let children = mixedChildren()
        let flattened = ObjectTreeGrouping.groupedByType(children).flatMap(\.objects)

        XCTAssertEqual(flattened.count, children.count)
        XCTAssertEqual(Set(flattened.map(\.id)), Set(children.map(\.id)))
    }

    // MARK: - schema 归属

    func testSchemasAreCollectedSortedAndDeduplicated() {
        let groups = ObjectTreeGrouping.groupedByType([
            object("orders", kind: .table, schema: "sales"),
            object("orders", kind: .table, schema: "public"),
            object("more_orders", kind: .table, schema: "sales"),
            object("no_schema", kind: .table, schema: nil)
        ])

        XCTAssertEqual(groups[0].schemas, ["public", "sales"], "去重并升序")
    }

    /// 跨 schema 时行上补 `schema.` 前缀，避免同名对象看起来一样。
    func testDisplayNameIsQualifiedWhenGroupSpansSchemas() {
        let groups = ObjectTreeGrouping.groupedByType([
            object("orders", kind: .table, schema: "public"),
            object("orders", kind: .table, schema: "sales")
        ])
        let group = groups[0]

        XCTAssertEqual(group.schemas.count, 2)
        XCTAssertEqual(group.displayName(for: group.objects[0]), "public.orders")
        XCTAssertEqual(group.displayName(for: group.objects[1]), "sales.orders")
    }

    /// 单一 schema 时保持原名（不画蛇添足）。
    func testDisplayNameStaysBareForSingleSchema() {
        let groups = ObjectTreeGrouping.groupedByType([
            object("orders", kind: .table),
            object("customers", kind: .table)
        ])

        XCTAssertEqual(groups[0].displayName(for: groups[0].objects[0]), "orders")
    }

    // MARK: - 标题

    func testTitlesFollowLanguage() {
        XCTAssertEqual(ObjectTreeGrouping.title(for: .table, language: .simplifiedChinese), "表")
        XCTAssertEqual(ObjectTreeGrouping.title(for: .table, language: .english), "Tables")
        XCTAssertEqual(ObjectTreeGrouping.title(for: .view, language: .simplifiedChinese), "视图")
        XCTAssertEqual(ObjectTreeGrouping.title(for: .sequence, language: .simplifiedChinese), "序列")
        XCTAssertEqual(ObjectTreeGrouping.title(for: .function, language: .simplifiedChinese), "函数")
        XCTAssertEqual(ObjectTreeGrouping.title(for: nil, language: .simplifiedChinese), "其他")
        XCTAssertEqual(ObjectTreeGrouping.title(for: nil, language: .english), "Other")
        // 兜底类型也必须有文案，不能返回空串。
        XCTAssertFalse(ObjectTreeGrouping.title(for: .server, language: .simplifiedChinese).isEmpty)
    }

    func testGroupTitleUsesPreferredLanguage() {
        let groups = ObjectTreeGrouping.groupedByType(
            [object("orders", kind: .table)],
            language: .english
        )

        XCTAssertEqual(groups[0].title(language: .english), "Tables")
    }

    // MARK: - 视图切换不重新查库

    /// 分组是纯函数：对同一份缓存反复分组结果一致，且不修改输入。
    func testGroupingIsPureAndRepeatable() {
        let children = mixedChildren()
        let snapshot = children

        let first = ObjectTreeGrouping.groupedByType(children, parentID: "p")
        let second = ObjectTreeGrouping.groupedByType(children, parentID: "p")

        XCTAssertEqual(first, second)
        XCTAssertEqual(children, snapshot, "分组不应修改调用方的缓存")
    }

    /// sequence 是新增的对象类型，必须参与分组而不是被当成「其他」。
    func testSequenceIsAGroupOfItsOwn() {
        let groups = ObjectTreeGrouping.groupedByType([
            object("orders_id_seq", kind: .sequence),
            object("orders", kind: .table)
        ])

        XCTAssertEqual(groups.map(\.kind), [.table, .sequence])
    }
}

/// 新增 `sequence` 类型后，`DatabaseObject` 的类型行为必须自洽。
final class DatabaseObjectKindTests: XCTestCase {

    func testSequenceKindBehaviour() {
        let sequence = DatabaseObject(id: "s", name: "orders_id_seq", kind: .sequence)

        XCTAssertFalse(sequence.isExpandable, "序列没有子节点")
        XCTAssertEqual(sequence.symbolName, "number")
    }

    func testSequenceKindIsCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let restored = try decoder.decode(
            DatabaseObject.Kind.self,
            from: try encoder.encode(DatabaseObject.Kind.sequence)
        )

        XCTAssertEqual(restored, .sequence)
        XCTAssertEqual(DatabaseObject.Kind.sequence.rawValue, "sequence")
    }
}
