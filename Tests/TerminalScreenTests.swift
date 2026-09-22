import XCTest
@testable import DoyahCore

/// 终端屏幕模型的单测（VT100/xterm 子集）。
///
/// 这些用例是**照着真实终端的语义**写的，不是照着自己的实现抄的：
/// 延迟换行、CR 覆写、宽字符占两格、UTF-8 跨 chunk 等，
/// 每一条错了都会让真 shell 的界面看起来"花掉"。
final class TerminalScreenTests: XCTestCase {

    private func screen(columns: Int = 20, rows: Int = 5) -> TerminalScreen {
        TerminalScreen(columns: columns, rows: rows, scrollbackLimit: 100)
    }

    // MARK: 基本写入

    func testPlainTextAndLineFeed() {
        let s = screen()
        s.feed(text: "hello\r\nworld")
        XCTAssertEqual(s.line(0).map(\.displayText).joined().trimmed, "hello")
        XCTAssertEqual(s.line(1).map(\.displayText).joined().trimmed, "world")
        XCTAssertEqual(s.cursorRow, 1)
        XCTAssertEqual(s.cursorColumn, 5)
    }

    func testCarriageReturnOverwrites() {
        let s = screen()
        s.feed(text: "abcdef\rXY")
        XCTAssertEqual(s.line(0).map(\.displayText).joined().trimmed, "XYcdef")
    }

    func testBackspaceMovesCursorWithoutErasing() {
        let s = screen()
        s.feed(text: "abc\u{08}Z")
        // BS 只移光标，所以 'c' 被 'Z' 覆盖
        XCTAssertEqual(s.line(0).map(\.displayText).joined().trimmed, "abZ")
    }

    func testTabStopsEveryEightColumns() {
        let s = screen()
        s.feed(text: "a\tb")
        XCTAssertEqual(s.characterAt(row: 0, column: 8), "b")
    }

    /// 延迟换行：写满最后一列**不**立刻换行，否则每个整行输出都会多一个空行。
    func testDelayedAutoWrap() {
        let s = screen(columns: 5, rows: 3)
        s.feed(text: "abcde")
        XCTAssertEqual(s.cursorRow, 0, "写满最后一列时不应立刻换行")
        XCTAssertEqual(s.line(0).map(\.displayText).joined(), "abcde")

        s.feed(text: "f")
        XCTAssertEqual(s.cursorRow, 1, "下一个字符才换行")
        XCTAssertEqual(s.characterAt(row: 1, column: 0), "f")
    }

    // MARK: 光标与擦除

    func testCursorPosition() {
        let s = screen()
        s.feed(text: "one\r\ntwo\r\nthree")
        s.feed(text: "\u{1B}[2;3H") // CUP 第 2 行第 3 列（1 基）
        XCTAssertEqual(s.cursorRow, 1)
        XCTAssertEqual(s.cursorColumn, 2)
    }

    func testEraseInLine() {
        let s = screen()
        s.feed(text: "abcdef\u{1B}[3G") // 光标到第 3 列
        s.feed(text: "\u{1B}[K")        // EL 0：从光标清到行尾
        XCTAssertEqual(s.line(0).map(\.displayText).joined().trimmed, "ab")
    }

    func testEraseInDisplayClearsScreen() {
        let s = screen()
        s.feed(text: "aaa\r\nbbb\r\nccc")
        s.feed(text: "\u{1B}[2J")
        XCTAssertEqual(s.text().trimmed, "")
    }

    func testEraseInDisplayFromCursorDown() {
        let s = screen()
        s.feed(text: "aaa\r\nbbb\r\nccc")
        s.feed(text: "\u{1B}[2;1H\u{1B}[0J") // 第 2 行起向下清
        XCTAssertEqual(s.line(0).map(\.displayText).joined().trimmed, "aaa")
        XCTAssertEqual(s.line(1).map(\.displayText).joined().trimmed, "")
        XCTAssertEqual(s.line(2).map(\.displayText).joined().trimmed, "")
    }

    // MARK: 颜色与属性

    func testSGRBoldAndColors() {
        let s = screen()
        s.feed(text: "\u{1B}[1;31;44mX\u{1B}[0m")
        let cell = s.line(0)[0]
        XCTAssertTrue(cell.bold)
        XCTAssertEqual(cell.foreground, .indexed(1))
        XCTAssertEqual(cell.background, .indexed(4))
        XCTAssertEqual(s.line(0)[1].bold, false, "SGR 0 之后必须复位")
        XCTAssertEqual(s.line(0)[1].foreground, .default)
    }

