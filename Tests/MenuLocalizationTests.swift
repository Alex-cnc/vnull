import XCTest
@testable import DoyahCore

/// 菜单栏文案反向映射的测试（NFR-I18N-03）。
///
/// 背景：SwiftUI 切换语言时只重建菜单标题，菜单里的叶子项不刷新，
/// 所以要用 `MenuLocalization.retitled` 把 `NSMenuItem.title` 改回来。
/// 这里锁住那张反向映射表的两条性质：**不漏**（menu 前缀的键都登记了）与**不串**（标题不撞车）。
final class MenuLocalizationTests: XCTestCase {

    /// 新增了 `menu` 前缀的键却忘了登记进反向映射表，菜单那一项就会停在旧语言。
    func testEveryMenuPrefixedKeyIsRegistered() {
        let registered = Set(MenuLocalization.menuKeys)
        let prefixed = Set(LKey.allCases.map(\.rawValue).filter { $0.hasPrefix("menu") })
        let missing = prefixed.subtracting(registered.map(\.rawValue))
        XCTAssertTrue(
            missing.isEmpty,
            "有 menu 前缀的键没登记进 MenuLocalization.menuKeys：\(missing.sorted())"
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

    /// 系统菜单项绝不能被改写：它们在运行时改不动，硬改只会让系统菜单中英混杂。
    func testSystemProvidedTitlesAreLeftAlone() {
        let systemTitles = [
            "文件", "编辑", "显示", "窗口", "帮助", "服务", "退出Doyah Studio",
            "File", "Edit", "View", "Window", "Help",
            "关闭", "全部关闭", "撤销", "重做", "全选", "拷贝", "粘贴",
            "", "关于Doyah Studio"
        ]
        for title in systemTitles {
            XCTAssertNil(
                MenuLocalization.retitled(title, to: .english),
                "不该改写系统菜单项：\(title)"
            )
        }
    }
}
