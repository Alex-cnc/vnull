import XCTest
@testable import DoyahCore

/// CSV / JSON 导入（FR-IO-03）：读取、映射、类型化字面量、分批。
///
/// 最要紧的是**别把数据读错位**：引号内的逗号与换行、`""` 转义、CRLF、BOM 各写一条。
final class TableImportTests: XCTestCase {

    // MARK: 读取

    func testSimpleCSVWithHeader() {
        let result = DelimitedTextReader.read("id,name\n1,alice\n2,bob\n")
        XCTAssertEqual(result.header, ["id", "name"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0], ["1", "alice"])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    /// 引号内的逗号是数据，不是分隔符。
    func testQuotedCommaIsData() {
        let result = DelimitedTextReader.read("id,note\n1,\"a, b\"\n")
        XCTAssertEqual(result.rows[0], ["1", "a, b"])
    }

    /// 引号内的换行是数据（最容易把行数读错的一条）。
    func testQuotedNewlineIsData() {
        let result = DelimitedTextReader.read("id,note\n1,\"line1\nline2\"\n2,plain\n")
        XCTAssertEqual(result.rows.count, 2, "引号里的换行不该被当成新行")
        XCTAssertEqual(result.rows[0][1], "line1\nline2")
        XCTAssertEqual(result.rows[1], ["2", "plain"])
    }

    /// `""` 是转义后的一个引号。
    func testDoubledQuoteEscape() {
        let result = DelimitedTextReader.read("id,note\n1,\"say \"\"hi\"\"\"\n")
        XCTAssertEqual(result.rows[0][1], "say \"hi\"")
    }

    /// CRLF 与 BOM 都要处理：前者来自 Windows 导出，后者来自 Excel。
    func testCRLFAndBOM() {
        let result = DelimitedTextReader.read("\u{FEFF}id,name\r\n1,alice\r\n")
        XCTAssertEqual(result.header, ["id", "name"], "BOM 不该混进第一个列名")
        XCTAssertEqual(result.rows, [["1", "alice"]])
    }

    /// 未加引号的空字段 = NULL；加了引号的空串 = 空字符串。区分它们是有意的。
    func testEmptyFieldVersusQuotedEmpty() {
        let result = DelimitedTextReader.read("a,b\n,\"\"\n")
        XCTAssertEqual(result.rows[0][0], nil)
        XCTAssertEqual(result.rows[0][1], "")
    }

    func testRowWithoutTrailingNewline() {
        let result = DelimitedTextReader.read("a,b\n1,2")
        XCTAssertEqual(result.rows, [["1", "2"]])
    }

    func testColumnCountMismatchIsWarnedNotFatal() {
        let result = DelimitedTextReader.read("a,b\n1,2\n3\n")
        XCTAssertEqual(result.rows.count, 2, "列数不齐仍然收下，但要报告")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("列数"))
    }

    func testTSVAndNoHeader() {
        // 有表头的 TSV：第一行是列名，不进数据。
        let withHeader = DelimitedTextReader.read("id\tname\n1\talice\n", options: .tsv)
        XCTAssertEqual(withHeader.header, ["id", "name"])
        XCTAssertEqual(withHeader.rows, [["1", "alice"]])

        // 无表头：第一行就是数据（`.tsv` 默认 hasHeader = true，所以要显式关掉 ——
        // 我第一版忘了这点，测试当场指出：那一行被当成表头，rows 是空的）。
        let noHeader = DelimitedTextReader.read(
            "1,alice\n",
            options: DelimitedTextReader.Options(hasHeader: false)
        )
        XCTAssertTrue(noHeader.header.isEmpty)
        XCTAssertEqual(noHeader.rows, [["1", "alice"]])
    }

