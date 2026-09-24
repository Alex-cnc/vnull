import XCTest
@testable import DoyahCore

/// 多语言词法器（FR-EDIT-36）。
///
/// 这里钉的都是"错了会误导人"的地方：字符串里的关键字、注释里的引号、
/// SQL 的大小写不敏感、Python 的三引号串、HTML 标签与文本的边界。
final class CodeLexerTests: XCTestCase {

    private func marked(_ text: String, _ language: TextLanguage) -> [(String, String)] {
        CodeLexer.highlightedTokens(in: text, language: language).map {
            ($0.kind.rawValue, String(text[$0.range]))
        }
    }

    // MARK: JavaScript

    func testJavaScriptKeywordsStringsAndComments() {
        let code = """
        // 注释里的 if 不算关键字
        const s = "if (x) {}";
        let n = 42;
        """
        let tokens = marked(code, .javascript)
        XCTAssertEqual(tokens.filter { $0.0 == "keyword" }.map(\.1), ["const", "let"])
        XCTAssertEqual(tokens.filter { $0.0 == "string" }.map(\.1), ["\"if (x) {}\""])
        XCTAssertEqual(tokens.filter { $0.0 == "number" }.map(\.1), ["42"])
        XCTAssertEqual(tokens.filter { $0.0 == "comment" }.count, 1)
        // 注释里的 `if` 与字符串里的 `if` 都不该出现在关键字里
        XCTAssertFalse(tokens.contains { $0.0 == "keyword" && $0.1 == "if" })
    }

    /// `ifx` 不是关键字 —— 前缀匹配是这类实现最容易犯的错。
    func testIdentifierPrefixIsNotAKeyword() {
        XCTAssertTrue(marked("ifx = 1", .javascript).filter { $0.0 == "keyword" }.isEmpty)
        XCTAssertTrue(marked("iffy", .javascript).filter { $0.0 == "keyword" }.isEmpty)
    }

    /// 模板串（反引号）整体是一个字符串，里面的 `${}` 不另作处理。
    func testTemplateLiteralIsOneString() {
        let tokens = marked("const t = `a ${b} c`;", .javascript)
        XCTAssertEqual(tokens.filter { $0.0 == "string" }.map(\.1), ["`a ${b} c`"])
    }

