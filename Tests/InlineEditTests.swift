import XCTest
@testable import DoyahCore

/// 结果集内联编辑（FR-DATA-04）：把改动翻译成将要执行的 DML。
///
/// 这一项的危险点不在"能不能拼出 UPDATE"，而在**拼错时无人察觉**：
/// 少一个主键条件就是全表更新，NULL 写成空串会静默改掉语义，
/// 所以下面的用例主要盯这三件事。
final class InlineEditTests: XCTestCase {

    private let dialect: SQLDialect = SQLDialectFactory.make(for: .postgresql)

    private var columns: [InlineEdit.Column] {
        [
            InlineEdit.Column(name: "id", typeName: "integer", isPrimaryKey: true, isNullable: false),
            InlineEdit.Column(name: "status", typeName: "text", isPrimaryKey: false, isNullable: true),
            InlineEdit.Column(name: "note", typeName: "text", isPrimaryKey: false, isNullable: true)
        ]
    }

    private var rows: [[String?]] { [["7", "paid", "hello"]] }
    private let columnNames = ["id", "status", "note"]

    private func makePlan(_ changes: [InlineEdit.Change], rows: [[String?]]? = nil) -> InlineEdit.Plan {
        InlineEdit.plan(
            table: "orders",
            schema: "public",
            columnNames: columnNames,
            columns: columns,
            rows: rows ?? self.rows,
            changes: changes,
            dialect: dialect
        )
    }

    // MARK: 定位行（设计要点 1）

    func testUpdateTargetsRowByPrimaryKey() {
        let plan = makePlan([.update(rowIndex: 0, column: "status", value: .text("refunded"))])
        XCTAssertEqual(plan.statements, [
            "UPDATE \"public\".\"orders\" SET \"status\" = 'refunded' WHERE \"id\" = 7"
        ])
        XCTAssertTrue(plan.isApplicable)
    }

    /// 数字主键**不加引号**（加了会让索引失效，甚至类型不匹配报错）。
    func testNumericPrimaryKeyIsUnquoted() {
        let plan = makePlan([.delete(rowIndex: 0)])
        XCTAssertEqual(plan.statements, ["DELETE FROM \"public\".\"orders\" WHERE \"id\" = 7"])
    }

    func testCompositePrimaryKeyJoinsWithAnd() {
        let composite = [
            InlineEdit.Column(name: "tenant", typeName: "text", isPrimaryKey: true, isNullable: false),
            InlineEdit.Column(name: "id", typeName: "integer", isPrimaryKey: true, isNullable: false),
            InlineEdit.Column(name: "status", typeName: "text", isPrimaryKey: false, isNullable: true)
        ]
        let plan = InlineEdit.plan(
            table: "orders",
            schema: nil,
            columnNames: ["tenant", "id", "status"],
            columns: composite,
            rows: [["acme", "7", "paid"]],
            changes: [.update(rowIndex: 0, column: "status", value: .text("void"))],
            dialect: dialect
        )
        XCTAssertEqual(plan.statements, [
            "UPDATE \"orders\" SET \"status\" = 'void' WHERE \"tenant\" = 'acme' AND \"id\" = 7"
        ])
    }

    /// **没有主键就拒绝**，而不是退化成"所有列都相等"（那会一次改掉多行）。
    func testRefusesWhenTableHasNoPrimaryKey() {
        let noKey = [
            InlineEdit.Column(name: "a", typeName: "text", isPrimaryKey: false, isNullable: true),
            InlineEdit.Column(name: "b", typeName: "text", isPrimaryKey: false, isNullable: true)
        ]
        let plan = InlineEdit.plan(
            table: "logs",
            schema: nil,
            columnNames: ["a", "b"],
            columns: noKey,
            rows: [["x", "y"]],
            changes: [.update(rowIndex: 0, column: "a", value: .text("z"))],
            dialect: dialect
        )
        XCTAssertFalse(plan.isApplicable)
        XCTAssertTrue(plan.statements.isEmpty, "拒绝时不该产出任何语句")
        XCTAssertTrue(plan.refusals.contains { $0.contains("没有主键") }, "\(plan.refusals)")
    }

    func testPrimaryKeyNullIsRefused() {
        let plan = makePlan([.delete(rowIndex: 0)], rows: [[nil, "paid", "hello"]])
        XCTAssertFalse(plan.isApplicable)
        XCTAssertTrue(plan.refusals.contains { $0.contains("主键") && $0.contains("为空") }, "\(plan.refusals)")
    }

