import XCTest
@testable import DoyahCore

/// ER 图（FR-DDL-05）：归一化、分层布局、走线、文本导出与数据来源解析。
///
/// 布局是纯计算，所以这里钉住的是**确定性**与**不重叠**这两件能被机器判的事 ——
/// 「好不好看」留人工，但「每次都乱跳」「两张表叠在一起」不该靠肉眼发现。
final class ERDiagramTests: XCTestCase {

    private func table(_ name: String, schema: String? = "public", columns: [(String, String, Bool)] = []) -> ERDiagram.Table {
        ERDiagram.Table(
            schema: schema,
            name: name,
            columns: columns.map { ERDiagram.Column(name: $0.0, typeName: $0.1, isPrimaryKey: $0.2) }
        )
    }

    private func relationship(
        _ from: String,
        _ fromColumns: [String],
        to toTable: String,
        _ toColumns: [String],
        name: String? = nil,
        schema: String? = "public"
    ) -> ERDiagram.Relationship {
        ERDiagram.Relationship(
            name: name,
            from: ERDiagram.Endpoint(schema: schema, table: from, columns: fromColumns),
            to: ERDiagram.Endpoint(schema: schema, table: toTable, columns: toColumns)
        )
    }

    /// 一个典型的订单模型：customers ← orders ← order_items，另有一张孤立表。
    private func shop() -> ERDiagram {
        ERDiagram.build(
            tables: [
                table("customers", columns: [("id", "integer", true), ("name", "text", false)]),
                table("orders", columns: [("id", "integer", true), ("customer_id", "integer", false)]),
                table("order_items", columns: [("order_id", "integer", false), ("sku", "text", false)]),
                table("audit_log", columns: [("id", "bigint", true)]),
            ],
            relationships: [
                relationship("orders", ["customer_id"], to: "customers", ["id"], name: "orders_customer_id_fkey"),
                relationship("order_items", ["order_id"], to: "orders", ["id"], name: "order_items_order_id_fkey"),
            ]
        )
    }

    // MARK: - 归一化

    func testBuildSortsAndDeduplicates() {
        let diagram = ERDiagram.build(
            tables: [table("b"), table("a"), table("a")],
            relationships: [
                relationship("b", ["a_id"], to: "a", ["id"], name: "fk1"),
                relationship("b", ["a_id"], to: "a", ["id"], name: "fk1"),
            ]
        )
        XCTAssertEqual(diagram.tables.map(\.name), ["a", "b"], "表按限定名稳定排序")
        XCTAssertEqual(diagram.tables.count, 2, "同一张表给两次要合并，不能出现两个节点")
        XCTAssertEqual(diagram.relationships.count, 1, "同一条外键只保留一次")
    }

    /// 关系里出现、但没给列定义的表要补成桩节点 —— 丢掉的话图上会凭空少一条外键。
    func testMissingReferencedTableBecomesStub() {
        let diagram = ERDiagram.build(
            tables: [table("orders", columns: [("id", "integer", true)])],
            relationships: [relationship("orders", ["customer_id"], to: "customers", ["id"], name: "fk")],
        )
        XCTAssertEqual(diagram.tables.map(\.name), ["customers", "orders"].sorted())
        let customers = diagram.tables.first { $0.name == "customers" }
        XCTAssertEqual(customers?.isStub, true)
        XCTAssertEqual(customers?.columns.map(\.name), ["id"])
    }

    func testForeignKeyColumnsAreMarked() {
        let diagram = shop()
        let orders = try? XCTUnwrap(diagram.tables.first { $0.name == "orders" })
        XCTAssertEqual(orders?.columns.first { $0.name == "customer_id" }?.isForeignKey, true)
        XCTAssertEqual(orders?.columns.first { $0.name == "id" }?.isPrimaryKey, true)
    }

    // MARK: - 布局

    func testLayeringPutsReferencedTablesOnTop() {
        let layout = shop().layout()
        XCTAssertEqual(layout.node(for: "public.customers")?.layer, 0)
        XCTAssertEqual(layout.node(for: "public.orders")?.layer, 1)
        XCTAssertEqual(layout.node(for: "public.order_items")?.layer, 2)
        XCTAssertEqual(layout.node(for: "public.audit_log")?.layer, 0, "孤立表与时同层（不依赖别人）")
    }

    func testLayoutIsDeterministic() {
        let first = shop().layout()
        let second = shop().layout()
        XCTAssertEqual(first, second, "同一份输入必须给出同一份布局（否则每次打开位置都在跳）")
        XCTAssertEqual(shop().mermaid(), shop().mermaid())
        XCTAssertEqual(shop().dot(), shop().dot())
        XCTAssertEqual(shop().json(), shop().json())
    }

