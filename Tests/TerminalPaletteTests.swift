import XCTest
@testable import DoyahCore

/// 终端调色板（FR-EDIT-29 的配色层）。
///
/// 这组测试是**配色的门槛**，不是"快照"：它守住三件事 ——
/// ① 可读（WCAG 对比度）；② 可区分（色差 ΔE）；③ 属性语义（粗体提亮 / 暗淡 / 反显）。
/// 色值可以改，但改了必须仍然过这些门槛 —— 否则"配色精美"就只是句形容。
final class TerminalPaletteTests: XCTestCase {

    private let dark = TerminalPalette.deepSeaDark
    private let light = TerminalPalette.deepSeaLight
    private var palettes: [TerminalPalette] { [dark, light] }

    /// 做正文用的槽位（排除四个"背景槽"）。
    private func textSlots(_ palette: TerminalPalette) -> [(Int, TerminalPalette.RGB)] {
        palette.ansi.enumerated()
            .filter { !TerminalPalette.isBackgroundSlot(index: $0.offset, isDark: palette.isDark) }
            .map { ($0.offset, $0.element) }
    }

    // MARK: - 结构

    func testBothPalettesHaveSixteenSlots() {
        for palette in palettes {
            XCTAssertEqual(palette.ansi.count, 16, palette.name)
            XCTAssertEqual(Set(palette.ansi).count, 16, "\(palette.name)：16 个槽位不应有重复色")
        }
    }

    /// 两套色板必须**真的不一样**：深色档的底色要比浅色档暗得多。
    func testDarkAndLightPalettesDifferInTheRightDirection() {
        XCTAssertTrue(dark.isDark)
        XCTAssertFalse(light.isDark)
        XCTAssertLessThan(
            TerminalPalette.relativeLuminance(dark.background),
            TerminalPalette.relativeLuminance(light.background) - 0.5
        )
        XCTAssertGreaterThan(
            TerminalPalette.contrastRatio(dark.background, light.background),
            10
        )
    }

    // MARK: - 可读（对比度）

    func testForegroundOnBackgroundIsAtLeastSeven() {
        for palette in palettes {
            let ratio = TerminalPalette.contrastRatio(palette.foreground, palette.background)
            XCTAssertGreaterThanOrEqual(ratio, 7.0, "\(palette.name)：前景对背景只有 \(ratio)")
        }
    }