    func testOutOfRangeRowIsRefused() {
        let plan = makePlan([.delete(rowIndex: 5)])
        XCTAssertFalse(plan.isApplicable)
        XCTAssertTrue(plan.refusals.contains { $0.contains("不在当前结果集") }, "\(plan.refusals)")
    }

    // MARK: NULL 与空串（设计要点 2）

    func testNullAndEmptyStringRenderDifferently() {
        let nullPlan = makePlan([.update(rowIndex: 0, column: "note", value: .null)])
        XCTAssertEqual(nullPlan.statements, [
            "UPDATE \"public\".\"orders\" SET \"note\" = NULL WHERE \"id\" = 7"
        ])
        let emptyPlan = makePlan([.update(rowIndex: 0, column: "note", value: .text(""))])
        XCTAssertEqual(emptyPlan.statements, [
            "UPDATE \"public\".\"orders\" SET \"note\" = '' WHERE \"id\" = 7"
        ])
    }

    func testTextEscapesSingleQuote() {
        let plan = makePlan([.update(rowIndex: 0, column: "note", value: .text("O'Brien"))])
        XCTAssertTrue(plan.statements[0].contains("'O''Brien'"), plan.statements[0])
    }

    /// NOT NULL 列写成 NULL → 拒绝（别等数据库报错，那时整批已经跑了一半）。
    func testNullForNotNullColumnIsRefused() {
        let plan = makePlan([.update(rowIndex: 0, column: "id", value: .null)])
        XCTAssertFalse(plan.isApplicable)
        XCTAssertTrue(plan.refusals.contains { $0.contains("不允许为空") }, "\(plan.refusals)")
    }

    // MARK: 新增 / 删除 / 顺序

    func testInsertRendersColumnsAndValues() {
        let plan = makePlan([.insert(values: ["status": .text("new"), "note": .null])])
        XCTAssertEqual(plan.statements, [
            "INSERT INTO \"public\".\"orders\" (\"note\", \"status\") VALUES (NULL, 'new')"
        ])
    }

    /// 同一格改两次：**以最后一次为准**（否则预览里有两条 UPDATE，用户以为两条都会跑）。
    func testLastChangeToOneCellWins() {
        let plan = makePlan([
            .update(rowIndex: 0, column: "status", value: .text("a")),
            .update(rowIndex: 0, column: "status", value: .text("b"))
        ])
        XCTAssertEqual(plan.statements.count, 1)
        XCTAssertTrue(plan.statements[0].contains("'b'"), plan.statements[0])
    }

    func testStatementOrderIsStable() {
        let plan = makePlan([
            .delete(rowIndex: 0),
            .insert(values: ["status": .text("x")]),
            .update(rowIndex: 0, column: "note", value: .text("n"))
        ])
        XCTAssertEqual(plan.statements.count, 3)
        XCTAssertTrue(plan.statements[0].hasPrefix("UPDATE"), "更新在前：\(plan.statements)")
        XCTAssertTrue(plan.statements[1].hasPrefix("DELETE"), "删除其次：\(plan.statements)")
        XCTAssertTrue(plan.statements[2].hasPrefix("INSERT"), "新增最后：\(plan.statements)")
        // 同一输入两次生成必须完全一致
        XCTAssertEqual(plan, makePlan([.delete(rowIndex: 0), .insert(values: ["status": .text("x")]), .update(rowIndex: 0, column: "note", value: .text("n"))]))
    }

    func testUnknownColumnIsRefused() {
        let plan = makePlan([.update(rowIndex: 0, column: "nope", value: .text("x"))])
        XCTAssertFalse(plan.isApplicable)
        XCTAssertTrue(plan.refusals.contains { $0.contains("没有这一列") }, "\(plan.refusals)")
    }

    /// 预览文本：能执行时是语句列表，不能执行时是理由（**同一份来源**，界面与 CLI 都读它）。
    func testPreviewShowsStatementsOrRefusals() {
        let ok = makePlan([.update(rowIndex: 0, column: "status", value: .text("paid"))])
        XCTAssertTrue(ok.preview.contains("UPDATE"), ok.preview)
        let refused = makePlan([.update(rowIndex: 9, column: "status", value: .text("paid"))])
        XCTAssertTrue(refused.preview.hasPrefix("⚠️"), refused.preview)
    }
}
