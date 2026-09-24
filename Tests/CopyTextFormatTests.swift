import XCTest
@testable import DoyahCore

/// `COPY … FROM STDIN` 的 text 格式编解码（FR-IO-03 的 COPY 路径）。
///
/// 这一层写错的症状是"**看着成功、数据已错**"：NULL 变成空串、值里的反斜杠悄悄少一层。
/// 所以规则逐条钉死。
final class CopyTextFormatTests: XCTestCase {

    /// NULL 与空串**只差一个字符**，绝不能混。
    func testNullAndEmptyStringAreDifferent() {
        XCTAssertEqual(CopyTextFormat.escape(nil), "\\N")
        XCTAssertEqual(CopyTextFormat.escape(""), "")
        XCTAssertNil(CopyTextFormat.unescape("\\N"))
        XCTAssertEqual(CopyTextFormat.unescape(""), "")
    }

    func testEscapesTabNewlineCarriageReturnAndBackslash() {
        XCTAssertEqual(CopyTextFormat.escape("a\tb"), "a\\tb")
        XCTAssertEqual(CopyTextFormat.escape("a\nb"), "a\\nb")
        XCTAssertEqual(CopyTextFormat.escape("a\rb"), "a\\rb")
        XCTAssertEqual(CopyTextFormat.escape("C:\\temp"), "C:\\\\temp")
    }

    /// 反斜杠必须**先**转义：否则 `\t`（真制表符）转出来会被再转义成 `\\t`（字面反斜杠 + t）。
    func testBackslashIsEscapedBeforeOthers() {
        XCTAssertEqual(CopyTextFormat.escape("\\\t"), "\\\\\\t")
        XCTAssertEqual(CopyTextFormat.unescape("\\\\\\t"), "\\\t")
    }

    func testRoundTripOnNastyValues() {
        let rows: [[String?]] = [
            ["plain", "with\ttab", "with\nnewline"],
            [nil, "", "with\\backslash"],
            ["中文", "it's", "quote\"inside"]
        ]
        let encoded = CopyTextFormat.encode(rows: rows)
        XCTAssertEqual(CopyTextFormat.decode(encoded), rows, "往返必须逐值相等：\(encoded)")
    }

    func testRowEncodingUsesTabSeparatorAndTrailingNewline() {
        XCTAssertEqual(CopyTextFormat.encode(row: ["a", nil, ""]), "a\t\\N\t")
        XCTAssertEqual(CopyTextFormat.encode(rows: [["a", "b"], ["c", "d"]]), "a\tb\nc\td\n")
    }

    /// 空输入不该产生"一行空值"。
    func testEmptyRowsEncodeToEmptyString() {
        XCTAssertEqual(CopyTextFormat.encode(rows: []), "")
        XCTAssertEqual(CopyTextFormat.decode(""), [])
    }

    /// 结尾悬着的反斜杠按字面处理，不吞掉。
    func testTrailingBackslashIsNotSwallowed() {
        XCTAssertEqual(CopyTextFormat.unescape("abc\\"), "abc\\")
    }

    /// 未知转义序列按字面字符处理（COPY 里 `\x` 这类就是字面 x）。
    func testUnknownEscapeKeepsCharacter() {
        XCTAssertEqual(CopyTextFormat.unescape("a\\qb"), "aqb")
    }
}