    func testNodesInSameLayerDoNotOverlap() {
        let layout = shop().layout()
        let sameLayer = layout.nodes.filter { $0.layer == 0 }.sorted { $0.x < $1.x }
        for (left, right) in zip(sameLayer, sameLayer.dropFirst()) {
            XCTAssertLessThanOrEqual(left.x + left.width, right.x, "同层节点不能重叠")
        }
        // 层与层之间也不能压在一起。
        let layers: [Int: [ERDiagram.Layout.Node]] = Dictionary(grouping: layout.nodes) { $0.layer }
        let ordered = layers.keys.sorted()
        for (upper, lower) in zip(ordered, ordered.dropFirst()) {
            let upperBottom = (layers[upper] ?? []).map(\.bottomY).max() ?? 0
            let lowerTop = (layers[lower] ?? []).map(\.y).min() ?? 0
            XCTAssertLessThanOrEqual(upperBottom, lowerTop, "第 \(upper) 层与第 \(lower) 层重叠了")
        }
    }

    func testNodeHeightGrowsWithColumnsAndCapsVeryWideTables() {
        let narrow = ERDiagram.build(tables: [table("t", columns: [("a", "int", false)])], relationships: [])
        let wide = ERDiagram.build(
            tables: [table("t", columns: (0..<40).map { ("c\($0)", "int", false) })],
            relationships: []
        )
        let short = narrow.layout().node(for: "public.t")
        let capped = wide.layout().node(for: "public.t")
        XCTAssertLessThan(short?.height ?? 0, capped?.height ?? 0, "列多则更高")
        XCTAssertLessThan(capped?.height ?? 0, 34 + 40 * 18, "超宽表要截断显示（否则一张表吃掉整屏）")
    }

    /// 环（互相引用）：不死循环，成环的表被点名并放到最后一层。
    func testCyclesDoNotHangAndAreReported() {
        let diagram = ERDiagram.build(
            tables: [table("a"), table("b"), table("c")],
            relationships: [
                relationship("a", ["b_id"], to: "b", ["id"], name: "a_b"),
                relationship("b", ["a_id"], to: "a", ["id"], name: "b_a"),
                relationship("c", ["id"], to: "c", ["id"], name: "c_self"),
            ]
        )
        let layout = diagram.layout()
        XCTAssertEqual(layout.nodes.count, 3, "每张表都要有节点")
        XCTAssertEqual(layout.cyclicTables, ["public.a", "public.b", "public.c"], "成环与自引用的表要点名")
        XCTAssertGreaterThan(layout.node(for: "public.a")?.layer ?? -1, 0, "成环的表排到后面，不占在第 0 层")
    }

    func testSelfReferenceIsRoutedOutsideTheNode() {
        let diagram = ERDiagram.build(
            tables: [table("category")],
            relationships: [relationship("category", ["parent_id"], to: "category", ["id"], name: "category_parent")]
        )
        let layout = diagram.layout()
        let edge = try? XCTUnwrap(layout.edges.first)
        XCTAssertEqual(edge?.isSelfReference, true)
        let node = try? XCTUnwrap(layout.node(for: "public.category"))
        // 走线必须从节点右侧出（绕出去），不能压在节点里。
        XCTAssertEqual(edge?.start.x, (node?.x ?? 0) + (node?.width ?? 0))
    }

    func testEdgeRoutingDirection() {
        let layout = shop().layout()
        let edge = layout.edges.first { $0.fromTable == "public.order_items" && $0.toTable == "public.orders" }
        let child = layout.node(for: "public.order_items")
        let parent = layout.node(for: "public.orders")
        XCTAssertEqual(edge?.start.x, child?.centerX)
        XCTAssertEqual(edge?.start.y, child?.y)
        XCTAssertEqual(edge?.end.x, parent?.centerX)
        XCTAssertEqual(edge?.end.y, parent?.bottomY)
    }

    // MARK: - 导出

    func testMermaidExport() {
        let mermaid = shop().mermaid()
        XCTAssertTrue(mermaid.hasPrefix("erDiagram\n"))
        XCTAssertTrue(mermaid.contains("public_orders {"), "实体名要净化成可渲染的写法：\n\(mermaid)")
        XCTAssertTrue(mermaid.contains("%% public.orders"), "注释里保留真实限定名")
        XCTAssertTrue(mermaid.contains("integer id PK"))
        XCTAssertTrue(mermaid.contains("integer customer_id FK"))
        // 关系行：**父在左**，一个父对应零到多个子。
        XCTAssertTrue(
            mermaid.contains("public_customers ||--o{ public_orders : \"orders_customer_id_fkey\""),
            "关系行不对：\n\(mermaid)"
        )
        awaitDrain(mermaid)
    }

