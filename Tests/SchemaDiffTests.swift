import XCTest
@testable import DoyahCore

/// Schema 对比与同步（FR-DDL-04）。
///
/// 最危险的地方不是"算不出差异"，而是**默认就把破坏性变更执行了**（删列 / 删表）。
/// 所以下面的用例把"默认只做加法与安全修改、破坏性必须显式开"这条钉死。
final class SchemaDiffTests: XCTestCase {

    private let dialect: SQLDialect = SQLDialectFactory.make(for: .postgresql)

    private func column(
        _ name: String,
        type: String = "text",
        nullable: Bool = true,
        default defaultValue: String = "",
        primaryKey: Bool = false
    ) -> TableColumnDefinition {
        TableColumnDefinition(
            name: name,
            typeName: type,
            isNullable: nullable,
            defaultValue: defaultValue,
            isPrimaryKey: primaryKey
        )
    }

    private func snapshot(_ label: String, _ tables: [(String, [TableColumnDefinition])]) -> SchemaSnapshot {
        SchemaSnapshot(
            label: label,
            tables: tables.map { TableSnapshot(schema: "public", name: $0.0, columns: $0.1) }
        )
    }

    // MARK: 相同

    func testIdenticalSnapshotsHaveNoDiff() {
        let columns = [column("id", type: "integer"), column("note")]
        let left = snapshot("期望", [("orders", columns)])
        let right = snapshot("目标", [("orders", columns)])

        XCTAssertTrue(SchemaDiffer.compare(left: left, right: right).isEmpty)
        let plan = SchemaDiffer.plan(left: left, right: right, dialect: dialect)
        XCTAssertTrue(plan.isIdentical)
        XCTAssertTrue(plan.statements.isEmpty)
        XCTAssertTrue(plan.skippedDestructive.isEmpty)
    }

    /// 类型写法不同但语义相同（`varchar(50)` vs `character varying(50)`）不该算差异 ——
    /// 归一化由 FR-DDL-03 提供，这里确认接得上。
    func testEquivalentTypeSpellingsAreNotADifference() {
        let left = snapshot("期望", [("t", [column("a", type: "varchar(50)")])])
        let right = snapshot("目标", [("t", [column("a", type: "character varying(50)")])])
        XCTAssertTrue(SchemaDiffer.compare(left: left, right: right).isEmpty)
    }

    // MARK: 表级

    func testMissingTableGeneratesCreate() {
        let left = snapshot("期望", [("orders", [column("id", type: "integer")])])
        let right = snapshot("目标", [])
        let plan = SchemaDiffer.plan(left: left, right: right, dialect: dialect)

        XCTAssertEqual(plan.diffs.map(\.kind), [.missingInTarget])
        XCTAssertEqual(plan.statements.count, 1)
        XCTAssertTrue(plan.statements[0].hasPrefix("CREATE TABLE \"public\".\"orders\""), plan.statements[0])
    }

    /// 目标库多出的表：**默认不删**，但要如实列出来（否则看起来像"没有差异"）。
    func testExtraTableIsNotDroppedByDefault() {
        let left = snapshot("期望", [])
        let right = snapshot("目标", [("legacy", [column("id")])])

        let safe = SchemaDiffer.plan(left: left, right: right, dialect: dialect)
        XCTAssertEqual(safe.diffs.map(\.kind), [.extraInTarget])
        XCTAssertTrue(safe.statements.isEmpty, "默认不该生成 DROP：\(safe.statements)")
        XCTAssertFalse(safe.skippedDestructive.isEmpty)
        XCTAssertTrue(safe.skippedDestructive[0].contains("legacy"), "\(safe.skippedDestructive)")

        let aggressive = SchemaDiffer.plan(left: left, right: right, allowDrop: true, dialect: dialect)
        XCTAssertEqual(aggressive.statements.count, 1)
        XCTAssertTrue(aggressive.statements[0].hasPrefix("DROP TABLE"), aggressive.statements[0])
    }

    // MARK: 列级

