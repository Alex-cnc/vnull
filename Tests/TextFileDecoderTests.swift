import XCTest
@testable import DoyahCore

/// 导入侧文本解码（FR-IO-07 的对称面）：BOM 优先 → 严格 UTF-8 → GB18030。
///
/// 这组用例的价值在于**中文 Windows 的真实文件**：从 Excel / WPS 另存的 CSV 就是
/// 本地代码页（GBK）；只按 UTF-8 读会失败，而"失败"在导入功能里就是用户拿到
/// 一句"读取文件失败"，连哪一步错了都看不出来。
final class TextFileDecoderTests: XCTestCase {

    func testUTF8WithBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("id,名称\r\n1,中文\r\n".utf8)
        let decoded = try TextFileDecoder.decode(data)
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertTrue(decoded.hadByteOrderMark)
        XCTAssertFalse(decoded.isFallback)
        XCTAssertEqual(decoded.text, "id,名称\r\n1,中文\r\n", "BOM 必须被剥掉，否则第一个列名会带一个看不见的字符")
    }

    func testUTF8WithoutBOM() throws {
        let data = Data("id,名称\r\n1,中文\r\n".utf8)
        let decoded = try TextFileDecoder.decode(data)
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertFalse(decoded.hadByteOrderMark)
    }

    func testGB18030Fallback() throws {
        try XCTSkipUnless(ResultExportEncoding.gb18030.isAvailable, "本机 Foundation 没有 GB18030 编码器")
        // 手工拼一份 GBK 字节（不经过我们的编码器，避免"自己验自己"）：
        // `中文` = D6 D0 CE C4（GB2312 码表）。
        let data = Data([0x69, 0x64, 0x2C, 0xD6, 0xD0, 0xCE, 0xC4, 0x0D, 0x0A])
        let decoded = try TextFileDecoder.decode(data)
        XCTAssertEqual(decoded.encoding, .gb18030)
        XCTAssertTrue(decoded.isFallback, "不是 UTF-8 就要让调用方能提示一句")
        XCTAssertEqual(decoded.text, "id,中文\r\n")
    }

    func testPureASCIIDecodesAsUTF8() throws {
        let decoded = try TextFileDecoder.decode(Data("id,name\n1,a\n".utf8))
        XCTAssertEqual(decoded.encoding, .utf8, "纯 ASCII 两种编码等价：不该白白回退")
    }

    func testBinaryBytesAreRejected() {
        // 0xFF 在 UTF-8 与 GB18030 里都不是合法起始字节。
        XCTAssertThrowsError(try TextFileDecoder.decode(Data([0xFF, 0xFE, 0x00, 0x01, 0xFF]))) { error in
            XCTAssertEqual(error as? TextFileDecodingError, .unreadable)
        }
    }

    /// 闭环：自己导出的 GB18030 CSV，自己必须读得回来（且值与列名逐个相等）。
    func testOwnGB18030ExportRoundTripsThroughImportDecoder() throws {
        try XCTSkipUnless(ResultExportEncoding.gb18030.isAvailable, "本机 Foundation 没有 GB18030 编码器")
        let columns = [ColumnMeta(id: 0, name: "id"), ColumnMeta(id: 1, name: "名称")]
        let rows: [[String?]] = [["1", "中文，1990"], ["2", "emoji 😀"]]
        let model = QueryResult(columns: columns, rows: rows)
        let data = try ResultExporter.data(for: model, format: .csv, encoding: .gb18030)

        let decoded = try TextFileDecoder.decode(data)
        XCTAssertEqual(decoded.encoding, .gb18030)
        let parsed = DelimitedTextReader.read(decoded.text, options: .csv)
        XCTAssertEqual(parsed.header, ["id", "名称"])
        XCTAssertEqual(parsed.rows.count, 2)
        XCTAssertEqual(parsed.rows[0], ["1", "中文，1990"])
        XCTAssertEqual(parsed.rows[1], ["2", "emoji 😀"], "GB18030 的四字节序列也要能原样读回")
    }
}
