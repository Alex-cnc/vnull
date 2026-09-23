import XCTest
@testable import DoyahCore

/// 设计令牌的单测。
///
/// 这一层的价值不在"存了几个数字"，而在**它把品味变成了可校验的约束**：
/// 间距必须在刻度上、表面之间必须能被看出来是两块、文字必须够对比度。
/// 这些都是肉眼容易放过、但一旦放过就会累积成"看着不精致"的东西。
final class DesignTokensTests: XCTestCase {

    private let thresholds = ColorContrast.Threshold.self

    // MARK: 刻度

    func testSpacingIsOnTheFourEightGrid() {
        XCTAssertEqual(Spacing.scale, [2, 4, 8, 12, 16, 24, 32])
        // 除了 hair（图标与文字紧贴），其余都必须是 4 的倍数
        for value in Spacing.scale where value != Spacing.hair {
            XCTAssertEqual(value.truncatingRemainder(dividingBy: 4), 0, "\(value) 不在 4 的倍数上")
        }
        XCTAssertTrue(Spacing.isOnScale(Spacing.l))
        XCTAssertFalse(Spacing.isOnScale(150), "曾经出现过 150 这种裸数字")
        XCTAssertFalse(Spacing.isOnScale(3), "曾经出现过 3 这种裸数字")
    }

    func testRadiusScaleIsFixed() {
        XCTAssertEqual(Radius.scale, [1, 4, 6, 8, 10])
    }

    func testTypeScaleHasRealHierarchy() {
        XCTAssertEqual(TypeScale.scale, [11, 12, 13, 15, 17])
        // 级差必须单调递增，否则不叫"级差"
        let sorted = TypeScale.scale.sorted()
        XCTAssertEqual(TypeScale.scale, sorted)
        XCTAssertFalse(TypeScale.isOnScale(14), "14 不属于任何一级（改造前出现过）")
        // 每个命名常量都必须在刻度上（否则刻度形同虚设）
        for named in [TypeScale.captionSize, TypeScale.dataSize, TypeScale.monoSize,
                      TypeScale.monoSmallSize, TypeScale.bodySize, TypeScale.titleSize, TypeScale.displaySize] {
            XCTAssertTrue(TypeScale.isOnScale(named), "\(named) 不在字号刻度上")
        }
    }

    /// 度量值被**钉住**：改这些数字是设计决策，必须连同测试一起改，不能顺手漂移。
    func testMetricsArePinned() {
        XCTAssertEqual(Metrics.hairline, 0.5)
        XCTAssertEqual(Metrics.rowHeight, 26)          // 紧凑但留白严格
        XCTAssertEqual(Metrics.toolbarHeight, 44)
        XCTAssertEqual(Metrics.statusBarHeight, 24)
        XCTAssertEqual(Metrics.activityBarWidth, 46)   // FR-EDIT-32
        XCTAssertEqual(Metrics.sidebarWidth, 248)
    }

    // MARK: 表面层次（改造中修掉过两次真缺陷，这里守住）

    /// 内容区与侧栏必须能被看出来是两块 —— 第一版只差 3/255，等于没有层次。
    func testContentAndSidebarAreDistinguishableInBothThemes() {
        for isDark in [true, false] {
            let content = Surface.content.color.hex(dark: isDark)
            let sidebar = Surface.sidebar.color.hex(dark: isDark)
            let distance = ColorContrast.distance(content, sidebar)
            XCTAssertGreaterThanOrEqual(
                distance, thresholds.surfaceSeparation,
                "\(isDark ? "深色" : "浅色")主题里内容区与侧栏太接近（距离 \(String(format: "%.3f", distance))）"
            )
        }
    }

    func testPanelAndWindowAreDistinguishableFromContent() {
        for isDark in [true, false] {
            let content = Surface.content.color.hex(dark: isDark)
            for surface in [Surface.panel, .window] {
                let distance = ColorContrast.distance(content, surface.color.hex(dark: isDark))
                XCTAssertGreaterThanOrEqual(
                    distance, thresholds.surfaceSeparation,
                    "\(isDark ? "深色" : "浅色")主题里 \(surface.rawValue) 与内容区太接近"
                )
            }
        }
    }

    /// 深色主题靠**明度递增**表达层次：window < sidebar < content < panel < raised。
    func testDarkSurfacesRiseInLightness() {
        let order: [Surface] = [.window, .sidebar, .content, .panel, .raised]
        let luminances = order.map { ColorContrast.relativeLuminance($0.color.dark) }
        for index in 1..<luminances.count {
            XCTAssertGreaterThan(
                luminances[index], luminances[index - 1],
                "深色主题里 \(order[index].rawValue) 不比 \(order[index - 1].rawValue) 亮"
            )
        }
    }

    /// 浅色主题的不变式不同：**内容区是最亮的**（面板与浮层靠描边 / 阴影区分，不靠更亮）。
    func testLightContentIsTheBrightestSurface() {
        let content = ColorContrast.relativeLuminance(Surface.content.color.light)
        for surface in Surface.allCases where surface != .content {
            XCTAssertLessThanOrEqual(
                ColorContrast.relativeLuminance(surface.color.light), content,
                "浅色主题里 \(surface.rawValue) 比内容区还亮"
            )
        }
    }

    // MARK: 对比度（这一层真正要守的）

