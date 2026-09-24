import Foundation

/// 补全列表里的一条候选。
public struct CodeCompletionItem: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case keyword
        case builtin
        case snippet
        case word
    }

    /// 列表里显示的文本（就是匹配用的前缀词）。
    public let label: String
    /// 实际插入的文本（片段的插入文本比 label 长）。
    public let insertText: String
    /// 右侧说明的**文案键**（界面按当前语言解析；Core 不持有中文）。
    public let detailKey: LKey
    public let kind: Kind

    public init(label: String, insertText: String, detailKey: LKey, kind: Kind) {
        self.label = label
        self.insertText = insertText
        self.detailKey = detailKey
        self.kind = kind
    }
}

/// 代码补全的候选策略（FR-EDIT-36）——**纯函数、可单测**。
///
/// 与 SQL 侧的 `QueryCompletion` 同源同规矩：候选顺序与准入条件是这个功能里唯一被用户直接感知的部分，
/// 藏在 AppKit 回调里就只能靠手点验证。三条规则是**刻意的选择**：
///
/// 1. **关键字 → 片段 → 内置 → 文档词**：`ret` 第一个永远是 `return`，
///    不因为用户文档里恰好有个 `retryCount` 就漂到后面 —— 肌肉记忆比"更懂我"值钱。
/// 2. **空前缀不给候选**：一打开文件就弹一屏候选不是补全，是噪音。
/// 3. **同一 label 只出现一次**，顺序取优先级最高的那种（关键字 > 片段 > 文档词）。
///
/// 大小写规则**随语言**：SQL / HTML / CSS 不区分（`sel` 命中 `SELECT`），
/// JS / TS / Python 区分（`Con` 不该命中 `const`）。
public enum CodeCompletion {

    /// 候选总数上限（一屏能看完 —— 与编辑器既有面板一致）。
    public static let totalLimit = 20

    /// 文档词最多带几条（关键字永远优先占位）。
    public static let documentWordLimit = 5

    /// 文档词的准入长度：太短（`a` / `id`）会把列表刷满噪音，太长多半是拼出来的长标识符。
    public static let minimumWordLength = 3
    public static let maximumWordLength = 40

    /// 候选。
    ///
    /// - Parameters:
    ///   - prefix: 光标处正在输入的词（**空前缀返回空**，见规则 2）。
    ///   - language: 判语言决定关键字表、片段与大小写规则。
    ///   - documentWords: 当前文档里的候选词（`words(in:language:)` 的结果）；为空则只给关键字与片段。
    public static func suggestions(
        prefix: String,
        language: TextLanguage,
        documentWords: [String] = []
    ) -> [CodeCompletionItem] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let syntax = CodeSyntax.of(language)
        let needle = syntax.normalized(trimmed)
        var items: [CodeCompletionItem] = []
        var seen: Set<String> = []

        func append(label: String, insertText: String, detailKey: LKey, kind: CodeCompletionItem.Kind) {
            guard items.count < totalLimit else { return }
            let key = syntax.normalized(label)
            guard !seen.contains(key) else { return }
            seen.insert(key)
            items.append(CodeCompletionItem(label: label, insertText: insertText, detailKey: detailKey, kind: kind))
        }

        for keyword in syntax.keywords where syntax.normalized(keyword).hasPrefix(needle) {
            append(label: keyword, insertText: keyword, detailKey: .codeDetailKeyword, kind: .keyword)
        }
        // 片段排在内置**之前**：同样敲 `log`，用户要的是 `console.log()` 这一段可用代码，
        // 而不是一个光秃秃的内置名 `log`。
        for snippet in syntax.snippets where syntax.normalized(snippet.label).hasPrefix(needle) {
            append(label: snippet.label, insertText: snippet.insertText, detailKey: snippet.detailKey, kind: .snippet)
        }
        for builtin in syntax.builtins where syntax.normalized(builtin).hasPrefix(needle) {
            append(label: builtin, insertText: builtin, detailKey: .codeDetailBuiltin, kind: .builtin)
        }

