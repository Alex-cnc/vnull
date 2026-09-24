import XCTest
@testable import DoyahCore

/// 结果集内联编辑的**草稿层**（FR-DATA-04 的界面状态）。
///
/// 界面上的双击 / 右键没法脚本化，但"改动怎么攒、怎么交给 `InlineEdit.plan`"是纯逻辑，
/// 而它恰好是这一项最容易出欺骗性结果的地方（同一行既改又删 → 预览里看不出问题；
/// 行号在翻页之后指向另一行 → 改动落到别人身上）。
final class InlineEditDraftTests: XCTestCase {

    private let keyRow: [String?] = ["1", "paid"]

    func testEmptyDraftProducesNoChanges() {
        let draft = InlineEditDraft()
        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(draft.changeCount, 0)
        XCTAssertTrue(draft.changes().isEmpty)
        XCTAssertTrue(draft.planInput().rows.isEmpty)
    }

    func testSameCellKeepsLastValue() {
        var draft = InlineEditDraft()
        draft.setValue(.text("a"), row: 0, column: "note", rowValues: keyRow)
        draft.setValue(.text("b"), row: 0, column: "note", rowValues: keyRow)

        XCTAssertEqual(draft.pendingValue(row: 0, column: "note"), .text("b"))
        XCTAssertEqual(draft.changes(), [.update(rowIndex: 0, column: "note", value: .text("b"))])
        XCTAssertEqual(draft.changeCount, 1)
    }

    /// 一行不能同时"改了"和"删了"：删除优先，且删除会清掉该行的改值。
    func testDeleteBeatsUpdateOnTheSameRow() {
        var draft = InlineEditDraft()
        draft.setValue(.text("x"), row: 3, column: "note", rowValues: keyRow)
        draft.markDeleted(row: 3, rowValues: keyRow)

        XCTAssertTrue(draft.isDeleted(row: 3))
        XCTAssertNil(draft.pendingValue(row: 3, column: "note"))
        XCTAssertEqual(draft.changes(), [.delete(rowIndex: 0)])
        XCTAssertEqual(draft.planInput().rows, [keyRow])
    }

    /// 反过来：对已标记删除的行改值 = 撤销删除（用户既然改了它，就不是要删它）。
    func testEditingADeletedRowUnmarksTheDeletion() {
        var draft = InlineEditDraft()
        draft.markDeleted(row: 1, rowValues: keyRow)
        draft.setValue(.text("y"), row: 1, column: "note", rowValues: keyRow)

        XCTAssertFalse(draft.isDeleted(row: 1))
        XCTAssertEqual(draft.changes(), [.update(rowIndex: 0, column: "note", value: .text("y"))])
    }

    func testUnmarkDeletedDropsTheSnapshot() {
        var draft = InlineEditDraft()
        draft.markDeleted(row: 2, rowValues: keyRow)
        draft.unmarkDeleted(row: 2)

        XCTAssertTrue(draft.isEmpty)
        XCTAssertTrue(draft.planInput().rows.isEmpty)
    }

    /// changes() 的顺序必须稳定：行号升序 → 列名升序 → 删除 → 新增（保持添加顺序）。
    func testChangeOrderIsStable() {
        var draft = InlineEditDraft()
        draft.appendInsert(["id": .number("9")])
        draft.markDeleted(row: 5, rowValues: ["5", "x"])
        draft.setValue(.text("b"), row: 2, column: "note", rowValues: ["2", "y"])
        draft.setValue(.text("a"), row: 2, column: "kind", rowValues: ["2", "y"])
        draft.setValue(.text("c"), row: 0, column: "note", rowValues: ["0", "z"])

        XCTAssertEqual(draft.changes(), [
            .update(rowIndex: 0, column: "note", value: .text("c")),
            .update(rowIndex: 1, column: "kind", value: .text("a")),
            .update(rowIndex: 1, column: "note", value: .text("b")),
            .delete(rowIndex: 2),
            .insert(values: ["id": .number("9")])
        ])
        XCTAssertEqual(draft.changeCount, 5)
    }

    /// 口径 4：提交用的是**改动发生时**那一行的快照，并按快照重排行号 ——
    /// 行号只是"当时界面上的位置"，翻页 / 排序之后它已经不是同一行了。
    func testPlanInputUsesSnapshotsAndRemapsRowIndexes() {
        var draft = InlineEditDraft()
        // 用户在第 1 页改了显示第 3 行（主键 30）……
        draft.setValue(.text("x"), row: 3, column: "note", rowValues: ["30", "old"])
        // ……翻到第 2 页又改了显示第 0 行（主键 71）。
        draft.setValue(.text("y"), row: 0, column: "note", rowValues: ["71", "old2"])

        let input = draft.planInput()
        // 按显示行号升序：第 0 行（主键 71）在前，第 3 行（主键 30）在后。
        XCTAssertEqual(input.rows, [["71", "old2"], ["30", "old"]], "行按改动快照带过去，不是当前页的行")
        XCTAssertEqual(input.changes, [
            .update(rowIndex: 0, column: "note", value: .text("y")),
            .update(rowIndex: 1, column: "note", value: .text("x"))
        ])

        // 拿这份输入真的生成一次 DML：WHERE 必须落在**快照里的主键**上。
        let plan = InlineEdit.plan(
            table: "items",
            columnNames: ["id", "note"],
            columns: [
                InlineEdit.Column(name: "id", typeName: "integer", isPrimaryKey: true, isNullable: false),
                InlineEdit.Column(name: "note", typeName: "text", isPrimaryKey: false, isNullable: true)
            ],
            rows: input.rows,
            changes: input.changes,
            dialect: PostgresDialect()
        )
        XCTAssertEqual(plan.statements, [
            "UPDATE \"items\" SET \"note\" = 'y' WHERE \"id\" = 71",
            "UPDATE \"items\" SET \"note\" = 'x' WHERE \"id\" = 30"
        ])
    }

