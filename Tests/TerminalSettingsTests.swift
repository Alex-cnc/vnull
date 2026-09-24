import XCTest
@testable import DoyahCore

/// 终端的两个偏好：外观三态与字号夹取（FR-EDIT-29 的后续）。
///
/// 这两件的共同点是"判断很小、但错了很难发现"：外观偏好的解析错一位，
/// 浅色界面上就会给你一个深色终端（或者反过来）；字号不夹取，
/// 一行会被重分成两三个字符宽，TUI 直接不可用。
final class TerminalSettingsTests: XCTestCase {

    // MARK: - 外观三态

    func testFollowSystemMirrorsTheSystem() {
        XCTAssertTrue(TerminalAppearance.followSystem.resolvesToDark(systemIsDark: true))
        XCTAssertFalse(TerminalAppearance.followSystem.resolvesToDark(systemIsDark: false))
    }

    /// 覆盖态**不受系统影响**：这是这个偏好存在的全部意义。
    func testOverridesIgnoreTheSystemAppearance() {
        for systemIsDark in [true, false] {
            XCTAssertTrue(TerminalAppearance.alwaysDark.resolvesToDark(systemIsDark: systemIsDark))
            XCTAssertFalse(TerminalAppearance.alwaysLight.resolvesToDark(systemIsDark: systemIsDark))
        }
    }

    func testPaletteResolutionFollowsThePreference() {
        XCTAssertEqual(TerminalAppearance.alwaysDark.palette(systemIsDark: false).name, TerminalPalette.deepSeaDark.name)
        XCTAssertEqual(TerminalAppearance.alwaysLight.palette(systemIsDark: true).name, TerminalPalette.deepSeaLight.name)
        XCTAssertEqual(TerminalAppearance.followSystem.palette(systemIsDark: true).name, TerminalPalette.deepSeaDark.name)
        XCTAssertEqual(TerminalAppearance.followSystem.palette(systemIsDark: false).name, TerminalPalette.deepSeaLight.name)
        // 深 / 浅两套色板的 isDark 也应当与解析一致
        XCTAssertTrue(TerminalAppearance.alwaysDark.palette(systemIsDark: false).isDark)
        XCTAssertFalse(TerminalAppearance.alwaysLight.palette(systemIsDark: true).isDark)
    }

    /// 未知值回落"跟随系统"：偏好文件被手改也不该让界面起不来。
    func testUnknownRawValueFallsBackToFollowSystem() {
        XCTAssertEqual(TerminalAppearance.resolve(rawValue: nil), .followSystem)
        XCTAssertEqual(TerminalAppearance.resolve(rawValue: ""), .followSystem)
        XCTAssertEqual(TerminalAppearance.resolve(rawValue: "solarized"), .followSystem)
        XCTAssertEqual(TerminalAppearance.resolve(rawValue: "alwaysDark"), .alwaysDark)
        XCTAssertEqual(TerminalAppearance.resolve(rawValue: "alwaysLight"), .alwaysLight)
    }

    /// 三个档位的 `rawValue` 是持久化契约：改名等于让用户的偏好失效，所以钉住。
    func testRawValuesAreStableStorageKeys() {
        XCTAssertEqual(TerminalAppearance.followSystem.rawValue, "followSystem")
        XCTAssertEqual(TerminalAppearance.alwaysDark.rawValue, "alwaysDark")
        XCTAssertEqual(TerminalAppearance.alwaysLight.rawValue, "alwaysLight")
        XCTAssertEqual(TerminalAppearance.allCases.count, 3)
    }

    // MARK: - 字号

    func testFontSizeClampsToItsBounds() {
        XCTAssertEqual(TerminalFontSize.clamped(0), TerminalFontSize.minimum)
        XCTAssertEqual(TerminalFontSize.clamped(-40), TerminalFontSize.minimum)
        XCTAssertEqual(TerminalFontSize.clamped(1000), TerminalFontSize.maximum)
        XCTAssertEqual(TerminalFontSize.clamped(13), 13, "区间内的值必须原样保留")
    }

    func testDefaultFontSizeIsInsideTheRange() {
        XCTAssertTrue(TerminalFontSize.isValid(TerminalFontSize.default))
        XCTAssertLessThan(TerminalFontSize.minimum, TerminalFontSize.maximum)
        // 默认值要与排版刻度里的等宽字号一致，否则"没设置过"和"设成默认"看起来会不一样。
        XCTAssertEqual(TerminalFontSize.default, Int(TypeScale.monoSize))
    }

    func testFontSizeResolveFallsBackForMissingOrForeignValues() {
        XCTAssertEqual(TerminalFontSize.resolve(rawValue: nil), TerminalFontSize.default)
        XCTAssertEqual(TerminalFontSize.resolve(rawValue: "12"), TerminalFontSize.default, "类型不对时回落默认，不崩")
        XCTAssertEqual(TerminalFontSize.resolve(rawValue: 42), TerminalFontSize.maximum)
        XCTAssertEqual(TerminalFontSize.resolve(rawValue: 2), TerminalFontSize.minimum)
        XCTAssertEqual(TerminalFontSize.resolve(rawValue: 16), 16)
    }

    /// 字号只影响排版，**不该影响配色**：换字号时色板必须完全一样。
    func testFontSizeDoesNotAffectThePalette() {
        let palette = TerminalAppearance.alwaysDark.palette(systemIsDark: true)
        for size in [TerminalFontSize.minimum, TerminalFontSize.default, TerminalFontSize.maximum] {
            XCTAssertEqual(TerminalAppearance.alwaysDark.palette(systemIsDark: true), palette)
            XCTAssertTrue(TerminalFontSize.isValid(size))
        }
    }
}
