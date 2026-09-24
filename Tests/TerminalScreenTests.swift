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

    // MARK: 备用屏（?1049 / ?47）

    /// 备用屏的意义：全屏 TUI 的界面盖在主屏上，退出后主屏原样回来。
    /// 我们原先不支持它，于是 TUI 每一帧都画在主屏上、旧帧永不清除。
    func testAlternateScreenSavesAndRestoresMainContent() {
        let s = screen()
        s.feed(text: "main")
        s.feed(text: "\u{1B}[?1049h")
        XCTAssertTrue(s.isAlternateScreen)
        XCTAssertEqual(s.text().trimmed, "", "备用屏初始必须是空白")
        s.feed(text: "tui")
        XCTAssertEqual(s.text().trimmed, "tui")
        s.feed(text: "\u{1B}[?1049l")
        XCTAssertFalse(s.isAlternateScreen)
        XCTAssertEqual(s.text().trimmed, "main")
    }

    func testAlternateScreenRestoresCursor() {
        let s = screen()
        s.feed(text: "ab")
        let row = s.cursorRow
        let column = s.cursorColumn
        s.feed(text: "\u{1B}[?1049h")
        XCTAssertEqual(s.cursorRow, 0)
        XCTAssertEqual(s.cursorColumn, 0)
        s.feed(text: "xyz")
        s.feed(text: "\u{1B}[?1049l")
        XCTAssertEqual(s.cursorRow, row)
        XCTAssertEqual(s.cursorColumn, column)
    }

    /// `?47` 只切缓冲区、不保存光标（xterm 约定），与 `?1049` 区分开。
    func testMode47DoesNotRestoreCursor() {
        let s = screen()
        s.feed(text: "ab")
        s.feed(text: "\u{1B}[?47h")
        XCTAssertTrue(s.isAlternateScreen)
        s.feed(text: "xyz")
        s.feed(text: "\u{1B}[?47l")
        XCTAssertFalse(s.isAlternateScreen)
        XCTAssertEqual(s.cursorColumn, 3)
    }

    /// 备用屏上的滚屏**不得**灌进回滚区：TUI 每帧都在滚，
    /// 真灌进去会把回滚区变成它自己的界面垃圾场。
    func testAlternateScreenDoesNotPolluteScrollback() {
        let s = screen(columns: 20, rows: 3)
        s.feed(text: "\u{1B}[?1049h")
        for index in 0..<10 {
            s.feed(text: "line\(index)\r\n")
        }
        XCTAssertEqual(s.scrollbackCount, 0)
        s.feed(text: "\u{1B}[?1049l")
        XCTAssertEqual(s.scrollbackCount, 0)
    }

    /// 在 TUI 里改过窗口大小后回来，主屏要按当前尺寸补齐 / 裁剪，不能崩。
    func testAlternateScreenRestoresMainScreenAtCurrentSize() {
        let s = screen(columns: 20, rows: 3)
        s.feed(text: "main")
        s.feed(text: "\u{1B}[?1049h")
        s.resize(columns: 10, rows: 2)
        s.feed(text: "\u{1B}[?1049l")
        XCTAssertEqual(s.line(0).count, 10)
        XCTAssertEqual(s.text().trimmed, "main")
    }

    func testResetLeavesAlternateScreen() {
        let s = screen()
        s.feed(text: "\u{1B}[?1049h")
        XCTAssertTrue(s.isAlternateScreen)
        s.feed(text: "\u{1B}c")
        XCTAssertFalse(s.isAlternateScreen)
        XCTAssertEqual(s.maxScrollOffset, 0)
    }

    // MARK: 回滚区视口（显示偏移）

    private func viewportText(_ s: TerminalScreen, offset: Int, height: Int) -> [String] {
        s.visibleLines(offset: offset, height: height)
            .map { $0.map(\.displayText).joined().trimmed }
    }

    func testViewportOffsetZeroIsLiveScreen() {
        let s = screen(columns: 10, rows: 3)
        s.feed(text: "a\r\nb\r\nc")
        XCTAssertEqual(viewportText(s, offset: 0, height: 3), ["a", "b", "c"])
    }

    func testViewportScrollsBackIntoScrollback() {
        let s = screen(columns: 10, rows: 2)
        s.feed(text: "1\r\n2\r\n3\r\n4") // 回滚区: 1、2；屏幕: 3、4
        XCTAssertEqual(s.scrollbackCount, 2)
        XCTAssertEqual(viewportText(s, offset: 1, height: 2), ["2", "3"])
        XCTAssertEqual(viewportText(s, offset: 2, height: 2), ["1", "2"])
    }

    func testViewportClampsOffsetToScrollbackCount() {
        let s = screen(columns: 10, rows: 2)
        s.feed(text: "1\r\n2\r\n3")
        XCTAssertEqual(
            viewportText(s, offset: 99, height: 2),
            viewportText(s, offset: s.maxScrollOffset, height: 2)
        )
    }

    func testViewportPadsWhenHeightExceedsBuffer() {
        let s = screen(columns: 10, rows: 2)
        s.feed(text: "x")
        let lines = viewportText(s, offset: 0, height: 5)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[3], "x", "补的空行在前，内容贴底")
        XCTAssertEqual(lines[4], "")
    }

    func testAlternateScreenHasNoScrollbackOffset() {
        let s = screen(columns: 10, rows: 2)
        s.feed(text: "1\r\n2\r\n3")
        XCTAssertGreaterThan(s.maxScrollOffset, 0)
        s.feed(text: "\u{1B}[?1049h")
        XCTAssertEqual(s.maxScrollOffset, 0)
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


// MARK: - SGR 2 / 22：暗淡与「恢复正常强度」（FR-EDIT-29）

/// 单独一个类，避免与 `TerminalScreenTests` 的私有 helper 同名相撞。
final class TerminalDimAttributeTests: XCTestCase {

    private func screen(_ text: String) -> TerminalScreen {
        let screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(text: text)
        return screen
    }

    private func cell(_ terminal: TerminalScreen, _ column: Int) -> TerminalCell {
        terminal.line(0)[column]
    }

    /// SGR 2 = 暗淡（渲染时由 `TerminalPalette.dimmed` 把前景混向底色）。
    func testSGRTwoMarksDim() {
        let terminal = screen("\u{1B}[2mA\u{1B}[0mB")
        XCTAssertTrue(cell(terminal, 0).isDim)
        XCTAssertFalse(cell(terminal, 1).isDim)
    }

    /// SGR 22 = 恢复正常强度：粗体**与暗淡一起清**（标准如此，只清一半就会留下"暗的粗体"）。
    func testSGRTwentyTwoClearsBoldAndDimTogether() {
        let terminal = screen("\u{1B}[1;2mA\u{1B}[22mB")
        XCTAssertTrue(cell(terminal, 0).bold)
        XCTAssertTrue(cell(terminal, 0).isDim)
        XCTAssertFalse(cell(terminal, 1).bold)
        XCTAssertFalse(cell(terminal, 1).isDim)
    }

    /// `1;2` 并存：粗体与暗淡不是互斥开关。
    func testBoldAndDimCoexist() {
        let cell = self.cell(screen("\u{1B}[1;2mX"), 0)
        XCTAssertTrue(cell.bold)
        XCTAssertTrue(cell.isDim)
    }

    /// 复位（SGR 0）要把暗淡一起清掉。
    func testResetClearsDim() {
        let terminal = screen("\u{1B}[2mA\u{1B}[0mB")
        XCTAssertTrue(cell(terminal, 0).isDim)
        XCTAssertFalse(cell(terminal, 1).isDim)
    }
}

// MARK: - 扩展颜色的两种写法（FR-EDIT-29；对照 xterm ctlseqs 后补）

/// 交叉核对 xterm 控制序列文档时发现：`38` / `48` 有**两种合法写法** ——
/// 冒号形式（ISO-8613-6 / ECMA-48 5th 标注为"保留待标准化"）与分号形式
/// （xterm 为兼容 KDE konsole 额外接受）。原先只认分号形式，
/// 于是 `38:5:n` 这类写法会被整段忽略（颜色静默丢失）。
final class TerminalExtendedColorTests: XCTestCase {

    private func screen(_ text: String) -> TerminalScreen {
        let screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(text: text)
        return screen
    }

    private func cell(_ terminal: TerminalScreen, _ column: Int) -> TerminalCell {
        terminal.line(0)[column]
    }

    /// 分号形式（原有行为，不能回归）。
    func testSemicolonFormsStillWork() {
        XCTAssertEqual(cell(screen("\u{1B}[38;5;196mX"), 0).foreground, .indexed(196))
        XCTAssertEqual(cell(screen("\u{1B}[38;2;255;0;0mX"), 0).foreground, .rgb(255, 0, 0))
        XCTAssertEqual(cell(screen("\u{1B}[48;5;17mX"), 0).background, .indexed(17))
        XCTAssertEqual(cell(screen("\u{1B}[48;2;0;128;255mX"), 0).background, .rgb(0, 128, 255))
    }

    /// 冒号形式：索引色 `38:5:n`。
    func testColonIndexedForm() {
        XCTAssertEqual(cell(screen("\u{1B}[38:5:196mX"), 0).foreground, .indexed(196))
        XCTAssertEqual(cell(screen("\u{1B}[48:5:17mX"), 0).background, .indexed(17))
    }

    /// 冒号形式：真彩色 `38:2:Pi:Pr:Pg:Pb`（带颜色空间标识）。
    func testColonTrueColorWithColorSpaceIdentifier() {
        XCTAssertEqual(cell(screen("\u{1B}[38:2:0:255:0:0mX"), 0).foreground, .rgb(255, 0, 0))
        // 空字段（实践中很常见：`38:2::255:0:0`）会被收集成 0，仍然按 Pi 处理
        XCTAssertEqual(cell(screen("\u{1B}[38:2::255:0:0mX"), 0).foreground, .rgb(255, 0, 0))
    }

    /// 冒号形式：省略颜色空间标识的 `38:2:Pr:Pg:Pb` 也认。
    func testColonTrueColorWithoutColorSpaceIdentifier() {
        XCTAssertEqual(cell(screen("\u{1B}[38:2:10:20:30mX"), 0).foreground, .rgb(10, 20, 30))
    }

    /// 越界的数值要夹取而不是崩（`UInt8(clamping:)` 的口径）。
    func testOutOfRangeComponentsAreClamped() {
        XCTAssertEqual(cell(screen("\u{1B}[38;2;300;0;0mX"), 0).foreground, .rgb(255, 0, 0))
        XCTAssertEqual(cell(screen("\u{1B}[38;5;999mX"), 0).foreground, .indexed(255))
    }

    /// 认不出来的选择子（例如 `38:9`）不该把后面的普通参数吃掉。
    func testUnknownSelectorDoesNotSwallowFollowingParameters() {
        let terminal = screen("\u{1B}[38:9;1mX")
        // 颜色没被改（保持默认），但粗体（`1`）照常生效
        XCTAssertEqual(cell(terminal, 0).foreground, .default)
        XCTAssertTrue(cell(terminal, 0).bold)
    }
}
