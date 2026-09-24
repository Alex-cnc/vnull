import XCTest
@testable import DoyahCore

/// 按路径判语言（FR-EDIT-36）。
///
/// 这层判错的后果很具体：`.tsx` 当纯文本 → 没有着色、补全给的是空的；
/// `.gitignore` 被当成某种语言 → 满屏莫名其妙的关键字颜色。
final class TextLanguageTests: XCTestCase {

    func testDetectsByExtension() {
        XCTAssertEqual(TextLanguage.detect(path: "index.js"), .javascript)
        XCTAssertEqual(TextLanguage.detect(path: "app.tsx"), .typescript)
        XCTAssertEqual(TextLanguage.detect(path: "main.py"), .python)
        XCTAssertEqual(TextLanguage.detect(path: "style.scss"), .css)
        XCTAssertEqual(TextLanguage.detect(path: "/tmp/项目/查询.sql"), .sql)
        XCTAssertEqual(TextLanguage.detect(path: "data.json"), .json)
    }

    /// 大小写不敏感：`.SQL` / `.Js` 也要认（macOS 上文件名大小写不敏感，实测常见）。
    func testDetectionIsCaseInsensitive() {
        XCTAssertEqual(TextLanguage.detect(path: "QUERY.SQL"), .sql)
        XCTAssertEqual(TextLanguage.detect(path: "Index.Js"), .javascript)
    }

    /// 没有扩展名但认得出的文件名。
    func testDetectsByFileName() {
        XCTAssertEqual(TextLanguage.detect(path: "/Users/me/.zshrc"), .shell)
        XCTAssertEqual(TextLanguage.detect(path: ".bashrc"), .shell)
    }

    /// 认不出就**如实**回落纯文本，不给一个"看起来像"的语言。
    func testUnknownFallsBackToPlainText() {
        XCTAssertEqual(TextLanguage.detect(path: ".gitignore"), .plainText)
        XCTAssertEqual(TextLanguage.detect(path: "Makefile"), .plainText)
        XCTAssertEqual(TextLanguage.detect(path: "Dockerfile"), .plainText)
        XCTAssertEqual(TextLanguage.detect(path: "noextension"), .plainText)
        XCTAssertEqual(TextLanguage.detect(path: ""), .plainText)
        XCTAssertEqual(TextLanguage.detect(path: "weird."), .plainText)
    }

    /// 多段扩展名只看最后一段：`component.test.ts` 是 TypeScript。
    func testUsesLastExtensionOnly() {
        XCTAssertEqual(TextLanguage.detect(path: "component.test.ts"), .typescript)
        XCTAssertEqual(TextLanguage.detect(path: "archive.sql.bak"), .plainText)
    }

    /// 前端常见语言都要"是代码"（要有着色与补全）；纯文本 / markdown 不算。
    func testCodeLanguagesCoverTheFrontendSet() {
        for language in [TextLanguage.sql, .javascript, .typescript, .html, .css, .json, .python] {
            XCTAssertTrue(language.isCode, "\(language.rawValue) 应当按代码处理")
        }
        XCTAssertFalse(TextLanguage.plainText.isCode)
        XCTAssertFalse(TextLanguage.markdown.isCode)
    }
}