    func testJSONObjects() throws {
        let result = try DelimitedTextReader.readJSON(#"[{"id": 1, "name": "alice"}, {"id": 2, "name": null}]"#)
        XCTAssertEqual(result.header, ["id", "name"])
        XCTAssertEqual(result.rows[0], ["1", "alice"])
        XCTAssertEqual(result.rows[1], ["2", nil], "JSON null 应当是 NULL")
    }

    func testJSONNestedValueBecomesText() throws {
        let result = try DelimitedTextReader.readJSON(#"[{"id": 1, "meta": {"a": 1}}]"#)
        XCTAssertEqual(result.header, ["id", "meta"])
        XCTAssertEqual(result.rows[0][1], #"{"a":1}"#, "嵌套结构转成 JSON 文本，不丢")
    }

    func testJSONRejectsUnexpectedShape() {
        XCTAssertThrowsError(try DelimitedTextReader.readJSON(#"{"id": 1}"#))
        XCTAssertThrowsError(try DelimitedTextReader.readJSON("不是 JSON"))
    }

    // MARK: 映射

    private let target = [
        TableImport.TargetColumn(name: "id", typeName: "integer", isNullable: false),
        TableImport.TargetColumn(name: "name", typeName: "text", isNullable: false),
        TableImport.TargetColumn(name: "amount", typeName: "numeric(10,2)", isNullable: true),
        TableImport.TargetColumn(name: "created_at", typeName: "timestamp", isNullable: true),
    ]

    func testMappingMatchesByNameIgnoringCase() {
        let plan = TableImport.plan(table: "t", sourceHeader: ["ID", "Name"], targetColumns: target)
        XCTAssertEqual(plan.mappedColumns.map(\.targetName), ["id", "name"])
        XCTAssertEqual(plan.mappedColumns.map(\.sourceIndex), [0, 1])
        // 文件里没有的列不导入（走默认值）
        XCTAssertEqual(plan.mappings.filter { $0.sourceIndex == nil }.map(\.targetName), ["amount", "created_at"])
    }

    /// 文件里有、目标表没有的列要**说出来**，不能悄悄丢。
    func testUnknownSourceColumnsAreReported() {
        let plan = TableImport.plan(table: "t", sourceHeader: ["id", "name", "extra"], targetColumns: target)
        XCTAssertEqual(plan.unknownSourceColumns, ["extra"])
    }

    /// 必填列在文件里缺失 → 提前说（继续导入基本一定失败）。
    func testMissingRequiredColumnIsReported() {
        let plan = TableImport.plan(table: "t", sourceHeader: ["id"], targetColumns: target)
        XCTAssertEqual(plan.missingRequiredColumns, ["name"])
    }

    func testValueTypeInference() {
        XCTAssertEqual(TableImport.valueType(forTypeName: "bigint"), .number)
        XCTAssertEqual(TableImport.valueType(forTypeName: "NUMERIC(10,2)"), .number)
        XCTAssertEqual(TableImport.valueType(forTypeName: "boolean"), .boolean)
        XCTAssertEqual(TableImport.valueType(forTypeName: "timestamp with time zone"), .text, "日期当文本，加引号让数据库自己转")
        XCTAssertEqual(TableImport.valueType(forTypeName: "interval"), .text, "interval 里也有 int，不能按 contains 判")
    }

    // MARK: 语句生成

    func testInsertStatementRendersTypedLiterals() throws {
        let plan = TableImport.plan(table: "t", schema: "public", sourceHeader: ["id", "name", "amount"], targetColumns: target)
        let sql = try XCTUnwrap(TableImport.insertStatement(
            rows: [["1", "O'Brien", "12.5"], ["2", nil, "abc"]],
            plan: plan
        ))

        XCTAssertTrue(sql.hasPrefix("INSERT INTO \"public\".\"t\" (\"id\", \"name\", \"amount\") VALUES"), sql)
        XCTAssertTrue(sql.contains("(1, 'O''Brien', 12.5)"), "数字不加引号、单引号要双写：\(sql)")
        // amount 是数字列但值是 `abc` → 退化成 NULL（由 invalidValues 提前报告）
        XCTAssertTrue(sql.contains("(2, NULL, NULL)"), sql)
    }

    func testInvalidValuesAreReportedWithRowAndColumn() {
        let plan = TableImport.plan(table: "t", sourceHeader: ["id", "amount"], targetColumns: target)
        let problems = TableImport.invalidValues(rows: [["1", "12"], ["abc", "xyz"]], plan: plan)
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems[0].contains("第 2 行 id"), problems[0])
        XCTAssertTrue(problems[1].contains("第 2 行 amount"), problems[1])
    }

    /// 这是"原始 SQL 里插入恶意值"的姊妹场景：导入的文本也必须是数据。
    func testMaliciousCellValueIsEscaped() throws {
        let plan = TableImport.plan(table: "t", sourceHeader: ["id", "name"], targetColumns: target)
        let sql = try XCTUnwrap(TableImport.insertStatement(
            rows: [["1", "x'); DROP TABLE t; --"]],
            plan: plan
        ))
        let dropIndex = try XCTUnwrap(sql.range(of: "DROP TABLE")).lowerBound
        XCTAssertFalse(SQLLexer.isCode(at: dropIndex, in: sql), "危险内容必须落在字面量里")
    }

    func testBatching() {
        let rows: [[String?]] = (1...7).map { ["\($0)"] }
        let batches = TableImport.batches(rows, size: 3)
        XCTAssertEqual(batches.map(\.count), [3, 3, 1])
        XCTAssertEqual(TableImport.batches([], size: 3).count, 0)
        XCTAssertEqual(TableImport.batches(rows, size: 0).count, 1, "非法批大小退化为一批")
    }

    func testEmptyPlanProducesNoStatement() {
        // 目标列与文件列完全不匹配 → 没有可映射的列，生成器返回 nil
        let plan = TableImport.plan(table: "t", sourceHeader: ["other"], targetColumns: [TableImport.TargetColumn(name: "id", typeName: "int")])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertNil(TableImport.insertStatement(rows: [["1"]], plan: plan))
    }

    // MARK: 写入通道（COPY / 批量 INSERT）

    /// COPY 的可用性必须**带理由**：不可用时退回 INSERT，"为什么退"是用户必须看到的事实。
    func testCopySupportByDatabaseType() {
        let postgres = TableImport.copySupport(databaseType: .postgresql)
        XCTAssertTrue(postgres.isAvailable)
        XCTAssertNil(postgres.reason)

        let gbase = TableImport.copySupport(databaseType: .gbase8a)
        XCTAssertFalse(gbase.isAvailable)
        XCTAssertNotNil(gbase.reason)
        XCTAssertTrue(gbase.reason?.contains("INSERT") == true, "理由要说清退回哪条路：\(gbase.reason ?? "")")
    }

    func testPreferredWriteModeFollowsCopySupport() {
        XCTAssertEqual(TableImport.preferredWriteMode(databaseType: .postgresql).mode, .copy)
        XCTAssertNil(TableImport.preferredWriteMode(databaseType: .postgresql).reason)

        let fallback = TableImport.preferredWriteMode(databaseType: .gbase8a)
        XCTAssertEqual(fallback.mode, .batchInsert)
        XCTAssertNotNil(fallback.reason)
    }

    /// 预览 / 安全检查用的 COPY 语句：限定名与列名都要按方言加引号，且**没有列就没有语句**。
    func testCopyStatementRendersQualifiedTarget() {
        let sql = TableImport.copyStatement(table: "items", schema: "public", columns: ["id", "note"])
        XCTAssertEqual(sql, #"COPY "public"."items" ("id", "note") FROM STDIN"#)
        XCTAssertNil(TableImport.copyStatement(table: "items", columns: []), "没有列就没有可下的 COPY")
    }

    /// COPY 语句必须被护栏识别成**数据变更** —— 否则这条快路径会绕过只读保护与写确认。
    func testCopyStatementIsClassifiedAsDataChange() throws {
        let sql = try XCTUnwrap(TableImport.copyStatement(table: "items", columns: ["id"]))
        let assessment = AgentGuardrail.evaluate(
            sql: sql,
            policy: AgentGuardPolicy(readOnly: true)
        )
        XCTAssertFalse(assessment.verdict.isAllowed, "只读模式下 COPY 必须被判为不可执行")
    }

    /// 只读连接上的 `ExecutionSafety` 也要拦下 COPY（界面据此直接拒绝，而不是"确认后放行"）。
    func testCopyStatementIsRefusedOnReadOnlyConnection() throws {
        let sql = try XCTUnwrap(TableImport.copyStatement(table: "items", columns: ["id"]))
        let decision = ExecutionSafety.check(
            sql: sql,
            policy: ExecutionSafetyPolicy(isEnabled: false, isReadOnly: true)
        )
        if case .refused = decision {
            // 期望路径
        } else {
            XCTFail("只读连接上 COPY 应被直接拒绝，实际：\(decision)")
        }
    }

    /// COPY 路径原样取值（不做字面量转义），顺序与"有来源列"的映射一致。
    func testCopyRowsKeepsRawValuesInMappingOrder() {
        let plan = TableImport.plan(table: "t", sourceHeader: ["name", "id"], targetColumns: target)
        let rows = TableImport.copyRows(rows: [["alice", "1"]], plan: plan)
        // 目标列顺序是 id → name，所以源列顺序被重排；且值**原样**（没有引号）。
        XCTAssertEqual(rows, [["1", "alice"]])
    }
}
