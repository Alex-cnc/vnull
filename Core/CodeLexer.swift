import Foundation

/// 一个着色记号。
public struct CodeToken: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// 语言关键字（`const` / `SELECT` / `def`…）
        case keyword
        /// 内置名 / 属性 / 标签属性（`console` / `color` / `class`…）
        case builtin
        /// 字符串字面量（含模板串）
        case string
        /// 注释
        case comment
        /// 数字字面量
        case number
        /// 普通标识符（**通常不着色**，留出来是为了将来做"符号高亮 / 跳转"）
        case identifier
        /// HTML 里的标签名（不在关键字表里的那些）
        case tag
        /// HTML 里不在内置表里的属性名
        case attribute
        /// 标点与运算符
        case punctuation

        /// 默认要不要上色 —— 标识符与标点保持正文色。
        public var isHighlighted: Bool {
            switch self {
            case .keyword, .builtin, .string, .comment, .number, .tag, .attribute: return true
            case .identifier, .punctuation: return false
            }
        }
    }

    public let kind: Kind
    public let range: Range<String.Index>

    public init(kind: Kind, range: Range<String.Index>) {
        self.kind = kind
        self.range = range
    }
}

/// 多语言**轻量词法器**：把文本切成着色记号（FR-EDIT-36）。
///
/// 定位与 `SQLLexer` 一致 —— **只做词法，不做语法分析**。目标是把"该上色的地方上色"这件事
/// 做对：字符串里的 `if` 不能被着成关键字，注释里的引号不能开启一个字符串。
/// 这类错误的代价不是崩溃而是**误导**：颜色错了，读代码的人会以为自己在看语法。
///
/// 覆盖范围（2026-09-24 需求提出者口径，先前端常见语言）：
/// JavaScript / TypeScript / SQL / HTML / CSS / JSON / Python，外加 YAML / Shell / Markdown 的轻量支持。
/// **新增语言不需要改这里** —— 只要在 `CodeSyntax` 里补一份定义（注释 / 字符串 / 关键字表 / 大小写）。
public enum CodeLexer {

    /// 全量切分（含标识符与标点 —— 便于测试与将来做符号功能）。
    public static func tokens(in text: String, language: TextLanguage) -> [CodeToken] {
        guard !text.isEmpty else { return [] }
        // 纯文本**一个记号都不给**：连数字都不该着色（它不是代码，颜色只会让人以为那是语法）。
        guard language != .plainText else { return [] }
        let syntax = CodeSyntax.of(language)
        var scanner = Scanner(text: text, syntax: syntax, isHTML: language == .html, isCSS: language == .css)
        return scanner.run()
    }

    /// 只取需要着色的记号（界面侧的高频路径：少一次过滤、少一批 attributed run）。
    public static func highlightedTokens(in text: String, language: TextLanguage) -> [CodeToken] {
        tokens(in: text, language: language).filter { $0.kind.isHighlighted }
    }
}

// MARK: - 扫描器

private struct Scanner {
    let text: String
    let syntax: CodeSyntax
    let isHTML: Bool
    let isCSS: Bool

    private var index: String.Index
    private var tokens: [CodeToken] = []

    init(text: String, syntax: CodeSyntax, isHTML: Bool, isCSS: Bool) {
        self.text = text
        self.syntax = syntax
        self.isHTML = isHTML
        self.isCSS = isCSS
        self.index = text.startIndex
    }

    mutating func run() -> [CodeToken] {
        while index < text.endIndex {
            let character = text[index]

            if isHTML, character == "<", matchCommentOrTag() { continue }
            if matchComment() { continue }
            if matchString() { continue }

            if character.isNumber, matchNumber() { continue }
            if isIdentifierStart(character) {
                let word = matchIdentifier()
                guard !word.isEmpty else {
                    // **零宽匹配必须前进一格**，否则就是死循环。这里踩过一次真的：
                    // `@` 被算作"标识符起始"、却不在"标识符体"里 → 消费 0 个字符，
                    // 于是 `@media` 直接把进程挂死（测试超时才暴露出来）。
                    // 与其只修那一个字符的集合，不如在这里保证"任何路径都前进"。
                    let start = index
                    index = text.index(after: index)
                    tokens.append(CodeToken(kind: .punctuation, range: start..<index))
                    continue
                }
                emit(word: word)
                continue
            }
            // 标点：单字符一个记号。**不做多字符运算符合并** —— 着色不需要，
            // 而"把 `=>` 合成一个 token"会让将来做符号时更难拆。
            let start = index
            index = text.index(after: index)
            tokens.append(CodeToken(kind: .punctuation, range: start..<index))
        }
        return tokens
    }

