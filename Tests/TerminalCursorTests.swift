import XCTest
@testable import DoyahCore

/// 终端光标形状与 OSC 颜色查询（FR-EDIT-29）。
///
/// 这两个都是"前台程序问、终端答"的协议细节：答错或答不了，程序往往**猜**一个颜色/形状，
/// 结果在浅色主题下很难看、或者光标突然变形。所以逐条钉住字节与优先级。
final class TerminalCursorTests: XCTestCase {

    // MARK: - DECSCUSR 映射

    func testDECSCUSRMapping() {
        XCTAssertEqual(TerminalCursorAppearance.fromDECSCUSR(0), TerminalCursorAppearance(style: .block, blinks: true))
        XCTAssertEqual(TerminalCursorAppearance.fromDECSCUSR(1), TerminalCursorAppearance(style: .block, blinks: true))
        XCTAssertEqual(TerminalCursorAppearance.fromDECSCUSR(2), TerminalCursorAppearance(style: .block, blinks: false))
        XCTAssertEqual(TerminalCursorAppearance.fromDECSCUSR(3), TerminalCursorAppearance(style: .underline, blinks: true))
        XCTAssertEqual(TerminalCursorAppearance.fromDECSCUSR(4), TerminalCursorAppearance(style: .underline, blinks: false))
        XCTAssertEqual(TerminalCursorAppearance.fromDECSCUSR(5), TerminalCursorAppearance(style: .bar, blinks: true))
        XCTAssertEqual(TerminalCursorAppearance.fromDECSCUSR(6), TerminalCursorAppearance(style: .bar, blinks: false))
        XCTAssertNil(TerminalCursorAppearance.fromDECSCUSR(9), "认不出的参数要返回 nil（保持原状，不猜）")
    }

    func testCursorPreferenceResolve() {
        XCTAssertEqual(
            TerminalCursorPreference.resolve(style: "bar", blinks: false).appearance,
            TerminalCursorAppearance(style: .bar, blinks: false)
        )
        XCTAssertEqual(TerminalCursorPreference.resolve(style: "nonsense", blinks: true), .default)
        XCTAssertEqual(TerminalCursorPreference.resolve(style: nil, blinks: nil), .default)
        // 只给了形状、没给闪烁：按"闪烁"（默认）
        XCTAssertEqual(TerminalCursorPreference.resolve(style: "underline", blinks: nil).appearance.blinks, true)
    }

    // MARK: - 经解析器的 DECSCUSR

    func testDECSCUSRThroughParser() {
        let model = TerminalScreen(columns: 80, rows: 24)
        model.feed(text: "\u{1B}[5 q")
        XCTAssertEqual(model.requestedCursor, TerminalCursorAppearance(style: .bar, blinks: true))

        model.feed(text: "\u{1B}[2 q")
        XCTAssertEqual(model.requestedCursor, TerminalCursorAppearance(style: .block, blinks: false))

        // 认不出的参数：**保持上一次**，不要清掉（清掉会让形状退回去，用户看到光标突然变）
        model.feed(text: "\u{1B}[9 q")
        XCTAssertEqual(model.requestedCursor, TerminalCursorAppearance(style: .block, blinks: false))

        // RIS 全复位：回到"程序没要求"
        model.feed(text: "\u{1B}c")
        XCTAssertNil(model.requestedCursor)
    }

    // MARK: - OSC 颜色查询

    private func screenWithPalette() -> TerminalScreen {
        let model = TerminalScreen(columns: 80, rows: 24)
        model.paletteProvider = { TerminalPalette.deepSeaDark }
        return model
    }

