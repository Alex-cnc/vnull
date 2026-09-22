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

    // MARK: - 文案内容自洽（防「串位」与漏翻）

    /// 语言中立的键：本来就是同一个串，或本来就不含汉字（URL / 模型名 / 通用术语）。
    ///
    /// 只有这三个键允许「中英同形」或「中文里没有汉字」，其余键都必须是真的中文，
    /// 否则就是「把英文抄进了中文槽位」。
    private static let languageNeutralKeys: Set<LKey> = [
        .agentEndpointPlaceholder,
        .agentModelPlaceholder,
        .agentAPIKey
    ]

    /// 英文文案里不得残留汉字。
    ///
    /// 这条直接对应 SRS 的验收口径「切换后逐页检查不得残留硬编码中 / 英文」，
    /// 也是夜间记录里那次「文案串位」（`字符串没有闭合` 变成 `功能尚未实现：%@`）
    /// 的自动化探针：key 覆盖齐全但内容对错了位，靠数量校验是查不出来的。
    func testEnglishTextCarriesNoChineseResidue() {
        let han = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")
        for key in LKey.allCases where !Self.languageNeutralKeys.contains(key) {
            let english = LocalizedStrings.table[key]?[.english] ?? ""
            XCTAssertNil(
                english.rangeOfCharacter(from: han),
                "英文文案里出现汉字（疑似串位或漏翻）：\(key.rawValue) → \(english)"
            )
        }
    }

    /// 中文文案必须真的是中文，不能是英文原文。
    func testChineseTextIsLocalizedNotLeftInEnglish() {
        let han = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")
        for key in LKey.allCases where !Self.languageNeutralKeys.contains(key) {
            let chinese = LocalizedStrings.table[key]?[.simplifiedChinese] ?? ""
            XCTAssertNotNil(
                chinese.rangeOfCharacter(from: han),
                "中文文案里没有汉字（疑似把英文抄进了中文槽位）：\(key.rawValue) → \(chinese)"
            )
        }
    }

    /// 两种语言的 `String(format:)` 占位符必须**逐位一致**。
    ///
    /// 占位符种类或顺序不一致时，`String(format:)` 会静默产出错值（甚至读越界），
    /// 界面上表现为「数字 / 名称串到了别的位置」——同样是数量校验查不出来的。
    func testFormatSpecifiersMatchBetweenLanguages() {
        for key in LKey.allCases {
            let chinese = LocalizedStrings.table[key]?[.simplifiedChinese] ?? ""
            let english = LocalizedStrings.table[key]?[.english] ?? ""
            XCTAssertEqual(
                Self.formatSpecifiers(in: chinese),
                Self.formatSpecifiers(in: english),
                "中英占位符不一致：\(key.rawValue)\n  中：\(chinese)\n  英：\(english)"
            )
        }
    }

    /// 取出形如 `%@` / `%d` / `%.2f` / `%1$@` 的占位符（保持出现顺序）。
    private static func formatSpecifiers(in text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?[-+ #0]*[\d.]*(?:hh|h|ll|l|L|z|j|t)?[@dioufFeEgGxXscpaA]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
