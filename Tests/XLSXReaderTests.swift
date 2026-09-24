import XCTest
@testable import DoyahCore

/// `.xlsx` 读取（FR-IO-06）：ZIP（stored / deflate）、共享字符串、`<rPh>` 跳过、日期序列号、
/// 公式缓存值、NULL 与空串之分、稀疏网格。
///
/// 夹具由 `Scripts/make-xlsx-fixtures.py` **手写 OOXML + Python zipfile(deflate)** 生成 ——
/// 手写是为了覆盖 openpyxl 那类库会"规整掉"的形状（拼音块、稀疏行、present-but-empty 内联串）；
/// deflate 是为了走真实 Excel / WPS 的压缩路径（那样才会真的用到 `Inflate`）。
final class XLSXReaderTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/xlsx")
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("夹具不存在：\(url.path)（先跑 python3 Scripts/make-xlsx-fixtures.py）")
        }
        return data
    }

    // MARK: - 结构

    func testSheetNamesAndOrder() throws {
        let sheets = try XLSXReader.sheets(try fixture("orders.xlsx"))
        XCTAssertEqual(sheets.map(\.name), ["订单", "第二张"])
        XCTAssertEqual(sheets[0].rows.count, 6, "第一张表 6 行（含稀疏的第 6 行）")
        XCTAssertEqual(sheets[0].columnCount, 8, "H 列出现过，所以宽 8")
        XCTAssertEqual(sheets[1].rows.count, 2)
    }

    func testStoredAndDeflatedArchiveBothRead() throws {
        for name in ["minimal.xlsx", "stored.xlsx"] {
            let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture(name)).first)
            XCTAssertEqual(sheet.rows[0], ["列一", "列二"], "\(name) 表头不对")
            XCTAssertEqual(sheet.rows[1], ["值", "42"], "\(name) 数据不对")
        }
    }

    /// 最小工作簿：没有 `xl/styles.xml`、没有 `xl/sharedStrings.xml`，读取器必须能兜底。
    func testMinimalWorkbookWithoutOptionalParts() throws {
        let sheets = try XLSXReader.sheets(try fixture("minimal.xlsx"))
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].name, "最小")
        XCTAssertEqual(sheets[0].rows[1][1], "42", "没有样式表时数字仍要读出来")
    }

    // MARK: - 字符串

    func testSharedStringsAndPhoneticSkip() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("orders.xlsx")).first)
        XCTAssertEqual(sheet.rows[1][1], "订单一", "共享字符串没读到")
        XCTAssertEqual(sheet.rows[2][1], "订单二", "`<rPh>` 拼音块必须跳过，否则会读成「订单二ディンデン」")
        XCTAssertEqual(sheet.rows[3][1], "Order Three Inc.", "富文本多段 `<r>` 要拼起来")
    }

    func testEntityDecodingAndPreservedWhitespace() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("orders.xlsx")).first)
        XCTAssertEqual(sheet.rows[1][5], "含逗号,与引号\"x\" 与实体 & <标签>")
        XCTAssertEqual(sheet.rows[4][5], "  前后有空格  ", "xml:space=preserve 的空白不能被吃掉")
    }

    func testInlineRichTextWithoutPhonetics() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("orders.xlsx")).first)
        XCTAssertEqual(sheet.rows[2][1], "订单二")
    }

    // MARK: - 日期（最容易"看着成功、数据已错"的一处）

    func testBuiltinDateStyleConvertsSerial() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("orders.xlsx")).first)
        XCTAssertEqual(sheet.rows[1][3], "2024-01-05", "内建日期样式（numFmtId 14）下的 45296")
        XCTAssertEqual(sheet.rows[4][3], "2024-01-08", "45299")
    }

    func testCustomDateFormatCodeWithTime() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("orders.xlsx")).first)
        XCTAssertEqual(sheet.rows[2][3], "2024-01-06 12:00:00", "自定义格式码 yyyy/mm/dd 下的 45297.5")
    }

    func testNumbersWithoutDateStyleStayRaw() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("orders.xlsx")).first)
        XCTAssertEqual(sheet.rows[1][2], "12.5", "没有日期样式的数字必须原样（不能自作聪明）")
        XCTAssertEqual(sheet.rows[4][2], "-3.25")
    }

    func test1904DateSystem() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("dates1904.xlsx")).first)
        XCTAssertEqual(sheet.rows[1][3], "1904-04-10", "date1904=\"1\" 时序列号 100 的基准日不同")
    }

    func testExcelDateSerialEdgeCases() {
        XCTAssertEqual(XLSXReader.excelDateString(serial: 1, uses1904: false), "1900-01-01")
        XCTAssertEqual(XLSXReader.excelDateString(serial: 59, uses1904: false), "1900-02-28")
        // Excel 认为 1900 年是闰年：序列号 60 是它虚构的 1900-02-29，我们如实输出而不是挪一天。
        XCTAssertEqual(XLSXReader.excelDateString(serial: 60, uses1904: false), "1900-02-29")
        XCTAssertEqual(XLSXReader.excelDateString(serial: 61, uses1904: false), "1900-03-01")
        XCTAssertEqual(XLSXReader.excelDateString(serial: 0.5, uses1904: false), "12:00:00")
        XCTAssertNil(XLSXReader.excelDateString(serial: .nan, uses1904: false))
    }

    func testDateFormatCodeSniffing() {
        XCTAssertTrue(XLSXReader.isDateLikeFormatCode("yyyy/mm/dd"))
        XCTAssertTrue(XLSXReader.isDateLikeFormatCode("[$-409]d/m/yyyy"))
        XCTAssertTrue(XLSXReader.isDateLikeFormatCode("hh:mm:ss"))
        XCTAssertTrue(XLSXReader.isDateLikeFormatCode("mm:ss"))
        XCTAssertFalse(XLSXReader.isDateLikeFormatCode("General"))
        XCTAssertFalse(XLSXReader.isDateLikeFormatCode("#,##0.00"))
        // 引号里的 m 是字面量（`0.00"m"`），不能当成月份记号。
        XCTAssertFalse(XLSXReader.isDateLikeFormatCode("0.00\"m\""))
        XCTAssertFalse(XLSXReader.isDateLikeFormatCode("0.0%"))
    }

    // MARK: - 其它单元格类型

    func testFormulaCachedValues() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("orders.xlsx")).first)
        XCTAssertEqual(sheet.rows[3][2], "125", "公式取缓存值（不求值）")
        XCTAssertEqual(sheet.rows[3][5], "公式结果", "t=\"str\" 的公式结果同样取缓存值")
    }

    func testErrorValueKeptVerbatim() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("orders.xlsx")).first)
        XCTAssertEqual(sheet.rows[4][1], "#DIV/0!", "错误值原样保留（不能悄悄变 NULL）")
    }

    func testNullVersusEmptyString() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("orders.xlsx")).first)
        XCTAssertNil(sheet.rows[3][3], "整格缺省 = NULL")
        XCTAssertEqual(sheet.rows[2][5], "", "存在但内容为空 = 空字符串（与导出侧语义一致）")
    }

    func testSparseRowsAndColumns() throws {
        let sheet = try XCTUnwrap(try XLSXReader.sheets(try fixture("orders.xlsx")).first)
        XCTAssertEqual(sheet.rows[5].count, 8)
        XCTAssertEqual(sheet.rows[5][7], "稀疏", "第 6 行只有 H 列，前面的空列要补齐")
        XCTAssertNil(sheet.rows[5][0])
    }

    func testColumnReferenceParsing() {
        XCTAssertEqual(XLSXReader.columnIndex(fromReference: "A1"), 0)
        XCTAssertEqual(XLSXReader.columnIndex(fromReference: "Z9"), 25)
        XCTAssertEqual(XLSXReader.columnIndex(fromReference: "AA1"), 26)
        XCTAssertEqual(XLSXReader.columnIndex(fromReference: "H6"), 7)
        XCTAssertNil(XLSXReader.columnIndex(fromReference: "1"))
    }

    // MARK: - 导入入口

    func testImportResultHeaderAndRows() throws {
        let result = try XLSXReader.importResult(try fixture("orders.xlsx"), sheet: 0)
        // 表头 6 列有名，但表宽是 8（第 6 行 H 列有数据）—— **宽度以数据为准**，
        // 没有名字的表头列补 `columnN`：宁可多给两列（映射预览里会标成「文件里有、目标表没有」），
        // 也不能为了好看把 H 列的「稀疏」丢掉。
        XCTAssertEqual(result.header, ["id", "名称", "金额", "下单日期", "已付", "备注", "column7", "column8"])
        XCTAssertEqual(result.rows.count, 5)
        XCTAssertEqual(result.rows[0][1], "订单一")
        XCTAssertEqual(result.rows[1][3], "2024-01-06 12:00:00")
        XCTAssertEqual(result.rows[5 - 1][7], "稀疏", "第 6 行的 H 列不能因为表头没名字就丢")
    }

    /// 第二张表也能选（序号越界要报错，不能悄悄退回第一张）。
    func testSheetSelectionAndOutOfRange() throws {
        let second = try XLSXReader.importResult(try fixture("orders.xlsx"), sheet: 1)
        XCTAssertEqual(second.header, ["编号", "说明"])
        XCTAssertEqual(second.rows[0], ["X-1", "第二张表"])

        let data = try fixture("orders.xlsx")
        XCTAssertThrowsError(try XLSXReader.importResult(data, sheet: 5)) { error in
            XCTAssertEqual(error as? XLSXReaderError, .sheetIndexOutOfRange(5, available: 2))
        }
    }

    func testNonZipInputThrowsReadableError() {
        XCTAssertThrowsError(try XLSXReader.sheets(Data("这不是 xlsx".utf8))) { error in
            XCTAssertEqual(error as? XLSXReaderError, .notAZipArchive)
            // 错误信息要能解释「.xls / .et 不是 xlsx」，否则用户只会看到"读取失败"。
            XCTAssertTrue(error.localizedDescription.contains(".xls"))
        }
    }

    // MARK: - 与自己写的 xlsx 往返

    /// 导出 → 导入 的闭环：`NULL` 与空串、中文、前导零都要原样回来。
    func testRoundTripWithOwnWriter() throws {
        let columns = ["id", "名称", "编号串", "备注"]
        let rows: [[String?]] = [
            ["1", "中文，1990", "007-1234", "含 <标签> & 引号\""],
            ["2", "emoji 😀", nil, ""],
        ]
        let data = XLSXWriter.workbook(
            sheetName: "查询结果",
            columns: columns,
            rows: rows,
            numericColumns: [0]
        )
        let sheets = try XLSXReader.sheets(data)
        XCTAssertEqual(sheets.map(\.name), ["查询结果"])
        let result = XLSXReader.importResult(from: sheets[0])
        XCTAssertEqual(result.header, columns)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0], ["1", "中文，1990", "007-1234", "含 <标签> & 引号\""])
        XCTAssertEqual(result.rows[1][1], "emoji 😀")
        XCTAssertNil(result.rows[1][2], "NULL 必须还是 NULL")
        XCTAssertEqual(result.rows[1][3], "", "空串必须还是空串")
    }
}
