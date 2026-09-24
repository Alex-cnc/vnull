import XCTest
@testable import DoyahCore

/// 等宽字体偏好（FR-EDIT-26）：字体族回落、字号夹取、持久化契约。
final class FontPreferencesTests: XCTestCase {

    private let installed = ["Menlo", "SF Mono", "JetBrains Mono", "Fira Code"]

    // MARK: - 字体族解析

    func testChosenFamilyIsKeptWhenAvailable() {
        let preference = MonospaceFontPreference(family: "JetBrains Mono", size: 13)
        let resolved = preference.resolved(availableFamilies: installed)
        XCTAssertEqual(resolved.family, "JetBrains Mono")
        XCTAssertFalse(resolved.didFallBack)
    }

    /// 用户选的字体在这台机器上没有 → 回落系统等宽，并**如实报告**（界面据此提示）。
    func testMissingFamilyFallsBackAndReportsIt() {
        let preference = MonospaceFontPreference(family: "Comic Mono", size: 13)
        let resolved = preference.resolved(availableFamilies: installed)
        XCTAssertNil(resolved.family)
        XCTAssertTrue(resolved.didFallBack)
    }

    /// 大小写不该让人"选中了却被判成不可用"（不同来源的大小写不总一致）。
    func testFamilyMatchIgnoresCase() {
        let preference = MonospaceFontPreference(family: "menlo", size: 13)
        let resolved = preference.resolved(availableFamilies: installed)
        XCTAssertEqual(resolved.family, "Menlo", "应当回填系统里的标准写法")
        XCTAssertFalse(resolved.didFallBack)
    }

    /// 没选过（系统等宽）不算回落。
    func testSystemMonospaceIsNotAFallback() {
        let resolved = MonospaceFontPreference.default.resolved(availableFamilies: installed)
        XCTAssertNil(resolved.family)
        XCTAssertFalse(resolved.didFallBack)
    }

    func testBlankFamilyIsTreatedAsNotChosen() {
        XCTAssertNil(MonospaceFontPreference.normalized(""))
        XCTAssertNil(MonospaceFontPreference.normalized("   "))
        XCTAssertNil(MonospaceFontPreference(family: "  ", size: 12).family)
        XCTAssertEqual(MonospaceFontPreference.normalized(" Menlo "), "Menlo")
    }

    // MARK: - 字号

    func testPreferenceClampsSizeOnInitAndOnChange() {
        XCTAssertEqual(MonospaceFontPreference(family: nil, size: 100).size, MonospaceFontSize.maximum)
        XCTAssertEqual(MonospaceFontPreference(family: nil, size: 1).size, MonospaceFontSize.minimum)
        XCTAssertEqual(MonospaceFontPreference.default.withSize(999).size, MonospaceFontSize.maximum)
        XCTAssertEqual(MonospaceFontPreference.default.withSize(14).size, 14)
    }

    func testWithFamilyKeepsSizeAndViceVersa() {
        let preference = MonospaceFontPreference(family: "Menlo", size: 15)
        XCTAssertEqual(preference.withFamily("SF Mono").size, 15)
        XCTAssertEqual(preference.withSize(11).family, "Menlo")
    }

    // MARK: - 持久化

    /// 偏好读回来：缺省 / 类型不对 / 越界都要回落，不能让界面起不来。
    func testResolveFallsBackForMissingOrForeignValues() {
        XCTAssertEqual(MonospaceFontPreference.resolve(family: nil, size: nil), .default)
        XCTAssertEqual(MonospaceFontPreference.resolve(family: 42, size: "13").family, nil)
        XCTAssertEqual(MonospaceFontPreference.resolve(family: 42, size: "13").size, MonospaceFontSize.default)
        XCTAssertEqual(MonospaceFontPreference.resolve(family: "Menlo", size: 99).size, MonospaceFontSize.maximum)
        XCTAssertEqual(MonospaceFontPreference.resolve(family: "Menlo", size: 14).family, "Menlo")
    }

    /// 键名是持久化契约：改了等于让用户偏好失效，所以钉住。
    func testStorageKeysAreStable() {
        XCTAssertEqual(MonospaceFontPreference.Storage.familyKey, "font.monoFamily")
        XCTAssertEqual(MonospaceFontPreference.Storage.sizeKey, "font.monoSize")
        XCTAssertEqual(AppearancePreference.Storage.appKey, "appearance.mode")
        XCTAssertEqual(AppearancePreference.Storage.terminalKey, "terminal.appearance")
    }

    // MARK: - 外观三态（应用主题与终端共用一份）

    func testForcedDarkMirrorsTheThreeState() {
        XCTAssertNil(AppearancePreference.followSystem.forcedDark, "跟随系统必须是 nil，交给 preferredColorScheme(nil)")
        XCTAssertEqual(AppearancePreference.alwaysDark.forcedDark, true)
        XCTAssertEqual(AppearancePreference.alwaysLight.forcedDark, false)
    }

    /// 终端的类型别名与应用主题是同一个类型 —— 一份实现，两个消费者。
    func testTerminalAppearanceIsTheSameType() {
        let viaAlias: TerminalAppearance = .alwaysDark
        XCTAssertEqual(viaAlias, AppearancePreference.alwaysDark)
        XCTAssertEqual(Set(TerminalAppearance.allCases).count, 3)
    }
}
