import XCTest
@testable import PostgresClientCore

/// FR-AI-07：合成数据生成（可复现 + 约束满足 + 写库走审批）。
final class SyntheticDataTests: XCTestCase {

    private func sampleSpec(seed: UInt64 = 42, rowCount: Int = 20) -> SyntheticTableSpec {
        SyntheticTableSpec(
            table: "orders",
            schema: "public",
            columns: [
                .init(name: "id", generator: .sequence(start: 1, step: 1), isUnique: true),
                .init(name: "customer_id", generator: .integer(min: 1, max: 500)),
                .init(name: "total", generator: .decimal(min: 1, max: 999.99, precision: 2)),
                .init(name: "paid", generator: .boolean(trueProbability: 0.5)),
                .init(name: "note", generator: .text(minLength: 4, maxLength: 8)),
                .init(name: "email", generator: .email),
                .init(name: "created_on", generator: .date(lastDays: 30))
            ],
            rowCount: rowCount,
            seed: seed
        )
    }

    // MARK: - 可复现（验收要点）

    /// 同 specs + 同 seed ⇒ 完全相同的行。
    func testSameSeedProducesIdenticalRows() throws {
        let spec = sampleSpec()

        let first = try SyntheticDataGenerator.generate(spec)
        let second = try SyntheticDataGenerator.generate(spec)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, spec.rowCount)
        XCTAssertEqual(first.first?.count, spec.columns.count)
    }

    func testDifferentSeedProducesDifferentRows() throws {
        let first = try SyntheticDataGenerator.generate(sampleSpec(seed: 1))
        let second = try SyntheticDataGenerator.generate(sampleSpec(seed: 2))

        XCTAssertNotEqual(first, second)
    }

    /// 可复现性跨「进程内多次调用」也成立：中间生成别的表不会影响结果。
    func testSeedIsIsolatedPerSpec() throws {
        let spec = sampleSpec()
        let before = try SyntheticDataGenerator.generate(spec)

        let other = SyntheticTableSpec(
            table: "other", columns: [.init(name: "x", generator: .uuid)], rowCount: 5, seed: 999
        )
        _ = try SyntheticDataGenerator.generate(other)

        XCTAssertEqual(try SyntheticDataGenerator.generate(spec), before)
    }

    /// 日期列相对固定基准日计算，不读时钟：今天和明天跑出的行必须一致。
    func testDateGenerationDoesNotDependOnCurrentTime() throws {
        let spec = SyntheticTableSpec(
            table: "events",
            columns: [.init(name: "on_date", generator: .date(lastDays: 365))],
            rowCount: 10,
            seed: 7
        )

        let rows = try SyntheticDataGenerator.generate(spec)
        let dates = rows.compactMap { $0[0] }

        XCTAssertEqual(dates.count, 10)
        for date in dates {
            XCTAssertTrue(date.hasPrefix("20"), "日期格式异常：\(date)")
            XCTAssertEqual(date.count, 10)
        }
        // 生成两次仍然一致（不含任何时钟依赖）。
        XCTAssertEqual(try SyntheticDataGenerator.generate(spec), rows)
    }

    func testCivilDateArithmetic() {
        // 与已知日期对照，确认纯整数运算没有把月份 / 闰年算错。
        XCTAssertEqual(SyntheticDataGenerator.civilDate(daysSinceUnixEpoch: 0), "1970-01-01")
        XCTAssertEqual(SyntheticDataGenerator.civilDate(daysSinceUnixEpoch: 18_262), "2020-01-01")
        XCTAssertEqual(SyntheticDataGenerator.civilDate(daysSinceUnixEpoch: 19_723), "2024-01-01")
        XCTAssertEqual(SyntheticDataGenerator.civilDate(daysSinceUnixEpoch: -1), "1969-12-31")
    }

    // MARK: - 约束满足

    /// 唯一列不产生重复值。
    func testUniqueColumnHasNoDuplicates() throws {
        let spec = SyntheticTableSpec(
            table: "t",
            columns: [.init(name: "code", generator: .integer(min: 1, max: 1_000_000), isUnique: true)],
            rowCount: 200,
            seed: 5
        )

        let values = try SyntheticDataGenerator.generate(spec).compactMap { $0[0] }

        XCTAssertEqual(values.count, 200)
        XCTAssertEqual(Set(values).count, 200, "唯一列出现了重复值")
    }

    /// 唯一约束无法满足时报错，而不是悄悄给出重复值。
    func testUnsatisfiableUniqueConstraintThrows() {
        let spec = SyntheticTableSpec(
            table: "t",
            columns: [.init(name: "flag", generator: .choice(values: ["y", "n"]), isUnique: true)],
            rowCount: 50,
            seed: 3
        )

        XCTAssertThrowsError(try SyntheticDataGenerator.generate(spec)) { error in
            guard case .uniqueConstraintUnsatisfiable(let column, _)? = error as? SyntheticDataError else {
                return XCTFail("应当报唯一约束无法满足，实际：\(error)")
            }
            XCTAssertEqual(column, "flag")
            XCTAssertNotNil((error as? SyntheticDataError)?.recoverySuggestion)
        }
    }

    /// `nullProbability = 0` ⇒ 不出现 NULL（满足 NOT NULL）。
    func testZeroNullProbabilityProducesNoNulls() throws {
        let rows = try SyntheticDataGenerator.generate(sampleSpec())

        for row in rows {
            for value in row {
                XCTAssertNotNil(value)
            }
        }
    }

    /// `nullProbability = 1` ⇒ 全是 NULL。
    func testFullNullProbabilityProducesAllNulls() throws {
        let spec = SyntheticTableSpec(
            table: "t",
            columns: [.init(name: "maybe", generator: .constant("x"), nullProbability: 1)],
            rowCount: 10,
            seed: 1
        )

        let rows = try SyntheticDataGenerator.generate(spec)
        XCTAssertTrue(rows.allSatisfy { $0[0] == nil })
    }

    /// 区间 / 精度 / 候选集严格生效。
    func testValueRangesAndPrecisionAreRespected() throws {
        let spec = SyntheticTableSpec(
            table: "t",
            columns: [
                .init(name: "n", generator: .integer(min: 10, max: 20)),
                .init(name: "amount", generator: .decimal(min: 0, max: 9.999, precision: 3)),
                .init(name: "status", generator: .choice(values: ["new", "paid", "void"])),
                .init(name: "len", generator: .text(minLength: 2, maxLength: 5))
            ],
            rowCount: 100,
            seed: 11
        )

        for row in try SyntheticDataGenerator.generate(spec) {
            let n = Int(row[0]!)!
            XCTAssertTrue((10...20).contains(n), "整数越界：\(n)")

            let amount = row[1]!
            XCTAssertTrue(amount.contains("."))
            let fraction = amount.components(separatedBy: ".")[1]
            XCTAssertEqual(fraction.count, 3, "小数位数不符：\(amount)")
            XCTAssertTrue((0.0...9.999).contains(Double(amount)!))

            XCTAssertTrue(["new", "paid", "void"].contains(row[2]!))
            XCTAssertTrue((2...5).contains(row[3]!.count))
        }
    }

    func testSequenceRespectsStartAndStep() throws {
        let spec = SyntheticTableSpec(
            table: "t",
            columns: [.init(name: "id", generator: .sequence(start: 100, step: 5))],
            rowCount: 4,
            seed: 1
        )

        XCTAssertEqual(
            try SyntheticDataGenerator.generate(spec).compactMap { $0[0] },
            ["100", "105", "110", "115"]
        )
    }

    func testUUIDShapeLooksLikeVersion4() throws {
        let spec = SyntheticTableSpec(
            table: "t", columns: [.init(name: "id", generator: .uuid)], rowCount: 5, seed: 8
        )

        for row in try SyntheticDataGenerator.generate(spec) {
            let uuid = row[0]!
            XCTAssertEqual(uuid.count, 36)
            XCTAssertEqual(uuid.filter { $0 == "-" }.count, 4)
            XCTAssertEqual(uuid[uuid.index(uuid.startIndex, offsetBy: 14)], "4", "版本位应当是 4")
        }
    }

    func testWeightedChoiceOnlyUsesProvidedValues() throws {
        let spec = SyntheticTableSpec(
            table: "t",
            columns: [
                .init(name: "grade", generator: .weightedChoice(values: [
                    .init(value: "A", weight: 0.1),
                    .init(value: "B", weight: 0.9)
                ]))
            ],
            rowCount: 100,
            seed: 21
        )

        let values = try SyntheticDataGenerator.generate(spec).compactMap { $0[0] }
        XCTAssertTrue(values.allSatisfy { $0 == "A" || $0 == "B" })
        XCTAssertTrue(values.contains("B"), "高权重值应当出现")
    }

    // MARK: - 规格校验

    func testInvalidSpecIsRejectedBeforeGenerating() {
        let spec = SyntheticTableSpec(
            table: "  ",
            columns: [
                .init(name: "a", generator: .integer(min: 10, max: 1), nullProbability: 2),
                .init(name: "a", generator: .decimal(min: 0, max: 1, precision: 99)),
                .init(name: "", generator: .sequence(start: 0, step: 0))
            ],
            rowCount: -1,
            seed: 1
        )

        let issues = SyntheticDataGenerator.issues(in: spec)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertTrue(issues.contains { $0.contains("表名") })
        XCTAssertTrue(issues.contains { $0.contains("行数") })
        XCTAssertTrue(issues.contains { $0.contains("列名重复") })
        XCTAssertTrue(issues.contains { $0.contains("NULL 概率") })
        XCTAssertTrue(issues.contains { $0.contains("上下界颠倒") })
        XCTAssertTrue(issues.contains { $0.contains("小数位数") })
        XCTAssertTrue(issues.contains { $0.contains("步长") })
        XCTAssertFalse(SyntheticDataGenerator.isValid(spec))

        XCTAssertThrowsError(try SyntheticDataGenerator.generate(spec)) { error in
            guard case .invalidSpec? = error as? SyntheticDataError else {
                return XCTFail("应当报规格非法，实际：\(error)")
            }
        }
    }

    func testZeroRowCountIsAllowedAndYieldsNothing() throws {
        var spec = sampleSpec()
        spec.rowCount = 0

        XCTAssertTrue(SyntheticDataGenerator.isValid(spec))
        let rows = try SyntheticDataGenerator.generate(spec)
        XCTAssertTrue(rows.isEmpty)
    }

    func testSpecCodableRoundTrip() throws {
        let spec = sampleSpec()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let restored = try decoder.decode(SyntheticTableSpec.self, from: try encoder.encode(spec))

        XCTAssertEqual(restored, spec)
        XCTAssertEqual(try SyntheticDataGenerator.generate(restored), try SyntheticDataGenerator.generate(spec))
    }

    // MARK: - 写入路径（走审批）

    func testInsertStatementsUseDialectQuoting() throws {
        let spec = sampleSpec(rowCount: 2)
        let rows = try SyntheticDataGenerator.generate(spec)

        let sql = try XCTUnwrap(SyntheticDataGenerator.insertStatements(rows: rows, spec: spec))

        XCTAssertTrue(sql.contains(#"INSERT INTO "public"."orders""#))
        XCTAssertTrue(sql.contains(#""id", "customer_id""#))
        XCTAssertEqual(sql.components(separatedBy: "INSERT INTO").count - 1, 2)
    }

    /// 覆盖模式先清空目标表（与 T-54 的写入语义一致）。
    func testOverwriteModePrependsTruncate() throws {
        let spec = sampleSpec(rowCount: 1)
        let rows = try SyntheticDataGenerator.generate(spec)

        let sql = try XCTUnwrap(
            SyntheticDataGenerator.insertStatements(rows: rows, spec: spec, writeMode: .overwrite)
        )

        XCTAssertTrue(sql.hasPrefix(#"TRUNCATE TABLE "public"."orders";"#))
        XCTAssertTrue(sql.contains("INSERT INTO"))
    }

    func testCopyStatementsAndPayload() throws {
        let spec = sampleSpec(rowCount: 3)
        let rows = try SyntheticDataGenerator.generate(spec)

        let copy = try XCTUnwrap(SyntheticDataGenerator.copyFromStdinStatement(spec: spec))
        XCTAssertTrue(copy.hasPrefix(#"COPY "public"."orders""#))
        XCTAssertTrue(copy.contains("FROM STDIN"))
        XCTAssertTrue(copy.hasSuffix(";"))

        // GBase（MySQL 协议族）没有这条 COPY 语法：不假装支持。
        XCTAssertNil(SyntheticDataGenerator.copyFromStdinStatement(spec: spec, dialect: GBaseDialect()))

        let payload = SyntheticDataGenerator.copyPayload(rows: rows, spec: spec)
        let lines = payload.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4, "CSV 载荷应含表头 + 3 行")
        XCTAssertTrue(lines[0].contains("customer_id"))
        // 载荷不带 BOM，便于直接喂给 COPY。
        XCTAssertFalse(payload.hasPrefix("\u{FEFF}"))
    }

    /// FR-AI-07：写入目标表走审批 —— 只读模式下拿不到审批单，写模式下需人工批准。
    func testWriteGoesThroughApproval() throws {
        let spec = sampleSpec(rowCount: 1)
        let rows = try SyntheticDataGenerator.generate(spec)
        let sql = try XCTUnwrap(SyntheticDataGenerator.insertStatements(rows: rows, spec: spec))

        // 只读模式：连审批单都建不出来。
        XCTAssertNil(SyntheticDataGenerator.writeApproval(sql: sql, policy: .readOnlyDefault))

        // 审批模式：INSERT 本身不是高危语句，但覆盖模式的 TRUNCATE 会要求批准。
        let overwriteSQL = try XCTUnwrap(
            SyntheticDataGenerator.insertStatements(rows: rows, spec: spec, writeMode: .overwrite)
        )
        let approval = try XCTUnwrap(SyntheticDataGenerator.writeApproval(sql: overwriteSQL))
        XCTAssertEqual(approval.state, .pending)
        XCTAssertTrue(approval.record.findings.contains(.truncateStatement))
        XCTAssertFalse(approval.canExecute, "未经批准不得写入")
    }

    func testTypeNamesAreInferredForInsertExport() {
        XCTAssertEqual(SyntheticDataGenerator.sqlTypeName(for: .sequence(start: 1, step: 1)), "int8")
        XCTAssertEqual(SyntheticDataGenerator.sqlTypeName(for: .decimal(min: 0, max: 1, precision: 2)), "numeric")
        XCTAssertEqual(SyntheticDataGenerator.sqlTypeName(for: .boolean(trueProbability: 0.5)), "bool")
        XCTAssertEqual(SyntheticDataGenerator.sqlTypeName(for: .date(lastDays: 1)), "date")
        XCTAssertEqual(SyntheticDataGenerator.sqlTypeName(for: .uuid), "uuid")
        XCTAssertEqual(SyntheticDataGenerator.sqlTypeName(for: .email), "text")
    }
}