    // MARK: 注释

    private mutating func matchComment() -> Bool {
        for style in syntax.comments {
            guard hasPrefix(style.open, at: index) else { continue }
            // 行注释：吃到行尾（不含换行）
            if style.isLine {
                var cursor = text.index(index, offsetBy: style.open.count)
                while cursor < text.endIndex, text[cursor] != "\n" {
                    cursor = text.index(after: cursor)
                }
                tokens.append(CodeToken(kind: .comment, range: index..<cursor))
                index = cursor
                return true
            }
            guard let close = style.close else { continue }
            var cursor = text.index(index, offsetBy: style.open.count)
            while cursor < text.endIndex, !hasPrefix(close, at: cursor) {
                cursor = text.index(after: cursor)
            }
            if cursor < text.endIndex {
                cursor = text.index(cursor, offsetBy: close.count)
            }
            tokens.append(CodeToken(kind: .comment, range: index..<cursor))
            index = cursor
            return true
        }
        return false
    }

    // MARK: 字符串

    private mutating func matchString() -> Bool {
        for delimiter in syntax.stringDelimiters where hasPrefix(delimiter, at: index) {
            // Python 的三引号串：`"""…"""` —— 不识别它的话，串里的 `#` 会被当成注释，
            // 后面的内容就全错了（文档字符串是最常见的一段多行文本）。
            let isTriple = delimiter.count == 1 && hasPrefix(String(repeating: delimiter, count: 3), at: index)
            let open = isTriple ? String(repeating: delimiter, count: 3) : delimiter
            var cursor = text.index(index, offsetBy: open.count)
            while cursor < text.endIndex {
                // 双写引号 = 转义（SQL）：**必须先判它**，否则 `'it''s'` 会在第一个 `'` 处被切开。
                if !isTriple, syntax.usesDoubledQuoteEscape, hasPrefix(delimiter + delimiter, at: cursor) {
                    cursor = text.index(cursor, offsetBy: 2)
                    continue
                }
                if hasPrefix(open, at: cursor) {
                    cursor = text.index(cursor, offsetBy: open.count)
                    break
                }
                let character = text[cursor]
                if character == "\\", !isTriple {
                    // 反斜杠转义（JS / Python / Shell）—— 跳过两个字符
                    cursor = text.index(after: cursor)
                    if cursor < text.endIndex { cursor = text.index(after: cursor) }
                    continue
                }
                cursor = text.index(after: cursor)
            }
            tokens.append(CodeToken(kind: .string, range: index..<cursor))
            index = cursor
            return true
        }
        return false
    }

    // MARK: 数字