    /// 正文与次要信息：WCAG AA 4.5。
    func testBodyAndSecondaryTextPassAAOnContent() {
        for isDark in [true, false] {
            let background = Surface.content.color.hex(dark: isDark)
            for tone in [TextTone.primary, .secondary] {
                let ratio = ColorContrast.ratio(tone.color.hex(dark: isDark), background)
                XCTAssertGreaterThanOrEqual(
                    ratio, thresholds.bodyText,
                    "\(isDark ? "深色" : "浅色")主题的 \(tone.rawValue) 只有 \(String(format: "%.2f", ratio))"
                )
            }
        }
    }

    /// 辅助信息（表头 / 行号）：按**非文本组件**的 3.0 守 —— 它刻意比正文轻，
    /// 但要能看清。浅色档原来给 #9A9AA0 只有 2.80，已压到 #7C7C82。
    func testTertiaryTextStaysReadable() {
        for isDark in [true, false] {
            let background = Surface.content.color.hex(dark: isDark)
            let ratio = ColorContrast.ratio(TextTone.tertiary.color.hex(dark: isDark), background)
            XCTAssertGreaterThanOrEqual(
                ratio, thresholds.largeText,
                "\(isDark ? "深色" : "浅色")主题的辅助文字只有 \(String(format: "%.2f", ratio))"
            )
        }
    }

    /// 状态色主要用作状态点（非文本组件）→ 3.0。
    func testStatusColoursAreVisibleOnBothSurfaces() {
        for isDark in [true, false] {
            for background in [Surface.content, .panel] {
                let hex = background.color.hex(dark: isDark)
                for tone in StatusTone.allCases {
                    let ratio = ColorContrast.ratio(tone.color.hex(dark: isDark), hex)
                    XCTAssertGreaterThanOrEqual(
                        ratio, thresholds.component,
                        "\(isDark ? "深色" : "浅色")主题里 \(tone.rawValue) 在 \(background.rawValue) 上只有 \(String(format: "%.2f", ratio))"
                    )
                }
            }
        }
    }

    /// 代码要在编辑器里读得下去：除注释外都按正文 4.5 守。
    func testSyntaxColoursAreReadableOnContent() {
        for isDark in [true, false] {
            let background = Surface.content.color.hex(dark: isDark)
            for tone in SyntaxTone.allCases {
                let ratio = ColorContrast.ratio(tone.color.hex(dark: isDark), background)
                let required = tone == .comment ? thresholds.largeText : thresholds.bodyText
                XCTAssertGreaterThanOrEqual(
                    ratio, required,
                    "\(isDark ? "深色" : "浅色")主题的 \(tone.rawValue) 只有 \(String(format: "%.2f", ratio))（需 ≥ \(required)）"
                )
            }
        }
    }

    /// 关键词与字符串、数字与函数之间必须分得开 —— 语法着色"糊成一片"就等于没有。
    func testSyntaxColoursAreDistinctFromEachOther() {
        for isDark in [true, false] {
            let tones = SyntaxTone.allCases
            for i in 0..<tones.count {
                for j in (i + 1)..<tones.count {
                    // identifier 就是正文色，与其它色当然不同；这里只要求"不完全相同"
                    let a = tones[i].color.hex(dark: isDark)
                    let b = tones[j].color.hex(dark: isDark)
                    XCTAssertNotEqual(a, b, "\(tones[i].rawValue) 与 \(tones[j].rawValue) 用了同一个颜色")
                }
            }
        }
    }

    // MARK: 与强调色的边界

    /// 选中态与斑马纹的透明度必须在一个"看得出但不糊"的区间里。
    ///
    /// 这条守的是手滑：写成 0.4 会让选中行糊成一块，写成 0.02 又完全看不出，
    /// 而这两种都不会有任何编译错误或崩溃 —— 只能靠断言。
    func testOverlayAlphasAreInASaneRange() {
        for alpha in [Overlay.Selection.darkAlpha, Overlay.Selection.lightAlpha] {
            XCTAssertGreaterThanOrEqual(alpha, 0.06, "选中淡填充太淡，看不出来")
            XCTAssertLessThanOrEqual(alpha, 0.20, "选中淡填充太重，会糊成一块")
        }
        // 浅色底的对比本来就弱，浅色档的透明度应当**不高于**深色档
        XCTAssertLessThanOrEqual(Overlay.Selection.lightAlpha, Overlay.Selection.darkAlpha)
        for alpha in [Overlay.Zebra.darkAlpha, Overlay.Zebra.lightAlpha] {
            XCTAssertGreaterThan(alpha, 0, "斑马纹不能为 0（等于没有）")
            XCTAssertLessThanOrEqual(alpha, 0.06, "斑马纹太重会像表格有底色")
        }
    }

    func testResultColumnWidthBoundsAreSane() {
        XCTAssertLessThan(Metrics.minColumnWidth, Metrics.maxColumnWidth)
        XCTAssertGreaterThanOrEqual(Metrics.minColumnWidth, 24, "太窄会把列头截没")
        XCTAssertGreaterThan(Metrics.columnWidthSampleRows, 0)
    }

    /// 强调色**不属于**令牌层：它由用户配置（`AccentTheme`）。
    /// 这条测试是防"有人图省事把强调色写死进 DesignTokens"。
    func testAccentIsNotHardCodedInTokens() {
        let tokenHexes = Set(
            Surface.allCases.map(\.color.light)
                + Surface.allCases.map(\.color.dark)
                + TextTone.allCases.map(\.color.light)
                + TextTone.allCases.map(\.color.dark)
        )
        for accent in AccentTheme.all {
            XCTAssertFalse(tokenHexes.contains(accent.accentHex), "\(accent.id) 被写死进了令牌层")
        }
    }
}
