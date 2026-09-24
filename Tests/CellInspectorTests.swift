import XCTest
@testable import DoyahCore

/// 值检查器（FR-DATA-05）：JSON 识别与美化、二进制摘要、长值截断口径。
///
/// 判据的边界是这一项的重点：**JSON 识别太宽会把半截日志当 JSON**，
/// **截断不说长度会让用户以为拿到的是全部**。
final class CellInspectorTests: XCTestCase {

    // MARK: NULL 与空串

    func testNullAndEmptyAreDistinct() {
        XCTAssertEqual(CellInspector.inspect(nil).shape, .null)
        XCTAssertEqual(CellInspector.inspect(nil).display, "NULL")
        XCTAssertEqual(CellInspector.inspect("").shape, .empty)
        XCTAssertEqual(CellInspector.inspect("").display, "")
        XCTAssertNotEqual(CellInspector.inspect(nil).shape, CellInspector.inspect("").shape)
    }

    /// 摘要要能一眼看出形态（状态栏 / 列表用）。
    func testSummaryText() {
        XCTAssertEqual(CellInspector.inspect(nil).summary(), "NULL")
        XCTAssertEqual(CellInspector.inspect("").summary(), "空字符串")
        XCTAssertTrue(CellInspector.inspect(#"{"a":1}"#).summary().contains("JSON 对象"))
        XCTAssertTrue(CellInspector.inspect(#"[1,2]"#).summary().contains("JSON 数组"))
        XCTAssertTrue(CellInspector.inspect("hello").summary().contains("文本"))
    }

    // MARK: JSON 识别（边界）

    func testJSONObjectAndArrayAreDetectedAndPrettyPrinted() {
        let object = CellInspector.inspect(#"{"b":1,"a":[2,3]}"#)
        XCTAssertEqual(object.shape, .jsonObject)
        // 键排序后稳定输出，且真的换行了
        XCTAssertTrue(object.display.contains("\n"), object.display)
        XCTAssertTrue(object.display.contains("\"a\""), object.display)

        XCTAssertEqual(CellInspector.inspect(#"[1,2,3]"#).shape, .jsonArray)
    }

    /// **半截 JSON 不能被当成 JSON**：真实数据里很常见（日志截断），
    /// 当 JSON 会显示解析错误，远不如按文本显示。
    func testBrokenJSONFallsBackToText() {
        XCTAssertEqual(CellInspector.inspect("{不是 JSON}").shape, .text)
        XCTAssertEqual(CellInspector.inspect("[未闭合").shape, .text)
        XCTAssertEqual(CellInspector.inspect(#"{"a":}"#).shape, .text)
    }

    /// 标量不要被硬说成"JSON"却不给出形态 —— 数字 / true / null 归到标量档。
    func testScalarJSONIsItsOwnShape() {
        XCTAssertEqual(CellInspector.inspect("123").shape, .scalarJSON)
        XCTAssertEqual(CellInspector.inspect("true").shape, .scalarJSON)
        XCTAssertEqual(CellInspector.inspect("null").shape, .scalarJSON)
        XCTAssertEqual(CellInspector.inspect("123").display, "123")
        // 普通文本仍然是文本
        XCTAssertEqual(CellInspector.inspect("12abc").shape, .text)
        XCTAssertEqual(CellInspector.inspect("hello").shape, .text)
    }

    func testJSONWithUnicodeKeepsCharacters() {
        let value = CellInspector.inspect(#"{"名称":"鲸鱼娘","emoji":"🐋"}"#)
        XCTAssertEqual(value.shape, .jsonObject)
        XCTAssertTrue(value.display.contains("鲸鱼娘"), value.display)
        XCTAssertTrue(value.display.contains("🐋"), value.display)
    }

    // MARK: 二进制

    func testByteaHexIsSummarized() {
        let value = CellInspector.inspect(#"\x48656c6c6f"#)
        XCTAssertEqual(value.shape, .binary(byteCount: 5))
        XCTAssertTrue(value.summary().contains("二进制 5 字节"), value.summary())
        XCTAssertEqual(value.display, #"\x48656c6c6f"#, "短值原样显示，不截")
    }

    func testLongByteaIsPreviewed() {
        let long = "\\x" + String(repeating: "ab", count: 40)
        let value = CellInspector.inspect(long)
        XCTAssertEqual(value.shape, .binary(byteCount: 40))
        XCTAssertTrue(value.isTruncated)
        XCTAssertTrue(value.display.hasSuffix("…"))
        XCTAssertEqual(value.originalCharacterCount, long.count)
    }

    /// `\x` 后面不是合法十六进制 → 不是二进制（别把普通文本误判）。
    func testMalformedHexIsNotBinary() {
        XCTAssertEqual(CellInspector.inspect(#"\xzz"#).shape, .text)
        XCTAssertEqual(CellInspector.inspect(#"\xabc"#).shape, .text, "奇数个十六进制字符不是 bytea")
        XCTAssertEqual(CellInspector.inspect(#"\x"#).shape, .text)
        XCTAssertEqual(CellInspector.inspect("x4865").shape, .text)
    }

    // MARK: 截断与长度

    /// **截断必须说清原始长度**：只说"…"会让用户以为拿到的就是全部。
    func testLongTextIsTruncatedWithOriginalLengthReported() {
        let long = String(repeating: "鲸", count: 100)
        let value = CellInspector.inspect(long, displayLimit: 10)
        XCTAssertTrue(value.isTruncated)
        XCTAssertEqual(value.originalCharacterCount, 100, "原始字符数要如实报告")
        XCTAssertEqual(value.originalByteCount, 300, "UTF-8 字节数（鲸 = 3 字节）")
        XCTAssertTrue(value.summary().contains("已截断"), value.summary())
        // 展示文本按**字符**截断，不会把多字节字符切成半个
        XCTAssertEqual(value.display.count, 11, "10 个字符 + 省略号")
    }

    func testLongJSONIsTruncatedButKeepsShape() {
        let json = #"{"a":""# + String(repeating: "x", count: 500) + #""}"#
        let value = CellInspector.inspect(json, displayLimit: 50)
        XCTAssertEqual(value.shape, .jsonObject, "截断不该改变形态判定")
        XCTAssertTrue(value.isTruncated)
        XCTAssertEqual(value.originalCharacterCount, json.count)
    }

    func testLineCountIsReported() {
        XCTAssertEqual(CellInspector.inspect("a\nb\nc").lineCount, 3)
        XCTAssertEqual(CellInspector.inspect(#"{"a":1,"b":2}"#).lineCount, 1, "原始文本是单行（美化后才是多行）")
        XCTAssertTrue(CellInspector.inspect("a\nb").summary().contains("2 行"))
    }

    // MARK: 单行竖排

    /// 单行详情按**列顺序**给出，缺列不崩、越界的行按 NULL 处理。
    func testRowFieldsFollowColumnOrder() {
        let columns = [
            ColumnMeta(id: 0, name: "id", typeName: "integer"),
            ColumnMeta(id: 1, name: "payload", typeName: "jsonb"),
            ColumnMeta(id: 2, name: "blob", typeName: "bytea"),
        ]
        let fields = CellInspector.row(columns: columns, row: ["1", #"{"k":1}"#, #"\x00ff"#])
        XCTAssertEqual(fields.map(\.columnName), ["id", "payload", "blob"])
        XCTAssertEqual(fields[0].value.shape, .scalarJSON)
        XCTAssertEqual(fields[1].value.shape, .jsonObject)
        XCTAssertEqual(fields[2].value.shape, .binary(byteCount: 2))

        // 行比列短：缺的按 NULL，不越界崩溃
        let short = CellInspector.row(columns: columns, row: ["1"])
        XCTAssertEqual(short.count, 3)
        XCTAssertEqual(short[1].value.shape, .null)
        XCTAssertEqual(short[2].value.shape, .null)
    }

    func testEmptyRowGivesAllNulls() {
        let columns = [ColumnMeta(id: 0, name: "a", typeName: "text")]
        XCTAssertEqual(CellInspector.row(columns: columns, row: [])[0].value.shape, .null)
    }
}
