import XCTest
@testable import DoyahCore

/// 终端模式位与查询应答**经由解析器**的行为（FR-EDIT-29）。
///
/// 与 `TerminalInputTests` 的分工：那边验纯函数的字节形状，这边验"把真实转义序列喂进屏幕模型之后，
/// 模式位对不对、要不要回话、回什么" —— 也就是解析器那一层。两层都对了，"vim 里方向键能用、
/// 鼠标能点、界面不卡住"才有依据。
final class TerminalModeTests: XCTestCase {

    private func screen() -> TerminalScreen { TerminalScreen(columns: 80, rows: 24) }
    private func string(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    // MARK: - 模式位

    func testDECCKMAndOriginAndFocusModes() {
        let model = screen()
        model.feed(text: "\u{1B}[?1h\u{1B}[?6h\u{1B}[?1004h")
        XCTAssertTrue(model.isApplicationCursorKeysEnabled)
        XCTAssertTrue(model.isOriginModeEnabled)
        XCTAssertTrue(model.isFocusReportingEnabled)

        model.feed(text: "\u{1B}[?1l\u{1B}[?6l\u{1B}[?1004l")
        XCTAssertFalse(model.isApplicationCursorKeysEnabled)
        XCTAssertFalse(model.isOriginModeEnabled)
        XCTAssertFalse(model.isFocusReportingEnabled)
    }

    /// 三个鼠标模式互斥：置位谁切到谁；复位**只关掉自己**（`?1003l` 不该把 `?1002` 也关了）。
    func testMouseTrackingModesAreMutuallyExclusive() {
        let model = screen()
        model.feed(text: "\u{1B}[?1000h")
        XCTAssertEqual(model.mouseTrackingMode, .click)
        XCTAssertTrue(model.isMouseReportingActive)

        model.feed(text: "\u{1B}[?1002h")
        XCTAssertEqual(model.mouseTrackingMode, .buttonEvent, "换模式应当直接切换")

        model.feed(text: "\u{1B}[?1003l")
        XCTAssertEqual(model.mouseTrackingMode, .buttonEvent, "关掉不是当前模式的 ?1003 不该影响 ?1002")

        model.feed(text: "\u{1B}[?1002l")
        XCTAssertEqual(model.mouseTrackingMode, .none)
        XCTAssertFalse(model.isMouseReportingActive)
    }

    func testSGRMouseModeTracking() {
        let model = screen()
        XCTAssertFalse(model.isSGRMouseEnabled)
        model.feed(text: "\u{1B}[?1006h")
        XCTAssertTrue(model.isSGRMouseEnabled)
        model.feed(text: "\u{1B}[?1006l")
        XCTAssertFalse(model.isSGRMouseEnabled)
    }

    /// RIS（`ESC c`）是全复位：模式位必须一起清掉，否则下一个前台程序会继承上一个的状态。
    func testRISResetsNewModes() {
        let model = screen()
        model.feed(text: "\u{1B}[?1h\u{1B}[?6h\u{1B}[?1004h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?2004h")
        model.feed(text: "\u{1B}c")
        XCTAssertFalse(model.isApplicationCursorKeysEnabled)
        XCTAssertFalse(model.isOriginModeEnabled)
        XCTAssertFalse(model.isFocusReportingEnabled)
        XCTAssertEqual(model.mouseTrackingMode, .none)
        XCTAssertFalse(model.isSGRMouseEnabled)
        XCTAssertFalse(model.isBracketedPasteEnabled)
        XCTAssertTrue(model.drainResponses().isEmpty)
    }

    /// 备用屏（`?1049`）要**连模式一起**保存 / 恢复：否则退出 vim 后方向键还停在应用模式。
    func testAlternateScreenSavesAndRestoresModes() {
        let model = screen()
        model.feed(text: "\u{1B}[?1h\u{1B}[?1002h\u{1B}[?1006h")
        model.feed(text: "\u{1B}[?1049h")
        // TUI 在备用屏里改掉这些位（很常见：它自己不用鼠标上报就关掉）。
        model.feed(text: "\u{1B}[?1l\u{1B}[?1002l\u{1B}[?1006l")
        XCTAssertFalse(model.isApplicationCursorKeysEnabled)
        XCTAssertEqual(model.mouseTrackingMode, .none)

        model.feed(text: "\u{1B}[?1049l")
        XCTAssertTrue(model.isApplicationCursorKeysEnabled, "退出备用屏要恢复 DECCKM")
        XCTAssertEqual(model.mouseTrackingMode, .buttonEvent, "退出备用屏要恢复鼠标模式")
        XCTAssertTrue(model.isSGRMouseEnabled, "退出备用屏要恢复 SGR 编码")
    }

    // MARK: - 查询应答

    /// DSR 5 / 6：`6` 必须回话 —— 不回话程序会一直等（表现为"界面卡住"）。
    func testDeviceStatusReport() {
        let model = screen()
        model.feed(text: "\u{1B}[5n")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[0n")

        // 光标移到第 7 行第 3 列再问（CUP 是 1 基）。
        model.feed(text: "\u{1B}[7;3H\u{1B}[6n")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[7;3R")
        // 取走即空（drain 幂等）。
        XCTAssertTrue(model.drainResponses().isEmpty)
    }

    /// 原址模式（`?6`）下 CUP 相对滚动区顶部，CPR 也按相对行号回话。
    func testOriginModeAffectsCUPAndCPR() {
        let model = screen()
        // 滚动区设为第 5~10 行（DECSTBM 是 1 基、含两端）。
        model.feed(text: "\u{1B}[5;10r")
        model.feed(text: "\u{1B}[?6h")
        model.feed(text: "\u{1B}[2;3H")
        XCTAssertEqual(model.cursorRow, 5, "原址模式下第 2 行 = 滚动区第 1 行 + 1")
        model.feed(text: "\u{1B}[6n")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[2;3R", "CPR 要回相对滚动区的行号")

        // 关掉原址模式：同样的 CUP 回到绝对定位。
        model.feed(text: "\u{1B}[?6l\u{1B}[2;3H")
        XCTAssertEqual(model.cursorRow, 1)
        model.feed(text: "\u{1B}[6n")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[2;3R")
    }

    func testDeviceAttributesThroughParser() {
        let model = screen()
        model.feed(text: "\u{1B}[c")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[?1;2c")
        model.feed(text: "\u{1B}[>c")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[>0;0;0c")
        // `CSI 0 c` 也是 DA1（参数缺省 = 0）。
        model.feed(text: "\u{1B}[0c")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[?1;2c")
    }

    /// DECRQM：跟踪的模式如实回 1 / 2，没跟踪的回 0（**不能**谎报"已置位"）。
    func testModeReportThroughParser() {
        let model = screen()
        model.feed(text: "\u{1B}[?1000h\u{1B}[?1000$p")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[?1000;1$y")

        model.feed(text: "\u{1B}[?1000l\u{1B}[?1000$p")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[?1000;2$y")

        model.feed(text: "\u{1B}[?25$p")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[?25;1$y", "光标默认可见 = 已置位")

        model.feed(text: "\u{1B}[?2004$p")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[?2004;2$y")

        model.feed(text: "\u{1B}[?9999$p")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[?9999;0$y", "不认识的模式要回 0")

        // 非私有形式（`CSI 4 $ p`）我们不跟踪任何模式 → 0。
        model.feed(text: "\u{1B}[4$p")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[4;0$y")
    }

    func testXTVERSIONThroughParser() {
        let model = screen()
        model.feed(text: "\u{1B}[>q")
        let response = string(model.drainResponses())
        XCTAssertTrue(response.hasPrefix("\u{1B}P>|DoyahStudio"), "XTVERSION 回的是 DCS 串：\(response.debugDescription)")
        XCTAssertTrue(response.hasSuffix("\u{1B}\\"))
    }

    /// 没有请求时不该有任何应答（否则会往 shell 里灌莫名其妙的字节）。
    func testNoResponsesWithoutQueries() {
        let model = screen()
        model.feed(text: "echo hello\u{1B}[?1000h\u{1B}[31m红色\u{1B}[0m")
        XCTAssertTrue(model.drainResponses().isEmpty)
        XCTAssertTrue(model.pendingResponseBytes.isEmpty)
    }

    /// 一整条"前台程序接手"的序列：开鼠标 + SGR + DECCKM，随后一次光标查询。
    func testFullForegroundHandoffSequence() {
        let model = screen()
        model.feed(text: "\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?1h")
        XCTAssertEqual(model.mouseTrackingMode, .buttonEvent)
        XCTAssertTrue(model.isSGRMouseEnabled)
        XCTAssertTrue(model.isApplicationCursorKeysEnabled)
        model.feed(text: "\u{1B}[6n")
        XCTAssertEqual(string(model.drainResponses()), "\u{1B}[1;1R")
    }
}
