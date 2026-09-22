import XCTest
@testable import DoyahCore

final class LocalizationTests: XCTestCase {

    func testEveryKeyHasBothLanguagesAndNoEmptyText() {
        for key in LKey.allCases {
            for language in AppLanguage.allCases {
                guard let value = LocalizedStrings.table[key]?[language] else {
                    XCTFail("缺少文案：\(key.rawValue) / \(language.rawValue)")
                    continue
                }
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "文案为空：\(key.rawValue) / \(language.rawValue)"
                )
            }
        }
    }

    func testTableCoversEveryDeclaredKey() {
        for key in LKey.allCases {
            XCTAssertNotNil(LocalizedStrings.table[key], "table 缺少 key：\(key.rawValue)")
        }
        XCTAssertEqual(LocalizedStrings.table.count, LKey.allCases.count)
    }

    func testLanguageIdentifiers() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.rawValue, "zh-Hans")
        XCTAssertEqual(AppLanguage.english.rawValue, "en")
        XCTAssertEqual(AppLanguage.allCases.count, 2)
        XCTAssertEqual(AppLanguage.simplifiedChinese.displayName, "简体中文")
        XCTAssertEqual(AppLanguage.english.displayName, "English")
    }

    func testFormattingFollowsLanguage() {
        let zh = LocalizedStrings.format(.resultSize, language: .simplifiedChinese, 3, 2)
        let en = LocalizedStrings.format(.resultSize, language: .english, 3, 2)

        XCTAssertEqual(zh, "3 行 · 2 列")
        XCTAssertEqual(en, "3 rows · 2 columns")
    }

    func testDiagnosticsFollowLanguage() {
        let zh = SQLLinter(databaseType: .postgresql, language: .simplifiedChinese).analyze("SELECT 'abc")
        let en = SQLLinter(databaseType: .postgresql, language: .english).analyze("SELECT 'abc")

        XCTAssertEqual(zh.count, 1)
        XCTAssertTrue(zh[0].message.contains("字符串"))
        XCTAssertEqual(en.count, 1)
        XCTAssertTrue(en[0].message.lowercased().contains("unterminated string"))
    }

    func testSystemDefaultIsOneOfSupportedLanguages() {
        XCTAssertTrue(AppLanguage.allCases.contains(AppLanguage.systemDefault))
    }
}
