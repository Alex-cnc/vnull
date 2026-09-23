import XCTest
@testable import DoyahCore

/// 按表结构推断合成数据规格（FR-AI-07 的"一键可用"入口）。
///
/// 重点在两条：**推断出的规格必须自洽**（非空列不给 NULL、主键用序列），
/// 以及**类型判定要按完整名比较**（`interval` 里也有 `int`，用 contains 会判错）。
final class SyntheticSpecBuilderTests: XCTestCase {

    private func shape(_ name: String, _ type: String, nullable: Bool = true, pk: Bool = false) -> SyntheticSpecBuilder.ColumnShape {
        SyntheticSpecBuilder.ColumnShape(name: name, typeName: type, isNullable: nullable, isPrimaryKey: pk)
    }

    // MARK: 自洽性（能不能插进去）

    /// 非空列与主键列的 NULL 概率必须是 0 —— 这是硬条件，不是偏好。
    func testNotNullAndPrimaryKeyColumnsNeverGenerateNull() throws {
        let spec = SyntheticSpecBuilder.spec(
            table: "t",
            columns: [
                shape("id", "bigint", nullable: false, pk: true),
                shape("name", "text", nullable: false),
                shape("note", "text", nullable: true),
            ],
            rowCount: 5
        )

        XCTAssertEqual(spec.columns[0].nullProbability, 0)
        XCTAssertEqual(spec.columns[1].nullProbability, 0)
        XCTAssertEqual(spec.columns[2].nullProbability, SyntheticSpecBuilder.nullableProbability)
        XCTAssertTrue(spec.columns[0].isUnique, "主键列必须唯一")
        XCTAssertFalse(spec.columns[1].isUnique, "看不到唯一约束时不猜 —— 猜错会让生成失败")

        // 真生成一遍：非空列不该出现 nil。
        let rows = try SyntheticDataGenerator.generate(spec)
        XCTAssertEqual(rows.count, 5)
        for row in rows {
            XCTAssertNotNil(row[0])
            XCTAssertNotNil(row[1])
        }
    }

    /// 生成的数据必须真的能通过规格校验（否则界面会"生成成功但插不进去"）。
    func testInferredSpecPassesValidation() {
        let spec = SyntheticSpecBuilder.spec(
            table: "orders",
            columns: [
                shape("id", "integer", nullable: false, pk: true),
                shape("amount", "numeric(10, 2)", nullable: false),
                shape("created_at", "timestamp with time zone", nullable: false),
                shape("email", "varchar(120)"),
                shape("active", "boolean"),
                shape("uid", "uuid"),
            ],
            rowCount: 20,
            seed: 7
        )
        XCTAssertEqual(SyntheticDataGenerator.issues(in: spec), [])
        XCTAssertNoThrow(try SyntheticDataGenerator.generate(spec))
    }

    // MARK: 类型映射

    func testTypeMapping() {
        let cases: [(String, ColumnGenerator)] = [
            ("bigint", .integer(min: 1, max: 10_000)),
            ("smallint", .integer(min: 1, max: 10_000)),
            ("numeric(10,2)", .decimal(min: 0, max: 1_000, precision: 2)),
            ("double precision", .decimal(min: 0, max: 1_000, precision: 2)),
            ("boolean", .boolean(trueProbability: 0.5)),
            ("date", .date(lastDays: 365)),
            ("timestamp without time zone", .timestamp(lastDays: 365)),
            ("uuid", .uuid),
            ("character varying(50)", .text(minLength: 8, maxLength: 24)),
            ("TEXT", .text(minLength: 8, maxLength: 24)),
        ]
        for (type, expected) in cases {
            let generator = SyntheticSpecBuilder.generator(for: shape("c", type))
            XCTAssertEqual(generator, expected, "\(type) 应映射为 \(expected)，实际 \(generator)")
        }
    }

    /// 主键 + 整数 → 序列（唯一且递增），比"随机整数 + 去重"更像真数据。
    func testPrimaryKeyIntegerBecomesSequence() {
        XCTAssertEqual(
            SyntheticSpecBuilder.generator(for: shape("id", "integer", nullable: false, pk: true)),
            .sequence(start: 1, step: 1)
        )
        // 非整数主键不套序列（uuid 主键就该是 uuid）。
        XCTAssertEqual(
            SyntheticSpecBuilder.generator(for: shape("id", "uuid", nullable: false, pk: true)),
            .uuid
        )
    }

    /// **按完整类型名判定**：`interval` 含 `int`，用 contains 会把它判成整数列。
    func testIntervalIsNotTreatedAsInteger() {
        let generator = SyntheticSpecBuilder.generator(for: shape("gap", "interval"))
        XCTAssertEqual(generator, .text(minLength: 6, maxLength: 16), "认不出来时给文本，而不是硬套整数")
    }

    func testNormalizedTypeNameStripsParameters() {
        XCTAssertEqual(SyntheticSpecBuilder.normalizedTypeName("VARCHAR(50)"), "varchar")
        XCTAssertEqual(SyntheticSpecBuilder.normalizedTypeName("numeric(10, 2)"), "numeric")
        XCTAssertEqual(SyntheticSpecBuilder.normalizedTypeName("  Text  "), "text")
        XCTAssertEqual(SyntheticSpecBuilder.normalizedTypeName("timestamp with time zone"), "timestamp with time zone")
    }

    func testEmptyColumnNamesAreDropped() {
        let spec = SyntheticSpecBuilder.spec(
            table: "t",
            columns: [shape("", "text"), shape("ok", "text")],
            rowCount: 3
        )
        XCTAssertEqual(spec.columns.map(\.name), ["ok"])
    }

    /// 从 `TableColumnDefinition` 直接构造（界面拿到的是那种类型）。
    func testInitFromTableColumnDefinition() {
        let column = TableColumnDefinition(name: "id", typeName: "integer", isNullable: false, defaultValue: "", isPrimaryKey: true)
        let shape = SyntheticSpecBuilder.ColumnShape(column)
        XCTAssertEqual(shape.name, "id")
        XCTAssertFalse(shape.isNullable)
        XCTAssertTrue(shape.isPrimaryKey)
    }

    // MARK: 可复现

    /// 同规格 + 同 seed ⇒ 完全相同的行（FR-AI-07 的硬要求）。
    func testSameSeedProducesIdenticalRows() throws {
        let columns = [shape("id", "integer", nullable: false, pk: true), shape("name", "text", nullable: false)]
        let first = try SyntheticDataGenerator.generate(
            SyntheticSpecBuilder.spec(table: "t", columns: columns, rowCount: 10, seed: 42)
        )
        let second = try SyntheticDataGenerator.generate(
            SyntheticSpecBuilder.spec(table: "t", columns: columns, rowCount: 10, seed: 42)
        )
        XCTAssertEqual(first, second)

        let other = try SyntheticDataGenerator.generate(
            SyntheticSpecBuilder.spec(table: "t", columns: columns, rowCount: 10, seed: 43)
        )
        XCTAssertNotEqual(first, other, "换 seed 应当换数据（否则 seed 形同虚设）")
    }
}