        var appendedWords = 0
        for word in documentWords where appendedWords < documentWordLimit {
            guard items.count < totalLimit else { break }
            guard word.count >= minimumWordLength, word.count <= maximumWordLength else { continue }
            guard !word.allSatisfy({ $0.isNumber }) else { continue }
            guard syntax.normalized(word).hasPrefix(needle) else { continue }
            let before = items.count
            append(label: word, insertText: word, detailKey: .codeDetailDocument, kind: .word)
            if items.count > before { appendedWords += 1 }
        }

        return items
    }

    /// 从文本里抽取候选词：**先去重、再按出现次数排序**（出现多的更可能是这个文件在用的东西）。
    ///
    /// 词法用 `CodeLexer` 的 `.identifier` —— 这样字符串与注释里的词不会被当成候选
    /// （否则文档里一句注释就能把补全列表带偏）。
    public static func words(in text: String, language: TextLanguage, limit: Int = 200) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for token in CodeLexer.tokens(in: text, language: language) where token.kind == .identifier {
            let word = String(text[token.range])
            guard word.count >= minimumWordLength, word.count <= maximumWordLength else { continue }
            if counts[word] == nil { order.append(word) }
            counts[word, default: 0] += 1
        }
        let sorted = order.sorted { left, right in
            let leftCount = counts[left] ?? 0
            let rightCount = counts[right] ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            return false    // 次数相同保持首次出现顺序（稳定）
        }
        return Array(sorted.prefix(limit))
    }

    /// 插入片段后光标该落在哪（相对插入文本的偏移）。
    ///
    /// 约定（按优先级）：
    /// 1. 有**空行占位**的（`{\n  \n}`）→ 落在那一行的缩进处（函数体最常见）；
    /// 2. HTML 的 `<tag></tag>` → 落在两个标签之间；
    /// 3. 末尾的空对（`()` / `{}` / `[]` / `""`）→ 落在其中（`console.log()`）；
    /// 4. 都不满足 → 落在末尾。
    ///
    /// 为什么不用带占位符的 snippet 语法：那需要编辑器支持 Tab 跳位，而我们没有；
    /// 一个"落在合理位置"的纯文本插入不会有留下未清理占位符的风险。
    public static func caretOffset(inInsertText text: String) -> Int {
        // 末行是空白且有换行：那是"等着你在这里写"的函数体（`def name():\n    `）→ 落在末尾。
        // 不先判这一条，下面的"末尾空对"会把光标拽回 `()` 里。
        if text.contains("\n"),
           let lastNewline = text.lastIndex(of: "\n"),
           text[text.index(after: lastNewline)...].allSatisfy({ $0 == " " || $0 == "\t" }),
           text[text.index(after: lastNewline)...].count >= 0 {
            return text.count
        }
        if let placeholder = blankLinePlaceholderOffset(in: text) { return placeholder }
        if let range = text.range(of: "></") {
            return text.distance(from: text.startIndex, to: range.lowerBound) + 1
        }
        for pair in ["()", "{}", "[]", "\"\"", "''"] {
            if let range = text.range(of: pair, options: .backwards) {
                return text.distance(from: text.startIndex, to: range.lowerBound) + 1
            }
        }
        return text.count
    }

    /// 形如 `{\n  \n}` 的空行占位：返回空行缩进结束处的偏移。
    private static func blankLinePlaceholderOffset(in text: String) -> Int? {
        let characters = Array(text)
        guard characters.count >= 3 else { return nil }
        var index = 0
        while index < characters.count {
            guard characters[index] == "\n" else { index += 1; continue }
            var cursor = index + 1
            var spaces = 0
            while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" {
                spaces += 1
                cursor += 1
            }
            // 这一行只有空白、且不是最后一行 → 它就是占位行
            if cursor < characters.count, characters[cursor] == "\n", spaces >= 0, cursor != index + 1 {
                return cursor
            }
            if cursor < characters.count, characters[cursor] == "\n", spaces == 0 {
                return cursor
            }
            index = cursor
        }
        return nil
    }
}
