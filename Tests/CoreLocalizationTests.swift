import XCTest
@testable import DoyahCore

/// Core 生成的**展示文本**要能按语言出（FR-DATA-04 / R-45）。
///
/// 这类文本以前硬编码中文：界面把英文用户的拒绝理由、单元格摘要原样显示出来，
/// 于是英文界面里混着中文。修法不是"把中文换成英文"（CLI 与中文界面还要中文），
/// 而是**让生成方知道自己该用哪种语言**（默认中文，界面传当前语言）。
final class CoreLocalizationTests: XCTestCase {

    // MARK: - 内联编辑的拒绝理由

    private func plan(language: AppLanguage) -> InlineEdit.Plan {
        // 一张**没有主键**的表 → 必定走"拒绝"分支（正是原先硬编码中文的那段）。
        let columns = [
            InlineEdit.Column(name: "name", typeName: "text", isPrimaryKey: false, isNullable: true),
            InlineEdit.Column(name: "amount", typeName: "numeric", isPrimaryKey: false, isNullable: true),
        ]
        return InlineEdit.plan(
            table: "orders",
            columnNames: ["name", "amount"],
            columns: columns,
            rows: [["alice", "12.5"]],
            changes: [.update(rowIndex: 0, column: "amount", value: .text("13.5"))],
            dialect: PostgresDialect(),
            language: language
        )
    }

    func testInlineEditRefusalsFollowLanguage() {
        let zh = plan(language: .simplifiedChinese)
        let en = plan(language: .english)

        XCTAssertEqual(zh.refusals.count, 2, "无主键要给出两条理由：结论 + 为什么不退化")
        XCTAssertTrue(zh.refusals[0].contains("没有主键"), zh.refusals[0])
        XCTAssertTrue(en.refusals[0].contains("no primary key"), en.refusals[0])
        XCTAssertFalse(en.refusals[0].contains("主键"), "英文界面不该出现中文字：\(en.refusals[0])")
        XCTAssertTrue(en.refusals.joined().contains("primary key"))
    }

    func testInlineEditDefaultsToChinese() {
        let columns = [InlineEdit.Column(name: "name", typeName: "text", isPrimaryKey: false, isNullable: true)]
        let plan = InlineEdit.plan(
            table: "t",
            columnNames: ["name"],
            columns: columns,
            rows: [["x"]],
            changes: [.delete(rowIndex: 0)],
            dialect: PostgresDialect()
        )
        XCTAssertTrue(plan.refusals[0].contains("没有主键"), "默认仍是中文（CLI 与既有调用点不变）")
    }

    /// 主键为空这类理由带**实际值**（行号与列名），两种语言都要带上。
    func testInlineEditRefusalKeepsArguments() {
        let columns = [
            InlineEdit.Column(name: "id", typeName: "integer", isPrimaryKey: true, isNullable: false),
            InlineEdit.Column(name: "name", typeName: "text", isPrimaryKey: false, isNullable: true),
        ]
        let zh = InlineEdit.plan(
            table: "t", columnNames: ["id", "name"], columns: columns,
            rows: [[nil, "alice"]],
            changes: [.update(rowIndex: 0, column: "name", value: .text("bob"))],
            dialect: PostgresDialect(), language: .simplifiedChinese
        )
        XCTAssertTrue(zh.refusals[0].contains("第 1 行"), zh.refusals[0])
        XCTAssertTrue(zh.refusals[0].contains("id"), zh.refusals[0])

        let en = InlineEdit.plan(
            table: "t", columnNames: ["id", "name"], columns: columns,
            rows: [[nil, "alice"]],
            changes: [.update(rowIndex: 0, column: "name", value: .text("bob"))],
            dialect: PostgresDialect(), language: .english
        )
        XCTAssertTrue(en.refusals[0].contains("Row 1"), en.refusals[0])
        XCTAssertTrue(en.refusals[0].contains("id"), en.refusals[0])
    }

    // MARK: - 单元格摘要（R-45）

    func testCellSummaryFollowsLanguage() {
        let value = CellInspector.inspect("line1\nline2")
        let zh = value.summary(language: .simplifiedChinese)
        let en = value.summary(language: .english)

        XCTAssertTrue(zh.contains("字符"), zh)
        XCTAssertTrue(zh.contains("2 行"), zh)
        XCTAssertTrue(en.contains("characters"), en)
        XCTAssertTrue(en.contains("2 lines"), en)
        XCTAssertFalse(en.contains("行"), "英文摘要不该出现中文字：\(en)")
    }

    func testCellSummaryEmptyAndBinary() {
        let empty = CellInspector.inspect("")
        XCTAssertEqual(empty.summary(language: .simplifiedChinese), "空字符串")
        XCTAssertEqual(empty.summary(language: .english), "Empty string")

        let hex = "\\x" + String(repeating: "48", count: 12)
        let binary = CellInspector.inspect(hex)
        XCTAssertTrue(binary.summary(language: .english).contains("Binary"), binary.summary(language: .english))
        XCTAssertTrue(binary.summary(language: .english).contains("12"), binary.summary(language: .english))
    }

    func testCellSummaryDefaultsToChinese() {
        let value = CellInspector.inspect("{}")
        XCTAssertTrue(value.summary().contains("JSON"), value.summary())
    }
}
