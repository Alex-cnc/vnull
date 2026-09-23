import XCTest
@testable import DoyahCore

/// 强调色主题的单测（FR-EDIT-33）。
///
/// 这里守的主要是**可访问性**与**回退**：三个候选都能选、都能持久化，
/// 且"白字压在实心按钮上"必须过 WCAG AA —— 这是肉眼很难判断、但一测就露的事。
final class AccentThemeTests: XCTestCase {

    // MARK: 候选集合

    func testThreeCandidatesWithStableUniqueIdentifiers() {
        XCTAssertEqual(AccentTheme.all.count, 3)
        XCTAssertEqual(Set(AccentTheme.all.map(\.id)).count, 3)
        // id 是持久化用的，写死在这里防止有人顺手改名把用户的选择弄丢
        XCTAssertEqual(AccentTheme.all.map(\.id), ["whale-blue", "deep-teal", "whale-magenta"])
    }

    func testEachCandidateHasItsOwnNameKey() {
        XCTAssertEqual(Set(AccentTheme.all.map(\.nameKey)).count, 3)
        XCTAssertEqual(AccentTheme.whaleBlue.nameKey, .accentWhaleBlue)
        XCTAssertEqual(AccentTheme.deepTeal.nameKey, .accentDeepTeal)
        XCTAssertEqual(AccentTheme.whaleMagenta.nameKey, .accentWhaleMagenta)
    }

    /// 两个候选取自 dsh-tui 鲸鱼自身的调色板：品牌同源的证据写进测试，免得日后被"优化"掉。
    func testWhaleColoursComeFromTheTuiPalette() {
        XCTAssertEqual(AccentTheme.whaleBlue.accentHex, 0x4E6FFF)      // B[78,111,255]
        XCTAssertEqual(AccentTheme.whaleMagenta.accentHex, 0xCC3399)   // 心形 H[204,51,153]
    }

    // MARK: 解析与回退

    func testResolveReturnsRequestedTheme() {
        XCTAssertEqual(AccentTheme.resolve(id: "deep-teal"), AccentTheme.deepTeal)
        XCTAssertEqual(AccentTheme.resolve(id: "whale-magenta"), AccentTheme.whaleMagenta)
    }

    /// 没存过 / 存了空串 / 存了未知 id / 存了将来被删掉的 id —— 都必须回退，不能报错也不能崩。
    func testResolveFallsBackInsteadOfFailing() {
        XCTAssertEqual(AccentTheme.resolve(id: nil), AccentTheme.fallback)
        XCTAssertEqual(AccentTheme.resolve(id: ""), AccentTheme.fallback)
        XCTAssertEqual(AccentTheme.resolve(id: "no-such-theme"), AccentTheme.fallback)
        XCTAssertEqual(AccentTheme.fallback, AccentTheme.whaleBlue)
    }

    func testStorageKeyIsNamespacedLikeOtherUIPreferences() {
        XCTAssertEqual(AccentTheme.Storage.key, "ui.accentTheme")
        XCTAssertTrue(AccentTheme.Storage.key.hasPrefix("ui."))
    }

    // MARK: 色值合法性

    func testEveryHexIsAValidOpaqueColour() {
        for theme in AccentTheme.all {
            for hex in [theme.accentHex, theme.fillHex] {
                XCTAssertLessThanOrEqual(hex, 0xFFFFFF, "\(theme.id) 的色值超出 0xRRGGBB")
            }
            let (red, green, blue) = AccentTheme.components(theme.accentHex)
            for component in [red, green, blue] {
                XCTAssertTrue((0...1).contains(component), "\(theme.id) 分量越界")
            }
        }
    }

    func testContrastRatioBasics() {
        // 黑白比为 21，同色比为 1 —— 先确认公式本身没错
        XCTAssertEqual(AccentTheme.contrastRatio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(AccentTheme.contrastRatio(0x4E6FFF, 0x4E6FFF), 1, accuracy: 0.001)
    }

    // MARK: 可访问性（这条是本次真正要守的）

    /// 实心按钮上压白字：**必须 ≥ 4.5**（WCAG AA 正文）。
    ///
    /// 实测背景：直接拿主色当填充时，鲸鱼蓝只有 4.17、深海青只有 3.12 —— 都不够，
    /// 所以才有了 `fillHex` 这一档压暗色。若有人日后把 fill 改回主色，这条会立刻红。
    func testWhiteTextOnSolidFillPassesAA() {
        for theme in AccentTheme.all {
            let ratio = AccentTheme.contrastRatio(0xFFFFFF, theme.fillHex)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(theme.id) 的实心填充放白字只有 \(String(format: "%.2f", ratio))，达不到 4.5"
            )
        }
    }

    /// 强调色作为 UI 组件（选中条 / 焦点环 / 图标）与两种表面比：**≥ 3.0** 即可（WCAG 对非文本）。
    func testAccentIsVisibleOnBothSurfaces() {
        for theme in AccentTheme.all {
            let onDark = AccentTheme.contrastRatio(theme.accentHex, 0x1F2229)   // 深色主题的内容底
            let onLight = AccentTheme.contrastRatio(theme.accentHex, 0xFFFFFF)  // 浅色主题的内容底
            XCTAssertGreaterThanOrEqual(onDark, 3.0, "\(theme.id) 在深色底上只有 \(String(format: "%.2f", onDark))")
            XCTAssertGreaterThanOrEqual(onLight, 3.0, "\(theme.id) 在浅色底上只有 \(String(format: "%.2f", onLight))")
        }
    }

    /// 三个候选必须**彼此可分辨**，否则"看样张再定"这件事就没有意义。
    func testCandidatesAreDistinguishableFromEachOther() {
        let themes = AccentTheme.all
        for i in 0..<themes.count {
            for j in (i + 1)..<themes.count {
                let a = AccentTheme.components(themes[i].accentHex)
                let b = AccentTheme.components(themes[j].accentHex)
                let distance = sqrt(
                    pow(a.red - b.red, 2) + pow(a.green - b.green, 2) + pow(a.blue - b.blue, 2)
                )
                XCTAssertGreaterThan(distance, 0.3, "\(themes[i].id) 与 \(themes[j].id) 太接近")
            }
        }
    }
}
