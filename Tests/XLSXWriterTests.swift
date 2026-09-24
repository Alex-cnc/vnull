import XCTest
@testable import DoyahCore

/// xlsx 写入器（FR-RES-14）：ZIP 结构、CRC、XML 转义、单元格类型、工作表名净化、确定性。
///
/// 更进一步的**独立验证**在 `Scripts/test-xlsx-export.sh` 里：那份用 Python 的 zipfile +
/// ElementTree 把产物解出来核对（两份实现互相印证，而不是自己验自己）。
final class XLSXWriterTests: XCTestCase {

    // MARK: - CRC32

    /// 对照公开测试向量：`"123456789"` 的 CRC-32 是 `0xCBF43926`。
    func testCRC32MatchesKnownVector() {
        XCTAssertEqual(XLSXWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testCRC32OfEmptyDataIsZero() {
        XCTAssertEqual(XLSXWriter.crc32(Data()), 0)
    }

    // MARK: - ZIP 结构

    func testArchiveHasZipSignatures() {
        let data = XLSXWriter.workbook(sheetName: "Sheet1", columns: ["a"], rows: [])
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "本地文件头签名")
        XCTAssertTrue(contains(bytes, [0x50, 0x4B, 0x05, 0x06]), "中央目录结束记录")
        XCTAssertTrue(contains(bytes, [0x50, 0x4B, 0x01, 0x02]), "中央目录项")
    }

    /// 六个部件一个都不能少（少了 Excel 会说"文件已损坏"）。
    func testAllPartsArePresent() {
        let data = XLSXWriter.workbook(sheetName: "Sheet1", columns: ["a"], rows: [])
        let text = String(decoding: [UInt8](data), as: UTF8.self)
        for part in [
            "[Content_Types].xml",
            "_rels/.rels",
            "xl/workbook.xml",
            "xl/_rels/workbook.xml.rels",
            "xl/styles.xml",
            "xl/worksheets/sheet1.xml"
        ] {
            XCTAssertTrue(text.contains(part), "缺少部件 \(part)")
        }
    }

    /// 同样的输入必须**逐字节相同**（时间戳固定）—— 否则每次导出都不同，校验无从谈起。
    func testArchiveIsDeterministic() {
        let first = XLSXWriter.workbook(sheetName: "s", columns: ["a", "b"], rows: [["1", "x"]])
        let second = XLSXWriter.workbook(sheetName: "s", columns: ["a", "b"], rows: [["1", "x"]])
        XCTAssertEqual(first, second)
    }

    // MARK: - 单元格

    func testNumericColumnsWriteNumbers() {
        let sheet = XLSXWriter.sheetXML(columns: ["id"], rows: [["42"]], numericColumns: [0])
        XCTAssertTrue(sheet.contains("<c r=\"A2\"><v>42</v></c>"), "数字列应当写成数值单元格：\(sheet)")
    }

    /// 看着像数字但不该按数字写的值（前导零 / 正号）——宁可当文本，也不悄悄改数据。
    func testAmbiguousNumbersStayText() {
        for value in ["007", "+5", " 42", "42 ", "1,000", "2026-09-24", "NaN", "1e999"] {
            XCTAssertNil(XLSXWriter.numericLiteral(value), "\(value) 不该按数字写")
        }
        XCTAssertEqual(XLSXWriter.numericLiteral("42"), "42")
        XCTAssertEqual(XLSXWriter.numericLiteral("-3.5"), "-3.5")
        XCTAssertEqual(XLSXWriter.numericLiteral("0.5"), "0.5")
    }

    func testTextCellsUseInlineStrings() {
        let sheet = XLSXWriter.sheetXML(columns: ["name"], rows: [["订单"]], numericColumns: [])
        XCTAssertTrue(sheet.contains("<c r=\"A2\" t=\"inlineStr\"><is><t>订单</t></is></c>"))
    }

    /// 前后空白 / 换行必须带 `xml:space="preserve"`，否则 Excel 会把它们吃掉。
    func testWhitespaceSensitiveTextIsPreserved() {
        let sheet = XLSXWriter.sheetXML(columns: ["x"], rows: [["  a  "], ["b\nc"]], numericColumns: [])
        XCTAssertEqual(sheet.components(separatedBy: "xml:space=\"preserve\"").count - 1, 2)
    }

    func testNilValuesProduceEmptyCells() {
        let sheet = XLSXWriter.sheetXML(columns: ["a", "b"], rows: [["1", nil]], numericColumns: [])
        XCTAssertTrue(sheet.contains("<row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is><t>1</t></is></c></row>"))
    }

    // MARK: - 转义

    func testEscapingCoversMarkupCharacters() {
        let escaped = XLSXWriter.escape("a & b < c > d \" e ' f")
        XCTAssertEqual(escaped, "a &amp; b &lt; c &gt; d &quot; e &apos; f")
    }

    /// XML 1.0 不允许的控制字符要替换成 U+FFFD（而不是静默删掉）——
    /// 原样写进去 Excel 直接判文件损坏。
    func testForbiddenControlCharactersAreReplaced() {
        let escaped = XLSXWriter.escape("a\u{0001}b\u{000B}c")
        XCTAssertEqual(escaped, "a\u{FFFD}b\u{FFFD}c")
        XCTAssertFalse(escaped.unicodeScalars.contains { $0.value < 0x20 })
        // 制表 / 换行 / 回车是合法的，要保留
        XCTAssertEqual(XLSXWriter.escape("a\tb\nc\rd"), "a\tb\nc\rd")
    }

    // MARK: - 工作表名与列名

    func testSheetNameSanitization() {
        XCTAssertEqual(XLSXWriter.sanitizedSheetName("结果[1]:*?/\\"), "结果1")
        XCTAssertEqual(XLSXWriter.sanitizedSheetName("   "), "Sheet1")
        XCTAssertEqual(XLSXWriter.sanitizedSheetName(String(repeating: "长", count: 40)).count, 31)
        XCTAssertEqual(XLSXWriter.sanitizedSheetName("'quoted'"), "quoted")
        XCTAssertEqual(XLSXWriter.sanitizedSheetName("订单"), "订单")
    }

    func testColumnNamesRollOverPastZ() {
        XCTAssertEqual(XLSXWriter.columnName(0), "A")
        XCTAssertEqual(XLSXWriter.columnName(25), "Z")
        XCTAssertEqual(XLSXWriter.columnName(26), "AA")
        XCTAssertEqual(XLSXWriter.columnName(27), "AB")
        XCTAssertEqual(XLSXWriter.columnName(51), "AZ")
        XCTAssertEqual(XLSXWriter.columnName(52), "BA")
        XCTAssertEqual(XLSXWriter.columnName(701), "ZZ")
        XCTAssertEqual(XLSXWriter.columnName(702), "AAA")
    }

    /// 端到端：表头 + 数据行都在，且中文原样。
    func testWorkbookCarriesHeaderAndRows() {
        let data = XLSXWriter.workbook(
            sheetName: "查询结果",
            columns: ["id", "名称"],
            rows: [["1", "订单一"], ["2", "订单二"]],
            numericColumns: [0]
        )
        let text = String(decoding: [UInt8](data), as: UTF8.self)
        XCTAssertTrue(text.contains("查询结果"))
        XCTAssertTrue(text.contains("<t>名称</t>"))
        XCTAssertTrue(text.contains("<t>订单二</t>"))
        XCTAssertTrue(text.contains("<v>1</v>"))
        XCTAssertTrue(text.contains("<v>2</v>"))
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}

// MARK: - 导出器层面的接线（FR-RES-14）

/// 这些断言盯的是"接进导出链路之后有没有走错路"：二进制格式不能被当成文本写，
/// 数值列的类型判断要保守，流式写入器要**明确拒绝**而不是写出半个坏文件。
final class XLSXExportIntegrationTests: XCTestCase {

    private func result() -> QueryResult {
        QueryResult(
            columns: [
                ColumnMeta(id: 0, name: "id", typeName: "integer"),
                ColumnMeta(id: 1, name: "name", typeName: "text"),
                ColumnMeta(id: 2, name: "amount", typeName: "numeric(10,2)"),
                ColumnMeta(id: 3, name: "created", typeName: "date")
            ],
            rows: [["1", "订单一", "12.5", "2026-09-24"]]
        )
    }

    func testFormatMetadata() {
        XCTAssertEqual(ResultExportFormat.xlsx.fileExtension, "xlsx")
        XCTAssertEqual(ResultExportFormat.xlsx.contentTypeIdentifier, "org.openxmlformats.spreadsheetml.sheet")
        XCTAssertTrue(ResultExportFormat.xlsx.isBinary)
        XCTAssertFalse(ResultExportFormat.csv.isBinary)
        XCTAssertFalse(ResultExportFormat.xlsx.requiresTableName)
    }

    /// 文本入口对二进制格式**返回空串**（有意的、被文档与测试钉住的契约）：
    /// 想拿 xlsx 必须用 `data(for:format:)`，而 `isBinary` 让调用方提前分支。
    func testTextEntryPointIsEmptyForBinaryFormat() {
        XCTAssertEqual(ResultExporter.text(for: result(), format: .xlsx), "")
    }

    func testDataEntryPointMatchesTextForTextFormats() {
        let model = result()
        let data = ResultExporter.data(for: model, format: .csv)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), ResultExporter.text(for: model, format: .csv))
        XCTAssertEqual(Array(data.prefix(4)), [0xEF, 0xBB, 0xBF, 0x69], "CSV 带 BOM（与既有行为一致）")
    }