    private mutating func matchNumber() -> Bool {
        let start = index
        var cursor = index
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isNumber || character.isHexDigit && (character.isLetter) {
                cursor = text.index(after: cursor)
                continue
            }
            if character == "." || character == "_" {
                let next = text.index(after: cursor)
                if next < text.endIndex, text[next].isNumber || text[next].isHexDigit {
                    cursor = next
                    continue
                }
            }
            break
        }
        // 数字后面紧跟字母（`123abc`）时按"标识符优先"处理不了，就照数字收下 —— 真实代码里罕见。
        guard cursor > start else { return false }
        tokens.append(CodeToken(kind: .number, range: start..<cursor))
        index = cursor
        return true
    }

    // MARK: 标识符 / 关键字 / HTML

    private mutating func matchIdentifier() -> String {
        let start = index
        var cursor = index
        while cursor < text.endIndex, isIdentifierBody(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        let word = String(text[start..<cursor])
        index = cursor
        return word
    }

    private mutating func emit(word: String) {
        let start = text.index(index, offsetBy: -word.count)
        let range = start..<index
        if syntax.isKeyword(word) {
            tokens.append(CodeToken(kind: .keyword, range: range))
        } else if syntax.isBuiltin(word) {
            tokens.append(CodeToken(kind: .builtin, range: range))
        } else if isCSS, isPropertyPosition() {
            // CSS 的属性名不一定在我们的表里（用户自定义属性 `--brand` 也在内）：
            // **后面紧跟冒号**的标识符就是属性名。
            tokens.append(CodeToken(kind: .builtin, range: range))
        } else {
            tokens.append(CodeToken(kind: .identifier, range: range))
        }
    }

    /// 当前位置之后（跳过空白）是不是冒号 —— 用来判断 CSS 的属性名。
    private func isPropertyPosition() -> Bool {
        var cursor = index
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        return cursor < text.endIndex && text[cursor] == ":"
    }

    /// HTML：`<!-- 注释 -->` 与 `<tag attr="v">`。
    private mutating func matchCommentOrTag() -> Bool {
        if hasPrefix("<!--", at: index) {
            var cursor = text.index(index, offsetBy: 4)
            while cursor < text.endIndex, !hasPrefix("-->", at: cursor) {
                cursor = text.index(after: cursor)
            }
            if cursor < text.endIndex { cursor = text.index(cursor, offsetBy: 3) }
            tokens.append(CodeToken(kind: .comment, range: index..<cursor))
            index = cursor
            return true
        }
        guard hasPrefix("<", at: index) else { return false }
        let afterBracket = text.index(after: index)
        guard afterBracket < text.endIndex else { return false }
        // 只有 `<` 后面紧跟字母 / `/` / `!` 才算标签（`a < b` 不该进标签模式）
        guard text[afterBracket].isLetter || text[afterBracket] == "/" || text[afterBracket] == "!" else { return false }

        var cursor = index
        var isFirstWord = true
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == ">" {
                let end = text.index(after: cursor)
                tokens.append(CodeToken(kind: .punctuation, range: cursor..<end))
                index = end
                return true
            }
            if character == "/" || character == "=" || character == "<" || character == "!" || character == "-" {
                let end = text.index(after: cursor)
                tokens.append(CodeToken(kind: .punctuation, range: cursor..<end))
                cursor = end
                continue
            }
            if character == "\"" || character == "'" {
                let delimiter = String(character)
                var end = text.index(after: cursor)
                while end < text.endIndex, String(text[end]) != delimiter {
                    end = text.index(after: end)
                }
                if end < text.endIndex { end = text.index(after: end) }
                tokens.append(CodeToken(kind: .string, range: cursor..<end))
                cursor = end
                continue
            }
            if character.isLetter || character == "_" || character == ":" {
                let start = cursor
                var end = cursor
                while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" || text[end] == "-" || text[end] == ":" {
                    end = text.index(after: end)
                }
                let word = String(text[start..<end])
                let kind: CodeToken.Kind = isFirstWord
                    ? (syntax.isKeyword(word) ? .keyword : .tag)
                    : (syntax.isBuiltin(word) ? .builtin : .attribute)
                tokens.append(CodeToken(kind: kind, range: start..<end))
                isFirstWord = false
                cursor = end
                continue
            }
            cursor = text.index(after: cursor)
        }
        // 没有闭合的 `>`：把已经认出来的收下，剩下的交给普通循环
        index = cursor
        return true
    }

    // MARK: 工具

    private func hasPrefix(_ prefix: String, at position: String.Index) -> Bool {
        text[position...].hasPrefix(prefix)
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$" || character == "@"
    }

    /// 标识符**体内**允许的字符 —— 必须包含 `isIdentifierStart` 允许的全部字符。
    ///
    /// 这两者不一致就会产生"消费 0 个字符"的死循环（`@` 曾经就是这样，见 `run()` 里的防御）。
    private func isIdentifierBody(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber || character == "-"
    }
}