    func testAddedColumnGeneratesAddColumn() {
        let left = snapshot("期望", [("t", [column("id"), column("note")])])
        let right = snapshot("目标", [("t", [column("id")])])
        let plan = SchemaDiffer.plan(left: left, right: right, dialect: dialect)

        XCTAssertEqual(plan.diffs.count, 1)
        XCTAssertEqual(plan.diffs[0].kind, .changed)
        XCTAssertEqual(plan.statements.count, 1)
        XCTAssertTrue(plan.statements[0].contains("ADD COLUMN"), plan.statements[0])
        XCTAssertTrue(plan.statements[0].contains("\"note\""), plan.statements[0])
    }

    /// 删列默认**不生成**（破坏性），但列进 skipped。
    func testDroppedColumnIsSkippedByDefault() {
        let left = snapshot("期望", [("t", [column("id")])])
        let right = snapshot("目标", [("t", [column("id"), column("secret")])])

        let safe = SchemaDiffer.plan(left: left, right: right, dialect: dialect)
        XCTAssertTrue(safe.statements.isEmpty, "默认不该删列：\(safe.statements)")
        XCTAssertTrue(safe.skippedDestructive.contains { $0.contains("secret") }, "\(safe.skippedDestructive)")

        let aggressive = SchemaDiffer.plan(left: left, right: right, allowDrop: true, dialect: dialect)
        XCTAssertEqual(aggressive.statements.count, 1)
        XCTAssertTrue(aggressive.statements[0].contains("DROP COLUMN"), aggressive.statements[0])
    }

    /// 改类型也是破坏性（可能丢数据）→ 默认跳过，开会话标志才生成。
    func testTypeChangeIsDestructive() {
        let left = snapshot("期望", [("t", [column("a", type: "bigint")])])
        let right = snapshot("目标", [("t", [column("a", type: "integer")])])

        let safe = SchemaDiffer.plan(left: left, right: right, dialect: dialect)
        XCTAssertTrue(safe.statements.isEmpty, "\(safe.statements)")
        XCTAssertTrue(safe.skippedDestructive.contains { $0.contains("改类型") }, "\(safe.skippedDestructive)")

        let aggressive = SchemaDiffer.plan(left: left, right: right, allowDrop: true, dialect: dialect)
        XCTAssertTrue(aggressive.statements[0].contains("TYPE bigint"), aggressive.statements[0])
    }

    /// 可空性与默认值是**非破坏性**修改，默认就该生成。
    func testNullabilityAndDefaultChangesAreSafe() {
        let left = snapshot("期望", [("t", [column("a", nullable: false, default: "'x'")])])
        let right = snapshot("目标", [("t", [column("a", nullable: true, default: "")])])
        let plan = SchemaDiffer.plan(left: left, right: right, dialect: dialect)

        XCTAssertEqual(plan.statements.count, 2, "\(plan.statements)")
        XCTAssertTrue(plan.statements.contains { $0.contains("SET NOT NULL") }, "\(plan.statements)")
        XCTAssertTrue(plan.statements.contains { $0.contains("SET DEFAULT") }, "\(plan.statements)")
        XCTAssertTrue(plan.skippedDestructive.isEmpty)
    }

    // MARK: 顺序与匹配

    func testDiffOrderIsDeterministic() {
        let left = snapshot("期望", [("b", [column("id")]), ("a", [column("id")])])
        let right = snapshot("目标", [("z", [column("id")])])
        XCTAssertEqual(SchemaDiffer.compare(left: left, right: right), SchemaDiffer.compare(left: left, right: right))
        // 先按限定名升序：a 的差异排在 b 前面
        XCTAssertEqual(SchemaDiffer.compare(left: left, right: right).first?.table.name, "a")
    }

    func testTableMatchingIsCaseInsensitive() {
        let left = snapshot("期望", [("Orders", [column("id")])])
        let right = snapshot("目标", [("orders", [column("id")])])
        XCTAssertTrue(SchemaDiffer.compare(left: left, right: right).isEmpty)
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let original = snapshot("期望", [("t", [column("id", type: "integer", primaryKey: true)])])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SchemaSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.tables[0].qualifiedName, "public.t")
    }
}