    /// 当正文用的槽位：≥ 4.5（WCAG AA 正文）。
    func testTextSlotsAreLegibleOnTheirOwnBackground() {
        for palette in palettes {
            for (index, color) in textSlots(palette) {
                let ratio = TerminalPalette.contrastRatio(color, palette.background)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    4.5,
                    "\(palette.name) 槽位 \(index) 对背景只有 \(ratio)"
                )
            }
        }
    }

    /// 四个"背景槽"（深色档 0/8、浅色档 7/15）不参与 4.5 门槛，但都有各自的硬要求：
    ///
    /// - 深色档的黑 / 亮黑：与底色 ΔE ≥ 8 —— 纯黑在深底上根本看不见，所以黑槽被抬亮了，
    ///   这条测试就是钉住"抬得够看得出边界"；
    /// - 浅色档的白（7）：是一块**浅灰**而不是白（ΔE ≥ 5 对底色），这样程序拿它当背景时看得见；
    /// - 浅色档的亮白（15）：**按设计就是白**（与底色 ΔE ≤ 3）。这是行业惯例（Solarized Light
    ///   的 base3、GitHub Light 的 `#fafbfc` 都贴着底色），也是"白底上画白底"这件事的本来含义 ——
    ///   不能为了通过一条测试就把它改成灰的，那等于替程序改了它的意图。
    func testBackgroundSlotsFollowTheirOwnRules() {
        for index in [0, 8] {
            let delta = TerminalPalette.deltaE(dark.ansi[index], dark.background)
            XCTAssertGreaterThanOrEqual(delta, 8.0, "深色档背景槽 \(index) 与底色只差 \(delta)")
        }

        let lightWhite = TerminalPalette.deltaE(light.ansi[7], light.background)
        XCTAssertGreaterThanOrEqual(lightWhite, 5.0, "浅色档的白槽应当是一块看得见的浅灰，实测 \(lightWhite)")

        XCTAssertEqual(light.ansi[15], TerminalPalette.RGB(hex: 0xFFFFFF), "浅色档亮白就是纯白")
        let brightWhite = TerminalPalette.deltaE(light.ansi[15], light.background)
        XCTAssertLessThanOrEqual(brightWhite, 3.0, "亮白与底色本就该几乎同色，实测 \(brightWhite)")
    }

    func testCursorAndSelectionRemainReadable() {
        for palette in palettes {
            let cursor = TerminalPalette.contrastRatio(palette.cursor, palette.background)
            XCTAssertGreaterThanOrEqual(cursor, 3.0, "\(palette.name)：光标对底色只有 \(cursor)")
            let onSelection = TerminalPalette.contrastRatio(palette.foreground, palette.selectionBackground)
            XCTAssertGreaterThanOrEqual(onSelection, 7.0, "\(palette.name)：选中底上的字只有 \(onSelection)")
            let selectionEdge = TerminalPalette.deltaE(palette.selectionBackground, palette.background)
            XCTAssertGreaterThanOrEqual(selectionEdge, 8.0, "\(palette.name)：选中底与底色只差 \(selectionEdge)")
        }
    }

    // MARK: - 可区分（色差）

    /// 不同色相之间必须分得开：红不能看着像橙、蓝不能看着像青。
    func testDifferentHuesAreDistinguishable() {
        for palette in palettes {
            for range in [1...6, 9...14] {
                let colors = range.map { palette.ansi[$0] }
                for i in colors.indices {
                    for j in colors.indices where j > i {
                        let delta = TerminalPalette.deltaE(colors[i], colors[j])
                        XCTAssertGreaterThanOrEqual(
                            delta,
                            25.0,
                            "\(palette.name)：槽位 \(range.lowerBound + i) 与 \(range.lowerBound + j) 只差 \(delta)"
                        )
                    }
                }
            }
        }
    }

    /// 同一色相的"常规 / 亮"两档要**看得出是两档**（≥ 8）。
    ///
    /// 浅色档的黄是最紧的一处（近白底上"更亮的黄"必然掉对比度），实测 ΔE 8：
    /// 这一条就是它的下限，再压就要动色相了。
    func testNormalAndBrightOfTheSameHueDifferEnough() {
        for palette in palettes {
            for hue in 1...6 {
                let normal = palette.ansi[hue]
                let bright = palette.ansi[hue + 8]
                let delta = TerminalPalette.deltaE(normal, bright)
                XCTAssertGreaterThanOrEqual(delta, 8.0, "\(palette.name) 色相 \(hue) 的常规/亮只差 \(delta)")
            }
        }
    }

    func testGreyRampIsOrdered() {
        for palette in palettes {
            let blackIndex = palette.isDark ? 0 : 0
            let brightness = { (index: Int) in TerminalPalette.relativeLuminance(palette.ansi[index]) }
            XCTAssertLessThan(brightness(blackIndex), brightness(8), "\(palette.name)：亮黑应当比黑亮")
            XCTAssertLessThan(brightness(8), brightness(7), "\(palette.name)：亮黑应当比白暗")
            XCTAssertLessThanOrEqual(brightness(7), brightness(15), "\(palette.name)：亮白应当不比白暗")
        }
    }

    /// ANSI 序号语义**不许改**：1 必须是红、2 绿、3 黄、4 蓝、5 品红、6 青。
    /// 用色相区间钉住（`ls` / `grep` / 测试框架都指望这个顺序）。
    func testAnsiHueOrderMatchesTheStandard() {
        func hue(_ color: TerminalPalette.RGB) -> Double {
            let r = Double(color.red) / 255
            let g = Double(color.green) / 255
            let b = Double(color.blue) / 255
            let maxValue = max(r, g, b)
            let minValue = min(r, g, b)
            let delta = maxValue - minValue
            guard delta > 0 else { return 0 }
            let raw: Double
            if maxValue == r {
                raw = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxValue == g {
                raw = 60 * ((b - r) / delta + 2)
            } else {
                raw = 60 * ((r - g) / delta + 4)
            }
            return raw < 0 ? raw + 360 : raw
        }

        for palette in palettes {
            XCTAssertTrue((330...360).contains(hue(palette.ansi[1])) || (0...20).contains(hue(palette.ansi[1])), "\(palette.name) 的 1 应当偏红")
            XCTAssertTrue((90...165).contains(hue(palette.ansi[2])), "\(palette.name) 的 2 应当偏绿")
            XCTAssertTrue((30...70).contains(hue(palette.ansi[3])), "\(palette.name) 的 3 应当偏黄")
            XCTAssertTrue((200...265).contains(hue(palette.ansi[4])), "\(palette.name) 的 4 应当偏蓝")
            XCTAssertTrue((285...330).contains(hue(palette.ansi[5])), "\(palette.name) 的 5 应当偏品红")
            XCTAssertTrue((165...200).contains(hue(palette.ansi[6])), "\(palette.name) 的 6 应当偏青")
        }
    }

    // MARK: - 解析：16 / 256 / 真彩色

    func testIndexedSlotsResolveToThePalette() {
        for palette in palettes {
            for index in 0..<16 {
                XCTAssertEqual(palette.resolve(.indexed(UInt8(index))), palette.ansi[index])
            }
        }
    }

    /// 256 色立方与灰阶按 xterm 标准（16…231 立方、232…255 灰阶）。
    func testExtendedIndexedColorsFollowXterm() {
        XCTAssertEqual(dark.resolve(.indexed(16)), TerminalPalette.RGB(hex: 0x000000))
        XCTAssertEqual(dark.resolve(.indexed(21)), TerminalPalette.RGB(hex: 0x0000FF))
        XCTAssertEqual(dark.resolve(.indexed(196)), TerminalPalette.RGB(hex: 0xFF0000))
        XCTAssertEqual(dark.resolve(.indexed(231)), TerminalPalette.RGB(hex: 0xFFFFFF))
        // 立方中间档：`steps = [0, 95, 135, 175, 215, 255]`
        XCTAssertEqual(dark.resolve(.indexed(16 + 1)), TerminalPalette.RGB(red: 0, green: 0, blue: 95))
        XCTAssertEqual(dark.resolve(.indexed(16 + 36)), TerminalPalette.RGB(red: 95, green: 0, blue: 0))
        // 灰阶：8 + n×10
        XCTAssertEqual(dark.resolve(.indexed(232)), TerminalPalette.RGB(red: 8, green: 8, blue: 8))
        XCTAssertEqual(dark.resolve(.indexed(255)), TerminalPalette.RGB(red: 238, green: 238, blue: 238))
    }

    func testTrueColorPassesThroughAndDefaultFollowsThePalette() {
        XCTAssertEqual(dark.resolve(.rgb(12, 34, 56)), TerminalPalette.RGB(red: 12, green: 34, blue: 56))
        XCTAssertEqual(dark.resolve(.default), dark.foreground)
        XCTAssertEqual(light.resolve(.default), light.foreground)
    }

    // MARK: - 属性语义

    func testBoldUsesTheBrightSlotForIndexedColors() {
        var cell = TerminalCell()
        cell.bold = true
        cell.foreground = .indexed(1)
        XCTAssertEqual(dark.resolvedForeground(for: cell), dark.ansi[9], "粗体应当用对应的亮色槽")

        // 真彩色不会被"提亮"（没有对应的亮色可换）
        cell.foreground = .rgb(10, 20, 30)
        XCTAssertEqual(dark.resolvedForeground(for: cell), TerminalPalette.RGB(red: 10, green: 20, blue: 30))

        // 已经是亮色槽就不要再跳到别的槽
        cell.foreground = .indexed(9)
        XCTAssertEqual(dark.resolvedForeground(for: cell), dark.ansi[9])
    }

    func testDimBlendsForegroundTowardTheBackground() {
        var cell = TerminalCell()
        cell.isDim = true
        let dimmed = dark.resolvedForeground(for: cell)
        XCTAssertNotEqual(dimmed, dark.foreground)
        let plain = TerminalPalette.contrastRatio(dark.foreground, dark.background)
        let dim = TerminalPalette.contrastRatio(dimmed, dark.background)
        XCTAssertLessThan(dim, plain, "暗淡必须比常规更弱")
        XCTAssertGreaterThan(dim, 1.5, "暗淡不等于消失：仍要看得出有字")
    }

    func testInverseSwapsForegroundAndBackground() {
        var cell = TerminalCell()
        cell.inverse = true
        XCTAssertEqual(dark.resolvedForeground(for: cell), dark.background)
        XCTAssertEqual(dark.resolvedBackground(for: cell), dark.foreground)

        // 显式着色时反显要换的是那一对颜色
        cell.foreground = .indexed(1)
        cell.background = .indexed(4)
        XCTAssertEqual(dark.resolvedForeground(for: cell), dark.ansi[4])
        XCTAssertEqual(dark.resolvedBackground(for: cell), dark.ansi[1])
    }

    func testDefaultBackgroundReportsThePaletteBackground() {
        XCTAssertEqual(dark.resolvedBackground(for: TerminalCell()), dark.background)
        XCTAssertEqual(light.resolvedBackground(for: TerminalCell()), light.background)
    }

    /// 粗体 + 暗淡可以并存：先提亮再压暗（xterm 里 `1;2` 就是这个意思）。
    func testBoldAndDimCanCoexist() {
        var cell = TerminalCell()
        cell.bold = true
        cell.isDim = true
        cell.foreground = .indexed(1)
        let resolved = dark.resolvedForeground(for: cell)
        XCTAssertNotEqual(resolved, dark.ansi[9])
        XCTAssertEqual(resolved, dark.dimmed(dark.ansi[9]))
    }
}