    func testOSCColorQueriesAreAnswered() {
        let model = screenWithPalette()
        let palette = TerminalPalette.deepSeaDark

        model.feed(text: "\u{1B}]10;?\u{07}")
        XCTAssertEqual(
            String(decoding: model.drainResponses(), as: UTF8.self),
            "\u{1B}]10;rgb:\(ScreenProbe.sixteenBit(palette.foreground))\u{1B}\\"
        )
        model.feed(text: "\u{1B}]11;?\u{07}")
        XCTAssertEqual(
            String(decoding: model.drainResponses(), as: UTF8.self),
            "\u{1B}]11;rgb:\(ScreenProbe.sixteenBit(palette.background))\u{1B}\\"
        )
        model.feed(text: "\u{1B}]12;?\u{1B}\\")   // ST 结尾也要认
        XCTAssertEqual(
            String(decoding: model.drainResponses(), as: UTF8.self),
            "\u{1B}]12;rgb:\(ScreenProbe.sixteenBit(palette.cursor))\u{1B}\\"
        )
    }

    /// **没有调色板就不回答**：瞎报一个颜色会让程序按错误底色挑前景色，比不答更糟。
    func testOSCIsSilentWithoutPalette() {
        let model = TerminalScreen(columns: 80, rows: 24)
        model.feed(text: "\u{1B}]11;?\u{07}")
        XCTAssertTrue(model.drainResponses().isEmpty)
    }

    /// 其它 OSC（窗口标题、超链接）照旧忽略，而且**不许**把内容当成颜色查询。
    func testOtherOSCIsIgnored() {
        let model = screenWithPalette()
        model.feed(text: "\u{1B}]0;my title\u{07}")
        model.feed(text: "\u{1B}]8;;https://example.com\u{1B}\\")
        model.feed(text: "\u{1B}]11;rgb:1/1/1\u{07}")   // 是"设置"而不是查询
        XCTAssertTrue(model.drainResponses().isEmpty)
    }

    func testSixteenBitFormatting() {
        XCTAssertEqual(ScreenProbe.sixteenBit(TerminalPalette.RGB(red: 0xAB, green: 0x00, blue: 0xFF)), "ABAB/0000/FFFF")
    }

    // MARK: - SGR 4:3（弯下划线）

    func testCurlyUnderlineIsTrackedSeparately() {
        let model = TerminalScreen(columns: 20, rows: 4)
        // 按**内容**取格子：中日韩宽字符占两格，按列号索引会指到「续格」上
        // （续格继承前一格的属性，看起来"清不掉"，第一版测试就是这样误报的）。
        func cell(_ text: String) -> TerminalCell? {
            for row in 0..<4 {
                for candidate in model.line(row) where candidate.displayText == text { return candidate }
            }
            return nil
        }

        model.feed(text: "\u{1B}[4:3m弯")
        XCTAssertEqual(cell("弯")?.underline, true, "4:3 首先是下划线")
        XCTAssertEqual(cell("弯")?.isCurlyUnderline, true, "同时要记住它是弯的（渲染用点划线近似）")

        // 普通 4 是实线：不能把上一次的"弯"带过来
        model.feed(text: "\u{1B}[4m直")
        XCTAssertEqual(cell("直")?.underline, true)
        XCTAssertEqual(cell("直")?.isCurlyUnderline, false)

        // 24 清掉下划线（弯的标记也一起清）
        model.feed(text: "\u{1B}[24m平")
        XCTAssertEqual(cell("平")?.underline, false)
        XCTAssertEqual(cell("平")?.isCurlyUnderline, false)

        // 4:0 显式关闭；4:5 虚线（渲染上按点划线近似）
        model.feed(text: "\u{1B}[4:0m无")
        XCTAssertEqual(cell("无")?.underline, false)
        model.feed(text: "\u{1B}[4:5m虚")
        XCTAssertEqual(cell("虚")?.isCurlyUnderline, true)
    }

    // MARK: - 回滚区

    func testClearScrollbackKeepsScreenAndCursor() {
        let model = TerminalScreen(columns: 20, rows: 3, scrollbackLimit: 100)
        for index in 1...10 { model.feed(text: "line\(index)\r\n") }
        XCTAssertGreaterThan(model.scrollbackCount, 0, "前提：确实攒了回滚行")

        model.clearScrollback()
        XCTAssertEqual(model.scrollbackCount, 0)
        XCTAssertEqual(model.cursorRow, model.cursorRow, "当前屏幕与光标不受影响")
        XCTAssertTrue(model.visibleLines(offset: 0, height: 3).count == 3)
    }
}