    /// 类型里的空格 / 括号要清掉，否则 Mermaid 的 `类型 名字` 会解析失败。
    func testMermaidSanitizesTypes() {
        let diagram = ERDiagram.build(
            tables: [table("t", columns: [("name", "character varying(20)", false)])],
            relationships: []
        )
        let mermaid = diagram.mermaid()
        XCTAssertTrue(mermaid.contains("character_varying name"), mermaid)
        XCTAssertFalse(mermaid.contains("(20)"))
    }

    func testDOTExport() {
        let dot = shop().dot()
        XCTAssertTrue(dot.hasPrefix("digraph er {"))
        XCTAssertTrue(dot.contains("\"public.order_items\" -> \"public.orders\""))
        XCTAssertTrue(dot.contains("arrowhead=crow"))
        XCTAssertTrue(dot.hasSuffix("}\n"))
    }

    func testJSONExportIsParsable() throws {
        let data = Data(shop().json().utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tables = try XCTUnwrap(object?["tables"] as? [[String: Any]])
        let relationships = try XCTUnwrap(object?["relationships"] as? [[String: Any]])
        XCTAssertEqual(tables.count, 4)
        XCTAssertEqual(relationships.count, 2)
        XCTAssertEqual(relationships.first?["from"] as? String, "public.order_items")
        XCTAssertEqual(relationships.first?["to"] as? String, "public.orders")
    }

    // MARK: - 数据来源

    /// 外键查询结果 → 关系：复合外键要**按 position 拼成一对列**，不能错配。
    func testCompositeForeignKeyParsing() {
        let result = QueryResult(
            columns: (0..<10).map { ColumnMeta(id: $0, name: "c\($0)") },
            rows: [
                ["order_fk", "line", "public", "order_id", "orders", "public", "id", "c", "a", "1"],
                // 第 2 列故意先出现（模拟行序）：解析必须按 position 排序。
                ["pair_fk", "child", "public", "b", "parent", "public", "y", "a", "a", "2"],
                ["pair_fk", "child", "public", "a", "parent", "public", "x", "a", "a", "1"],
            ]
        )
        let relationships = ERDiagramSource.relationships(from: result)
        XCTAssertEqual(relationships.count, 2)
        let composite = try? XCTUnwrap(relationships.first { $0.name == "pair_fk" })
        XCTAssertEqual(composite?.from.columns, ["a", "b"], "列序必须按 position，不能按行序")
        XCTAssertEqual(composite?.to.columns, ["x", "y"])
        XCTAssertEqual(composite?.isComposite, true)
        // 引用动作编码：c = CASCADE、a = NO ACTION。
        let single = try? XCTUnwrap(relationships.first { $0.name == "order_fk" })
        XCTAssertEqual(single?.onDelete, "CASCADE")
        XCTAssertEqual(single?.onUpdate, "NO ACTION")
    }

    func testForeignKeyQueryTargetsTheSchema() {
        let sql = ERDiagramSource.foreignKeysQuery(schema: "sales")
        XCTAssertTrue(sql.contains("child_ns.nspname = 'sales'"))
        XCTAssertTrue(sql.contains("con.contype = 'f'"))
        XCTAssertTrue(sql.contains("generate_subscripts"))
        // 引号里的单引号要转义（schema 名理论上可以带单引号）。
        XCTAssertTrue(ERDiagramSource.foreignKeysQuery(schema: "o'brien").contains("'o''brien'"))
    }

    func testTablesFromSnapshots() {
        let snapshot = TableSnapshot(
            schema: "public",
            name: "orders",
            columns: [
                TableColumnDefinition(name: "id", typeName: "integer", isNullable: false, defaultValue: "", isPrimaryKey: true),
                TableColumnDefinition(name: "note", typeName: "text", isNullable: true, defaultValue: "", isPrimaryKey: false),
            ]
        )
        let tables = ERDiagramSource.tables(from: [snapshot])
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].qualifiedName, "public.orders")
        XCTAssertEqual(tables[0].columns.map(\.isPrimaryKey), [true, false])
    }

    func testEmptyDiagramIsEmptyNotCrash() {
        let diagram = ERDiagram.build(tables: [], relationships: [])
        XCTAssertTrue(diagram.isEmpty)
        XCTAssertEqual(diagram.layout().nodes.count, 0)
        XCTAssertTrue(diagram.mermaid().hasPrefix("erDiagram"))
    }

    /// 只为了让上面的断言在失败时打印全文（避免超长输出被截断后看不懂）。
    private func awaitDrain(_ text: String) { _ = text }
}