    func testRemoveInsertAndDiscard() {
        var draft = InlineEditDraft()
        draft.appendInsert(["id": .number("1")])
        draft.appendInsert(["id": .number("2")])
        draft.removeInsert(at: 0)
        XCTAssertEqual(draft.insertedRows, [["id": .number("2")]])
        draft.removeInsert(at: 7) // 越界不崩、不改任何东西
        XCTAssertEqual(draft.insertedRows.count, 1)

        draft.discard()
        XCTAssertTrue(draft.isEmpty)
    }

    // MARK: - 文本 → 值

    /// NULL 与空串是两种东西（单元格编辑）：空文本是**空串**，`NULL` 才是空值。
    func testCellParsingDistinguishesNullFromEmptyString() {
        XCTAssertEqual(InlineEdit.Value.parsed("NULL", typeName: "text"), .null)
        XCTAssertEqual(InlineEdit.Value.parsed("null", typeName: "text"), .null)
        XCTAssertEqual(InlineEdit.Value.parsed("", typeName: "text"), .text(""))
        XCTAssertEqual(InlineEdit.Value.parsed("abc", typeName: "text"), .text("abc"))
    }

    func testCellParsingFollowsColumnType() {
        XCTAssertEqual(InlineEdit.Value.parsed("42", typeName: "integer"), .number("42"))
        XCTAssertEqual(InlineEdit.Value.parsed("4.5", typeName: "numeric(8,2)"), .number("4.5"))
        XCTAssertEqual(InlineEdit.Value.parsed("42", typeName: "text"), .text("42"))
        XCTAssertEqual(InlineEdit.Value.parsed("true", typeName: "boolean"), .boolean(true))
        XCTAssertEqual(InlineEdit.Value.parsed("f", typeName: "bool"), .boolean(false))
        // 类型是数字但内容不是数字：按文本走，别把它硬塞成数字（数据库会给出真实报错）
        XCTAssertEqual(InlineEdit.Value.parsed("abc", typeName: "integer"), .text("abc"))
        // 布尔列上写了不认识的内容：同样不猜
        XCTAssertEqual(InlineEdit.Value.parsed("maybe", typeName: "boolean"), .text("maybe"))
    }

    /// 追加行：**空文本 = 不写这一列**（交给默认值），`''` = 写空串，`NULL` = 空值。
    func testInsertParsingUsesNilForUnsetColumns() {
        XCTAssertNil(InlineEdit.Value.parsedForInsert("", typeName: "text"))
        XCTAssertNil(InlineEdit.Value.parsedForInsert("   ", typeName: "text"))
        XCTAssertEqual(InlineEdit.Value.parsedForInsert("''", typeName: "text"), .text(""))
        XCTAssertEqual(InlineEdit.Value.parsedForInsert("NULL", typeName: "text"), .null)
        XCTAssertEqual(InlineEdit.Value.parsedForInsert("7", typeName: "bigint"), .number("7"))
    }

    func testDisplayText() {
        XCTAssertEqual(InlineEdit.Value.null.displayText, "NULL")
        XCTAssertEqual(InlineEdit.Value.text("").displayText, "")
        XCTAssertEqual(InlineEdit.Value.number("3").displayText, "3")
        XCTAssertEqual(InlineEdit.Value.boolean(true).displayText, "TRUE")
        XCTAssertEqual(InlineEdit.Value.boolean(false).displayText, "FALSE")
    }

    /// 草稿最终交给 `InlineEdit.plan` 时，无主键表必须被拒绝（而不是退化成"整行相等"）。
    func testDraftFeedsPlanAndNoPrimaryKeyIsRefused() {
        var draft = InlineEditDraft()
        draft.setValue(.text("z"), row: 0, column: "a", rowValues: ["x", "y"])
        let input = draft.planInput()
        let plan = InlineEdit.plan(
            table: "logs",
            columnNames: ["a", "b"],
            columns: [
                InlineEdit.Column(name: "a", typeName: "text", isPrimaryKey: false, isNullable: true),
                InlineEdit.Column(name: "b", typeName: "text", isPrimaryKey: false, isNullable: true)
            ],
            rows: input.rows,
            changes: input.changes,
            dialect: PostgresDialect()
        )
        XCTAssertTrue(plan.statements.isEmpty)
        XCTAssertFalse(plan.refusals.isEmpty)
        XCTAssertFalse(plan.isApplicable)
    }
}