    /// 转义引号不结束字符串。
    func testEscapedQuoteDoesNotEndString() {
        let tokens = marked(#"const s = "a\"b";"#, .javascript)
        XCTAssertEqual(tokens.filter { $0.0 == "string" }.map(\.1), [#""a\"b""#])
    }

    func testMultiLineBlockComment() {
        let tokens = marked("/* a\nb */ const x = 1", .javascript)
        XCTAssertEqual(tokens.filter { $0.0 == "comment" }.map(\.1), ["/* a\nb */"])
        XCTAssertEqual(tokens.filter { $0.0 == "keyword" }.map(\.1), ["const"])
    }

    /// 内置名与关键字分开（`console.log` 里两个都该有颜色，但分类不同）。
    func testBuiltinsAreDistinguishedFromKeywords() {
        let tokens = marked("console.log(value)", .javascript)
        XCTAssertEqual(tokens.filter { $0.0 == "builtin" }.map(\.1), ["console", "log"])
    }

    // MARK: TypeScript

    func testTypeScriptAddsTypeKeywords() {
        let tokens = marked("interface User { name: string }", .typescript)
        XCTAssertEqual(tokens.filter { $0.0 == "keyword" }.map(\.1), ["interface", "string"])
    }

    // MARK: SQL

    /// SQL 关键字**大小写不敏感**：`select` 与 `SELECT` 都算。
    func testSQLIsCaseInsensitive() {
        let lower = marked("select 1", .sql)
        let upper = marked("SELECT 1", .sql)
        XCTAssertEqual(lower.filter { $0.0 == "keyword" }.map(\.1), ["select"])
        XCTAssertEqual(upper.filter { $0.0 == "keyword" }.map(\.1), ["SELECT"])
    }

    /// SQL 的 `''` 是转义引号，串要继续；`--` 是行注释。
    func testSQLDoubledQuoteAndLineComment() {
        let tokens = marked("SELECT 'it''s ok' -- 注释里的 SELECT", .sql)
        XCTAssertEqual(tokens.filter { $0.0 == "string" }.map(\.1), ["'it''s ok'"])
        XCTAssertEqual(tokens.filter { $0.0 == "comment" }.map(\.1), ["-- 注释里的 SELECT"])
        XCTAssertEqual(tokens.filter { $0.0 == "keyword" }.map(\.1), ["SELECT"])
    }

    /// SQL 关键字与内置函数来自方言（同一份定义），这里只抽查两个常见的。
    func testSQLUsesDialectVocabulary() {
        let tokens = marked("SELECT count(*) FROM t", .sql)
        XCTAssertTrue(tokens.contains { $0.0 == "builtin" && $0.1.lowercased() == "count" })
        XCTAssertTrue(tokens.contains { $0.0 == "keyword" && $0.1.lowercased() == "from" })
    }

    // MARK: HTML

    func testHTMLTagsAttributesAndComments() {
        let html = """
        <!-- 注释 -->
        <div class="box">text</div>
        """
        let tokens = marked(html, .html)
        XCTAssertEqual(tokens.filter { $0.0 == "comment" }.count, 1)
        XCTAssertEqual(tokens.filter { $0.0 == "keyword" }.map(\.1), ["div", "div"])
        XCTAssertEqual(tokens.filter { $0.0 == "builtin" }.map(\.1), ["class"])
        XCTAssertEqual(tokens.filter { $0.0 == "string" }.map(\.1), ["\"box\""])
        // 标签外的文本不该被着色
        XCTAssertFalse(tokens.contains { $0.1 == "text" })
    }

    /// `x < y` 不该被当成标签的开始（用 x/y 而不是 a/b：`a` 本来就是 HTML 的标签名）。
    func testHTMLComparisonsDoNotOpenTags() {
        XCTAssertTrue(marked("x < y", .html).isEmpty)
    }

    // MARK: CSS

    func testCSSPropertiesAndAtRules() {
        let css = """
        @media screen {
          background-color: #fff;
          --brand: red;
        }
        """
        let tokens = marked(css, .css)
        XCTAssertTrue(tokens.contains { $0.0 == "keyword" && $0.1 == "@media" })
        XCTAssertTrue(tokens.contains { $0.0 == "builtin" && $0.1 == "background-color" })
        // 表里没有的属性名（自定义属性）只要后面跟冒号，也算属性；
        // 前导的 `--` 是标点，被识别成属性的是 `brand` 这一段。
        XCTAssertTrue(tokens.contains { $0.0 == "builtin" && $0.1 == "brand" })
    }

    // MARK: Python

    func testPythonDocstringAndComment() {
        let code = """
        def f():
            \"\"\"文档：这里的 # 不是注释\"\"\"
            return 1  # 真的注释
        """
        let tokens = marked(code, .python)
        XCTAssertEqual(tokens.filter { $0.0 == "keyword" }.map(\.1), ["def", "return"])
        XCTAssertEqual(tokens.filter { $0.0 == "comment" }.map(\.1), ["# 真的注释"])
        XCTAssertEqual(tokens.filter { $0.0 == "string" }.count, 1)
    }

    // MARK: JSON

    func testJSONLiteralsAreKeywords() {
        let tokens = marked(#"{"ok": true, "n": null}"#, .json)
        XCTAssertEqual(tokens.filter { $0.0 == "keyword" }.map(\.1), ["true", "null"])
        XCTAssertEqual(tokens.filter { $0.0 == "string" }.count, 2)
    }

    // MARK: 通用性质

    /// 记号必须**按顺序、不重叠**地覆盖被着色区域 —— 重叠会让属性串拼接出错。
    func testTokensAreOrderedAndDisjoint() {
        let code = "const a = \"x\"; /* c */ function f() { return 1 }"
        let tokens = CodeLexer.tokens(in: code, language: .javascript)
        var previousEnd = code.startIndex
        for token in tokens {
            XCTAssertGreaterThanOrEqual(token.range.lowerBound, previousEnd)
            previousEnd = token.range.upperBound
        }
    }

    /// 纯文本不着色（没有关键字表 / 注释 / 字符串）。
    func testPlainTextHasNothingToHighlight() {
        XCTAssertTrue(CodeLexer.highlightedTokens(in: "const x = 1 // 不是代码", language: .plainText).isEmpty)
    }

    /// **任何路径都必须前进**：`@` 曾经同时是"标识符起始"却不是"标识符体"，
    /// 于是 `@media` 消费 0 个字符、直接把进程挂死（当时是靠测试超时才发现）。
    /// 这里钉住"不会挂" + "结果正确"两件事。
    func testAtRulesDoNotHangAndAreKeywords() {
        let tokens = marked("@media (max-width: 600px) { }", .css)
        XCTAssertTrue(tokens.contains { $0.0 == "keyword" && $0.1 == "@media" })
    }

    /// 空文本与未闭合的结构不能崩、也不能吞掉后面的内容。
    func testUnterminatedStructuresDoNotHang() {
        XCTAssertEqual(marked("/* 没闭合", .javascript).filter { $0.0 == "comment" }.count, 1)
        XCTAssertEqual(marked("\"没闭合", .javascript).filter { $0.0 == "string" }.count, 1)
        XCTAssertEqual(marked("<div", .html).filter { $0.0 == "keyword" }.map(\.1), ["div"])
        XCTAssertTrue(CodeLexer.tokens(in: "", language: .sql).isEmpty)
    }
}