    func testDataEntryPointProducesZipForXLSX() {
        let data = ResultExporter.data(for: result(), format: .xlsx)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "应当是 ZIP（PK）")
    }

    /// 数值列按**类型名**判定，且保守：日期 / 布尔 / 金额字符串都不算数字。
    func testNumericTypeDetectionIsConservative() {
        for name in ["integer", "int4", "bigint", "numeric", "numeric(10,2)", "decimal(6,3)",
                     "real", "double precision", "float8", "serial"] {
            XCTAssertTrue(ResultExporter.isNumericTypeName(name), "\(name) 应当是数字列")
        }
        for name in ["text", "character varying(20)", "date", "timestamp with time zone",
                     "boolean", "uuid", "jsonb", "bytea", "money"] {
            XCTAssertFalse(ResultExporter.isNumericTypeName(name), "\(name) 不该按数字写")
        }
    }

    /// 整数列写成数值单元格、文本列写成 inlineStr；日期列按文本（不能变成序列号）。
    func testWorkbookCellTypesFollowColumnTypes() {
        let data = ResultExporter.xlsx(for: result())
        let sheet = String(decoding: [UInt8](data), as: UTF8.self)
        XCTAssertTrue(sheet.contains("<c r=\"A2\"><v>1</v></c>"), "整数列 → 数值")
        XCTAssertTrue(sheet.contains("<c r=\"C2\"><v>12.5</v></c>"), "numeric 列 → 数值")
        XCTAssertTrue(sheet.contains("<c r=\"B2\" t=\"inlineStr\">"), "text 列 → 文本")
        XCTAssertTrue(sheet.contains("<c r=\"D2\" t=\"inlineStr\">"), "date 列 → 文本（不能变成序列号）")
    }

    /// 流式写入器必须**明确拒绝** xlsx：写半个 ZIP 是打不开的，错误信息才说得清原因。
    func testStreamingWriterRefusesBinaryFormat() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doyah-xlsx-refuse-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = ResultStreamWriter(
            targetURL: url,
            format: .xlsx,
            columns: [ColumnMeta(id: 0, name: "id")],
            tableName: "t",
            dialect: nil
        )
        XCTAssertThrowsError(try writer.begin()) { error in
            XCTAssertEqual(error as? ResultStreamError, .binaryFormatNeedsFullResult)
        }
    }
}
