import XCTest
@testable import DoyahCore

/// 菜单栏文案反向映射的测试（NFR-I18N-03）。
///
/// 背景：SwiftUI 切换语言时只重建菜单标题，菜单里的叶子项不刷新，
/// 所以要用 `MenuLocalization.retitled` 把 `NSMenuItem.title` 改回来。
/// 这里锁住那张反向映射表的两条性质：**不漏**（menu 前缀的键都登记了）与**不串**（标题不撞车）。
final class MenuLocalizationTests: XCTestCase {

    /// 新增了 `menu` 前缀的键却忘了登记，菜单那一项就会停在旧语言。
    ///
    /// 覆盖面从"只看前缀"扩到**三类表全并**：自有项（`menuKeys`）、系统顶层标题
    /// （`systemMenuTitles`）、系统叶子项（`systemMenuItems` 的值）。
    /// 为什么改：2026-09-24 实测发现 `.archiveTitle` / `.databaseStatsTitle` /
    /// `.schemaDiffTitle` / `.lowerPaneToggle` 这四个**自有**菜单项的键没有 `menu` 前缀，
    /// 于是旧版测试完全没覆盖它们 —— 切到中文后那四项停在英文。
    func testEveryMenuPrefixedKeyIsRegistered() {
        let registered = Set(MenuLocalization.menuKeys)
            .union(MenuLocalization.systemMenuTitles)
            .union(MenuLocalization.systemMenuItems.values)
        let prefixed = Set(LKey.allCases.filter { $0.rawValue.hasPrefix("menu") })
        let missing = prefixed.subtracting(registered)
        XCTAssertTrue(
            missing.isEmpty,
            "有 menu 前缀的键没登记进任何一张菜单表：\(missing.map(\.rawValue).sorted())"
        )
    }

    func testMenuKeysAreUniqueAndNonEmpty() {
        XCTAssertFalse(MenuLocalization.menuKeys.isEmpty)
        XCTAssertEqual(
            MenuLocalization.menuKeys.count,
            Set(MenuLocalization.menuKeys).count,
            "反向映射表里有重复的键"
        )
    }

    /// 两种语言互查都要成立，且「翻译成自己」是幂等的。
    func testRoundTripBetweenLanguages() {
        for key in MenuLocalization.menuKeys {
            let chinese = LocalizedStrings.text(key, language: .simplifiedChinese)
            let english = LocalizedStrings.text(key, language: .english)

            XCTAssertEqual(MenuLocalization.retitled(english, to: .simplifiedChinese), chinese)
            XCTAssertEqual(MenuLocalization.retitled(chinese, to: .english), english)
            XCTAssertEqual(MenuLocalization.retitled(chinese, to: .simplifiedChinese), chinese)
            XCTAssertEqual(MenuLocalization.retitled(english, to: .english), english)
        }
    }

    /// 任一种语言下，自有菜单标题之间都不能撞车，否则反向映射会指到错的键。
    func testMenuTitlesDoNotCollideAcrossLanguages() {
        var owners: [String: LKey] = [:]
        for key in MenuLocalization.menuKeys {
            for language in AppLanguage.allCases {
                let title = LocalizedStrings.text(key, language: language)
                if let existing = owners[title] {
                    XCTFail("菜单标题撞车：\(title) 同时属于 \(existing.rawValue) 与 \(key.rawValue)")
                }
                owners[title] = key
            }
        }
    }

    // MARK: 系统菜单（2026-09-24 起改为**由我们改写**，于是"换语言要重启"这条限制去掉）

    /// 系统菜单的**叶子项**按 `action selector` 认，两种语言都要给得出来。
    func testSystemLeafItemsAreRetitledBySelector() {
        XCTAssertEqual(MenuLocalization.retitled(action: "undo:", appName: "Doyah Studio", to: .simplifiedChinese), "撤销")
        XCTAssertEqual(MenuLocalization.retitled(action: "undo:", appName: "Doyah Studio", to: .english), "Undo")
        XCTAssertEqual(MenuLocalization.retitled(action: "copy:", appName: "x", to: .simplifiedChinese), "拷贝")
        XCTAssertEqual(MenuLocalization.retitled(action: "selectAll:", appName: "x", to: .english), "Select All")
        XCTAssertEqual(MenuLocalization.retitled(action: "toggleSidebar:", appName: "x", to: .simplifiedChinese), "显示/隐藏边栏")
    }

    /// 带应用名的项要用 `appName` 填 `%@`（名字不写死在文案表里）。
    func testSystemAppNamedItemsUseTheBundleName() {
        XCTAssertEqual(
            MenuLocalization.retitled(action: "terminate:", appName: "Doyah Studio", to: .simplifiedChinese),
            "退出 Doyah Studio"
        )
        XCTAssertEqual(
            MenuLocalization.retitled(action: "showHelp:", appName: "Doyah Studio", to: .english),
            "Doyah Studio Help"
        )
        XCTAssertEqual(
            MenuLocalization.retitled(action: "orderFrontStandardAboutPanel:", appName: "Doyah Studio", to: .simplifiedChinese),
            "关于 Doyah Studio"
        )
    }

    /// 表里没有的 selector 返回 `nil`（调用方退回按标题查）——不能瞎猜一个文案出来。
    func testUnknownSelectorIsNotGuessed() {
        XCTAssertNil(MenuLocalization.retitled(action: "noSuchAction:", appName: "x", to: .english))
    }

    /// 菜单栏**顶层标题**（没有 action，只能按标题认）双向都要成立且幂等。
    func testSystemTopLevelTitlesRoundTrip() {
        let pairs = [("File", "文件"), ("Edit", "编辑"), ("View", "显示"), ("Window", "窗口"), ("Help", "帮助")]
        for (english, chinese) in pairs {
            XCTAssertEqual(MenuLocalization.retitled(english, to: .simplifiedChinese), chinese)
            XCTAssertEqual(MenuLocalization.retitled(chinese, to: .english), english)
            XCTAssertEqual(MenuLocalization.retitled(chinese, to: .simplifiedChinese), chinese)
        }
    }

    /// 空标题 / 不认识的标题一律不动（`nil`），免得把分隔符之类的东西改成文案。
    func testUnrelatedTitlesAreLeftAlone() {
        for title in ["", "Doyah Studio", "Services…"] {
            XCTAssertNil(MenuLocalization.retitled(title, to: .english), "不该改写：\(title)")
        }
    }
}