    func testSGR256AndTrueColor() {
        let s = screen()
        s.feed(text: "\u{1B}[38;5;208mA\u{1B}[38;2;10;20;30mB")
        XCTAssertEqual(s.line(0)[0].foreground, .indexed(208))
        XCTAssertEqual(s.line(0)[1].foreground, .rgb(10, 20, 30))
    }

    // MARK: 宽字符

    func testWideCharactersOccupyTwoCells() {
        let s = screen()
        s.feed(text: "中文")
        XCTAssertEqual(s.characterAt(row: 0, column: 0), "中")
        XCTAssertEqual(s.line(0)[1].content, .continuation, "宽字符右半格是占位")
        XCTAssertEqual(s.characterAt(row: 0, column: 2), "文")
        XCTAssertEqual(s.cursorColumn, 4)
    }

    func testWideCharacterAtLastColumnWrapsFirst() {
        let s = screen(columns: 4, rows: 3)
        s.feed(text: "abc")   // 占满前 3 列
        s.feed(text: "中")     // 第 4 列放不下 → 先换行
        XCTAssertEqual(s.cursorRow, 1)
        XCTAssertEqual(s.characterAt(row: 1, column: 0), "中")
    }

    // MARK: UTF-8 分片

    func testUTF8SplitAcrossChunks() {
        let s = screen()
        let bytes = Array("中".utf8)
        s.feed([bytes[0]])
        s.feed([bytes[1]])
        s.feed([bytes[2]])
        XCTAssertEqual(s.characterAt(row: 0, column: 0), "中")
    }

    // MARK: 滚动与回滚

    func testScrollPushesLinesIntoScrollback() {
        let s = screen(columns: 10, rows: 2)
        s.feed(text: "one\r\ntwo\r\nthree")
        XCTAssertEqual(s.scrollbackCount, 1)
        XCTAssertEqual(s.scrollbackLine(0).map(\.displayText).joined().trimmed, "one")
        XCTAssertEqual(s.line(1).map(\.displayText).joined().trimmed, "three")
    }

    func testScrollbackIsCapped() {
        let s = TerminalScreen(columns: 10, rows: 2, scrollbackLimit: 3)
        for index in 0..<10 { s.feed(text: "line\(index)\r\n") }
        XCTAssertEqual(s.scrollbackCount, 3, "回滚缓冲必须按上限裁剪")
    }

    // MARK: 尺寸变化

    func testResizeKeepsContentAndClampsCursor() {
        let s = screen(columns: 10, rows: 4)
        s.feed(text: "hello\r\nworld")
        s.resize(columns: 6, rows: 2)
        XCTAssertEqual(s.columns, 6)
        XCTAssertEqual(s.rows, 2)
        XCTAssertLessThan(s.cursorRow, 2)
        XCTAssertLessThan(s.cursorColumn, 6)
        // 变宽时补齐空格，不越界
        s.resize(columns: 12, rows: 4)
        XCTAssertEqual(s.line(0).count, 12)
    }

    // MARK: 私有模式与复位

    func testCursorVisibilityPrivateMode() {
        let s = screen()
        s.feed(text: "\u{1B}[?25l")
        XCTAssertFalse(s.isCursorVisible)
        s.feed(text: "\u{1B}[?25h")
        XCTAssertTrue(s.isCursorVisible)
    }

    func testOSCTitleIsIgnoredNotPrinted() {
        let s = screen()
        s.feed(text: "\u{1B}]0;my title\u{07}ok")
        XCTAssertEqual(s.line(0).map(\.displayText).joined().trimmed, "ok")
    }

    func testResetClearsEverything() {
        let s = screen()
        s.feed(text: "abc\r\n\u{1B}[1;31mdef")
        s.feed(text: "\u{1B}c") // RIS
        XCTAssertEqual(s.text().trimmed, "")
        XCTAssertEqual(s.line(0)[0].foreground, .default)
        XCTAssertEqual(s.scrollbackCount, 0)
    }

    /// 宽字符宽度判定：中文 2 格、ASCII 1 格、emoji 2 格。
    func testCellWidthTable() {
        XCTAssertEqual(TerminalScreen.cellWidth("a"), 1)
        XCTAssertEqual(TerminalScreen.cellWidth("中"), 2)
        XCTAssertEqual(TerminalScreen.cellWidth("，"), 2)
        XCTAssertEqual(TerminalScreen.cellWidth("😀"), 2)
    }
}

private extension TerminalScreen {
    func characterAt(row: Int, column: Int) -> String? {
        guard line(row).indices.contains(column) else { return nil }
        return line(row)[column].character.map(String.init)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
