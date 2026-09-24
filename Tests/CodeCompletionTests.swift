import XCTest
@testable import DoyahCore

/// 代码补全的候选策略（FR-EDIT-36）。
///
/// 与 `QueryCompletionTests` 同一套口径：顺序稳定、空前缀不给、同一条不重复、有上限。
final class CodeCompletionTests: XCTestCase {

    func testKeywordsComeFirstAndMatchPrefix() {
        let items = CodeCompletion.suggestions(prefix: "con", language: .javascript)
        XCTAssertEqual(items.first?.kind, .keyword)
        XCTAssertTrue(items.contains { $0.label == "const" })
        XCTAssertTrue(items.contains { $0.label == "continue" })
    }

    /// 空前缀返回空：一打开文件就弹一屏候选不是补全。
    func testEmptyPrefixGivesNothing() {
        XCTAssertTrue(CodeCompletion.suggestions(prefix: "", language: .javascript).isEmpty)
        XCTAssertTrue(CodeCompletion.suggestions(prefix: "   ", language: .javascript).isEmpty)
    }

    /// SQL / HTML / CSS 不区分大小写，JS / Python 区分。
    func testCaseSensitivityFollowsLanguage() {
        XCTAssertTrue(CodeCompletion.suggestions(prefix: "sel", language: .sql).contains { $0.label.lowercased() == "select" })
        XCTAssertTrue(CodeCompletion.suggestions(prefix: "SEL", language: .sql).contains { $0.label.lowercased() == "select" })
        // JS 区分：`CON` 不该命中 `const`
        XCTAssertFalse(CodeCompletion.suggestions(prefix: "CON", language: .javascript).contains { $0.label == "const" })
        XCTAssertTrue(CodeCompletion.suggestions(prefix: "con", language: .javascript).contains { $0.label == "const" })
    }

    /// 片段带 `insertText`（比 label 长），且说明写清楚它是片段。
    func testSnippetsCarryInsertText() {
        let items = CodeCompletion.suggestions(prefix: "log", language: .javascript)
        let snippet = items.first { $0.kind == .snippet }
        XCTAssertEqual(snippet?.label, "log")
        XCTAssertEqual(snippet?.insertText, "console.log()")
    }

    /// 文档词排在关键字 / 片段之后，最多 5 条。
    func testDocumentWordsComeLastAndAreLimited() {
        let words = ["constA", "constB", "constC", "constD", "constE", "constF", "constG"]
        let items = CodeCompletion.suggestions(prefix: "const", language: .javascript, documentWords: words)
        let wordItems = items.filter { $0.kind == .word }
        XCTAssertEqual(wordItems.count, CodeCompletion.documentWordLimit)
        // 关键字在前
        if let firstWordIndex = items.firstIndex(where: { $0.kind == .word }),
           let lastKeywordIndex = items.lastIndex(where: { $0.kind == .keyword }) {
            XCTAssertGreaterThan(firstWordIndex, lastKeywordIndex)
        }
    }

    /// 同一个 label 不重复出现（关键字与文档词同名时保留关键字那条）。
    func testNoDuplicateLabels() {
        let items = CodeCompletion.suggestions(prefix: "return", language: .javascript, documentWords: ["return", "returns"])
        let labels = items.map(\.label)
        XCTAssertEqual(labels.count, Set(labels).count)
        XCTAssertEqual(items.first { $0.label == "return" }?.kind, .keyword)
    }

    func testTotalLimitIsRespected() {
        let manyWords = (0..<100).map { "prefixword\($0)" }
        let items = CodeCompletion.suggestions(prefix: "p", language: .python, documentWords: manyWords)
        XCTAssertLessThanOrEqual(items.count, CodeCompletion.totalLimit)
    }

    /// 文档词来自**真实词法**：字符串与注释里的词不该进候选（否则注释能把列表带偏）。
    func testDocumentWordsSkipStringsAndComments() {
        let text = """
        // commentOnlyWord
        const realWord = "stringOnlyWord";
        """
        let words = CodeCompletion.words(in: text, language: .javascript)
        XCTAssertTrue(words.contains("realWord"))
        XCTAssertFalse(words.contains("commentOnlyWord"))
        XCTAssertFalse(words.contains("stringOnlyWord"))
    }

    /// 出现次数多的排前面。
    func testDocumentWordsSortedByFrequency() {
        let text = "alpha beta beta gamma gamma gamma"
        XCTAssertEqual(Array(CodeCompletion.words(in: text, language: .javascript).prefix(2)), ["gamma", "beta"])
    }

    func testCaretOffsetForCommonSnippets() {
        XCTAssertEqual(CodeCompletion.caretOffset(inInsertText: "console.log()"), 12)          // 括号内
        XCTAssertEqual(CodeCompletion.caretOffset(inInsertText: "<div></div>"), 5)             // 标签之间
        XCTAssertEqual(CodeCompletion.caretOffset(inInsertText: "def name():\n    "), 16)      // 行尾（函数体缩进处）
        XCTAssertEqual(CodeCompletion.caretOffset(inInsertText: "SELECT * FROM "), 14)         // 末尾
        // `{\n  \n}`：落在空行缩进处
        let body = CodeCompletion.caretOffset(inInsertText: "function name() {\n  \n}")
        XCTAssertEqual(body, 20)
    }
}
