import XCTest
@testable import DoyahCore

/// 终端输入编码与设备应答（FR-EDIT-29）：鼠标上报、DECCKM、DA1 / DA2 / DSR / DECRQM / XTVERSION。
///
/// 这里逐字节钉住的是**规范给出的字节形状**（xterm ctlseqs / ECMA-48）——
/// 这些东西错一位，前台程序收到的就是另一个事件（例如把"松开"读成"右键按下"），
/// 而界面上完全看不出来。
final class TerminalInputTests: XCTestCase {

    private func string(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    // MARK: - DECCKM

    func testCursorKeysFollowDECCKM() {
        XCTAssertEqual(string(TerminalInput.cursorKey(.up, applicationCursorKeys: false)), "\u{1B}[A")
        XCTAssertEqual(string(TerminalInput.cursorKey(.up, applicationCursorKeys: true)), "\u{1B}OA")
        XCTAssertEqual(string(TerminalInput.cursorKey(.down, applicationCursorKeys: true)), "\u{1B}OB")
        XCTAssertEqual(string(TerminalInput.cursorKey(.right, applicationCursorKeys: true)), "\u{1B}OC")
        XCTAssertEqual(string(TerminalInput.cursorKey(.left, applicationCursorKeys: true)), "\u{1B}OD")
        XCTAssertEqual(string(TerminalInput.cursorKey(.home, applicationCursorKeys: true)), "\u{1B}OH")
        XCTAssertEqual(string(TerminalInput.cursorKey(.end, applicationCursorKeys: true)), "\u{1B}OF")
    }

    // MARK: - 鼠标上报

    func testSGRMouseEncoding() {
        func report(_ action: TerminalInput.MouseAction, _ button: TerminalInput.MouseButton,
                    modifiers: TerminalInput.MouseModifiers = [], column: Int, row: Int) -> String {
            string(TerminalInput.mouseReport(
                .init(action: action, button: button, modifiers: modifiers, column: column, row: row),
                sgr: true
            ))
        }
        XCTAssertEqual(report(.press, .left, column: 10, row: 5), "\u{1B}[<0;10;5M")
        // SGR 的好处之一：松开也带按钮号，分得清松的是哪个键（旧式编码做不到）。
        XCTAssertEqual(report(.release, .left, column: 10, row: 5), "\u{1B}[<0;10;5m")
        XCTAssertEqual(report(.release, .right, column: 10, row: 5), "\u{1B}[<2;10;5m")
        XCTAssertEqual(report(.press, .middle, column: 3, row: 2), "\u{1B}[<1;3;2M")
        XCTAssertEqual(report(.press, .right, column: 1, row: 1), "\u{1B}[<2;1;1M")
        // 移动 = 按钮码 + 32；修饰键 ⇧4 / ⌥8 / ⌃16。
        XCTAssertEqual(report(.motion, .left, column: 12, row: 6), "\u{1B}[<32;12;6M")
        XCTAssertEqual(report(.press, .left, modifiers: [.shift, .control], column: 1, row: 2), "\u{1B}[<20;1;2M")
        XCTAssertEqual(report(.wheelUp, .left, column: 4, row: 4), "\u{1B}[<64;4;4M")
        XCTAssertEqual(report(.wheelDown, .left, column: 4, row: 4), "\u{1B}[<65;4;4M")
    }

    func testLegacyMouseEncoding() {
        func report(_ action: TerminalInput.MouseAction, _ button: TerminalInput.MouseButton,
                    column: Int, row: Int) -> [UInt8] {
            TerminalInput.mouseReport(
                .init(action: action, button: button, column: column, row: row),
                sgr: false
            )
        }
        // 旧式：`ESC [ M` + (32+按钮码)(32+列)(32+行)，全部 1 基。
        XCTAssertEqual(report(.press, .left, column: 10, row: 5), [0x1B, 0x5B, 0x4D, 32, 42, 37])
        // 松开统一用按钮码 3（旧式编码表达不出"哪个键松开"）——这是规范本身的上限。
        XCTAssertEqual(report(.release, .right, column: 10, row: 5), [0x1B, 0x5B, 0x4D, 35, 42, 37])
        XCTAssertEqual(report(.motion, .left, column: 12, row: 6), [0x1B, 0x5B, 0x4D, 64, 44, 38])
        XCTAssertEqual(report(.wheelUp, .left, column: 4, row: 4), [0x1B, 0x5B, 0x4D, 96, 36, 36])
    }

    /// 旧式编码的坐标上限是 223（32 + 191）—— 超出时**截断**，不能回绕成别的按钮 / 坐标。
    func testLegacyMouseClampsLargeCoordinates() {
        let report = TerminalInput.mouseReport(
            .init(action: .press, button: .left, column: 500, row: 400),
            sgr: false
        )
        XCTAssertEqual(report, [0x1B, 0x5B, 0x4D, 32, 223, 223])
        // SGR 没有这个限制（这正是 SGR 存在的理由之一）。
        XCTAssertEqual(
            string(TerminalInput.mouseReport(.init(action: .press, button: .left, column: 500, row: 400), sgr: true)),
            "\u{1B}[<0;500;400M"
        )
    }

    func testShouldReportPerTrackingMode() {
        let press = TerminalInput.MouseEvent(action: .press, button: .left, column: 1, row: 1)
        let release = TerminalInput.MouseEvent(action: .release, button: .left, column: 1, row: 1)
        let motion = TerminalInput.MouseEvent(action: .motion, button: .left, column: 1, row: 1)
        let wheel = TerminalInput.MouseEvent(action: .wheelUp, button: .left, column: 1, row: 1)

        for event in [press, release, wheel] {
            XCTAssertFalse(TerminalInput.shouldReport(event, mode: .none))
            XCTAssertTrue(TerminalInput.shouldReport(event, mode: .click))
        }
        XCTAssertFalse(TerminalInput.shouldReport(motion, mode: .none))
        XCTAssertFalse(TerminalInput.shouldReport(motion, mode: .click), "?1000 不报移动")
        XCTAssertTrue(TerminalInput.shouldReport(motion, mode: .buttonEvent), "?1002 按住拖动要报")
        XCTAssertTrue(TerminalInput.shouldReport(motion, mode: .anyEvent))
    }

    // MARK: - 设备查询应答

    func testDeviceAttributes() {
        XCTAssertEqual(string(TerminalInput.primaryDeviceAttributes()), "\u{1B}[?1;2c")
        // DA2 的版本号写 0（不冒充 xterm 的高版本），让程序走保守分支。
        XCTAssertEqual(string(TerminalInput.secondaryDeviceAttributes()), "\u{1B}[>0;0;0c")
    }

    func testStatusAndCursorPositionReport() {
        XCTAssertEqual(string(TerminalInput.statusReportOK()), "\u{1B}[0n")
        XCTAssertEqual(string(TerminalInput.cursorPositionReport(row: 7, column: 3)), "\u{1B}[7;3R")
        // 0 或负数一律夹到 1：CPR 的坐标是 1 基，回 0 会让程序算出负的偏移。
        XCTAssertEqual(string(TerminalInput.cursorPositionReport(row: 0, column: -5)), "\u{1B}[1;1R")
    }

    func testModeReport() {
        XCTAssertEqual(
            string(TerminalInput.modeReport(parameter: 1000, isPrivate: true, state: .set)),
            "\u{1B}[?1000;1$y"
        )
        XCTAssertEqual(
            string(TerminalInput.modeReport(parameter: 25, isPrivate: true, state: .reset)),
            "\u{1B}[?25;2$y"
        )
        XCTAssertEqual(
            string(TerminalInput.modeReport(parameter: 4, isPrivate: false, state: .notRecognized)),
            "\u{1B}[4;0$y"
        )
    }

    func testTerminalVersionUsesDCSString() {
        XCTAssertEqual(string(TerminalInput.terminalVersion(name: "DoyahStudio 1.0")), "\u{1B}P>|DoyahStudio 1.0\u{1B}\\")
    }
}
