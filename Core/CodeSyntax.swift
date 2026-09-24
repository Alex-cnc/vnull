import Foundation

/// 一段注释的形态：`open` + 可选 `close`（没有 close 就是行注释）。
public struct CodeCommentStyle: Sendable, Equatable {
    public let open: String
    public let close: String?

    public init(line: String) {
        self.open = line
        self.close = nil
    }

    public init(block open: String, _ close: String) {
        self.open = open
        self.close = close
    }

    public var isLine: Bool { close == nil }
}

/// 补全里的一条**片段**（插入的是纯文本；`detail` 给人看）。
///
/// 刻意不用带占位符的 snippet 语法：那需要编辑器支持 Tab 跳位，
/// 而我们的编辑器是 `NSTextView` + 自己的补全面板。插入纯文本 + 把光标放在
/// 合理位置（约定见 `CodeCompletion`）已经能省掉大部分重复劳动，且**不会**留下
/// 一堆需要用户手动清理的占位符。
public struct CodeSnippet: Sendable, Equatable {
    public let label: String
    public let insertText: String
    /// 说明文字的**文案键**（Core 不持有中文：展示文本一律走 `LocalizedStrings`，
    /// 这也是 Core 本地化棘轮要求的口径）。
    public let detailKey: LKey

    public init(label: String, insertText: String, detailKey: LKey) {
        self.label = label
        self.insertText = insertText
        self.detailKey = detailKey
    }
}

/// 一个语言的**语法定义**：关键字、内置名、注释与字符串形态、是否区分大小写、常用片段。
///
/// 为什么key字表与补全片段放**同一份**：着色与补全都是"这个词算不算关键字"的消费者。
/// 分成两份的典型症状是——用户看到 `await` 被着成关键字，补全却给不出来（或反过来）。
/// 这也正是 `SQLDialect` 已有的做法（`keywords` / `builtinFunctions` 同时喂高亮与补全）。
///
/// 语言范围（2026-09-24 需求提出者口径）：**先支持前端常见语言**（JS / TS / SQL / HTML / CSS / Python），
/// 之后再加 C / C++ / Java —— 加一个语言只需要在这里补一份 `case`，不必碰词法器。
public struct CodeSyntax: Sendable {
    public let language: TextLanguage
    public let keywords: [String]
    public let builtins: [String]
    public let comments: [CodeCommentStyle]
    public let stringDelimiters: [String]
    public let isCaseInsensitive: Bool
    /// 双写引号是不是"转义一个引号"（SQL 的 `''`；JS / Python 用反斜杠，不是这种）。
    public let usesDoubledQuoteEscape: Bool
    public let snippets: [CodeSnippet]

    /// 归一化后的关键字集合（大小写不敏感的语言统一转小写，见 `normalized(_:)`）。
    public let keywordLookup: Set<String>
    public let builtinLookup: Set<String>

    public init(
        language: TextLanguage,
        keywords: [String],
        builtins: [String] = [],
        comments: [CodeCommentStyle],
        stringDelimiters: [String] = ["\"", "'"],
        isCaseInsensitive: Bool = false,
        usesDoubledQuoteEscape: Bool = false,
        snippets: [CodeSnippet] = []
    ) {
        self.language = language
        self.keywords = keywords
        self.builtins = builtins
        self.comments = comments
        self.stringDelimiters = stringDelimiters
        self.isCaseInsensitive = isCaseInsensitive
        self.usesDoubledQuoteEscape = usesDoubledQuoteEscape
        self.snippets = snippets
        self.keywordLookup = Set(keywords.map { Self.normalized($0, caseInsensitive: isCaseInsensitive) })
        self.builtinLookup = Set(builtins.map { Self.normalized($0, caseInsensitive: isCaseInsensitive) })
    }

    /// 查表用的归一化：不区分大小写的语言（SQL / HTML / CSS）统一小写。
    public static func normalized(_ word: String, caseInsensitive: Bool) -> String {
        caseInsensitive ? word.lowercased() : word
    }

    public func normalized(_ word: String) -> String {
        Self.normalized(word, caseInsensitive: isCaseInsensitive)
    }

    public func isKeyword(_ word: String) -> Bool { keywordLookup.contains(normalized(word)) }
    public func isBuiltin(_ word: String) -> Bool { builtinLookup.contains(normalized(word)) }

    /// 取某个语言的语法定义。**新增语言只改这一处。**
    public static func of(_ language: TextLanguage) -> CodeSyntax {
        switch language {
        case .javascript: return .javascript
        case .typescript: return .typescript
        case .sql: return .sql
        case .html: return .html
        case .css: return .css
        case .json: return .json
        case .python: return .python
        case .shell: return .shell
        case .yaml: return .yaml
        case .markdown: return .markdown
        case .plainText: return .plainText
        }
    }
}

// MARK: - 各语言的表

private extension CodeSyntax {

    static let slashComments = [CodeCommentStyle(line: "//"), CodeCommentStyle(block: "/*", "*/")]

    static let javascript = CodeSyntax(
        language: .javascript,
        keywords: [
            "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case",
            "default", "break", "continue", "class", "extends", "super", "new", "this", "typeof", "instanceof",
            "in", "of", "delete", "void", "yield", "async", "await", "try", "catch", "finally", "throw",
            "import", "export", "from", "as", "static", "get", "set", "true", "false", "null", "undefined",
            "NaN", "Infinity"
        ],
        builtins: [
            "console", "log", "window", "document", "JSON", "Object", "Array", "String", "Number", "Boolean",
            "Math", "Date", "Promise", "Map", "Set", "Symbol", "Error", "RegExp", "parseInt", "parseFloat",
            "setTimeout", "setInterval", "fetch", "require", "module", "exports"
        ],
        comments: slashComments,
        stringDelimiters: ["\"", "'", "`"],
        snippets: [
            CodeSnippet(label: "log", insertText: "console.log()", detailKey: .codeDetailLog),
            CodeSnippet(label: "func", insertText: "function name() {\n  \n}", detailKey: .codeDetailFunction),
            CodeSnippet(label: "arrow", insertText: "const name = () => {\n  \n}", detailKey: .codeDetailArrow),
            CodeSnippet(label: "forof", insertText: "for (const item of items) {\n  \n}", detailKey: .codeDetailLoop),
            CodeSnippet(label: "try", insertText: "try {\n  \n} catch (error) {\n  console.error(error)\n}", detailKey: .codeDetailException),
            CodeSnippet(label: "import", insertText: "import {  } from \"\"", detailKey: .codeDetailImport),
            CodeSnippet(label: "fetch", insertText: "const response = await fetch(url)", detailKey: .codeDetailRequest)
        ]
    )

    static let typescript = CodeSyntax(
        language: .typescript,
        keywords: javascript.keywords + [
            "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "declare",
            "namespace", "abstract", "keyof", "infer", "never", "unknown", "any", "string", "number", "boolean",
            "object", "symbol", "bigint", "satisfies", "override", "is", "asserts"
        ],
        builtins: javascript.builtins + ["Partial", "Required", "Readonly", "Record", "Pick", "Omit", "Promise"],
        comments: slashComments,
        stringDelimiters: ["\"", "'", "`"],
        snippets: javascript.snippets + [
            CodeSnippet(label: "interface", insertText: "interface Name {\n  \n}", detailKey: .codeDetailType),
            CodeSnippet(label: "type", insertText: "type Name = {\n  \n}", detailKey: .codeDetailType)
        ]
    )

    /// SQL 的关键字与内置函数**直接取自方言**（`PostgresDialect`）——
    /// 与编辑器高亮、补全用的是同一份定义。方言侧已冻结（见 SRS v3.180），这里只**读**它。
    static var sql: CodeSyntax {
        let dialect = PostgresDialect()
        return CodeSyntax(
            language: .sql,
            keywords: dialect.keywords,
            builtins: dialect.builtinFunctions,
            comments: [CodeCommentStyle(line: "--"), CodeCommentStyle(block: "/*", "*/")],
            stringDelimiters: ["'", "\""],
            isCaseInsensitive: true,
            // SQL 的 `'it''s'` 是一个字符串 —— 不认这条就会把它切成两段，后面的括号 / 关键字跟着错位。
            usesDoubledQuoteEscape: true,
            snippets: [
                CodeSnippet(label: "select", insertText: "SELECT * FROM ", detailKey: .codeDetailQuery),
                CodeSnippet(label: "selectwhere", insertText: "SELECT *\nFROM table_name\nWHERE condition", detailKey: .codeDetailQuery),
                CodeSnippet(label: "insert", insertText: "INSERT INTO table_name (columns)\nVALUES (values)", detailKey: .codeDetailInsert),
                CodeSnippet(label: "update", insertText: "UPDATE table_name\nSET column = value\nWHERE condition", detailKey: .codeDetailUpdate),
                CodeSnippet(label: "delete", insertText: "DELETE FROM table_name\nWHERE condition", detailKey: .codeDetailDelete),
                CodeSnippet(label: "create", insertText: "CREATE TABLE table_name (\n  id bigint PRIMARY KEY\n)", detailKey: .codeDetailCreateTable),
                CodeSnippet(label: "join", insertText: "JOIN other ON other.id = table_name.other_id", detailKey: .codeDetailJoin)
            ]
        )
    }

    static let html = CodeSyntax(
        language: .html,
        keywords: [
            "html", "head", "body", "title", "meta", "link", "script", "style", "div", "span", "p", "a", "img",
            "ul", "ol", "li", "table", "thead", "tbody", "tr", "td", "th", "form", "input", "button", "label",
            "select", "option", "textarea", "section", "header", "footer", "nav", "main", "article", "aside",
            "h1", "h2", "h3", "h4", "h5", "h6", "br", "hr", "strong", "em", "code", "pre", "iframe", "canvas",
            "svg", "template", "slot"
        ],
        builtins: [
            "class", "id", "style", "href", "src", "alt", "title", "type", "name", "value", "placeholder",
            "disabled", "checked", "selected", "readonly", "required", "target", "rel", "width", "height",
            "colspan", "rowspan", "for", "action", "method", "charset", "content", "defer", "async", "lang"
        ],
        comments: [CodeCommentStyle(block: "<!--", "-->")],
        stringDelimiters: ["\"", "'"],
        isCaseInsensitive: true,
        snippets: [
            CodeSnippet(label: "html5", insertText: "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n  <meta charset=\"utf-8\">\n  <title></title>\n</head>\n<body>\n  \n</body>\n</html>", detailKey: .codeDetailTemplate),
            CodeSnippet(label: "div", insertText: "<div></div>", detailKey: .codeDetailElement),
            CodeSnippet(label: "a", insertText: "<a href=\"\"></a>", detailKey: .codeDetailLink),
            CodeSnippet(label: "img", insertText: "<img src=\"\" alt=\"\">", detailKey: .codeDetailImage),
            CodeSnippet(label: "input", insertText: "<input type=\"text\" name=\"\">", detailKey: .codeDetailInput),
            CodeSnippet(label: "ul", insertText: "<ul>\n  <li></li>\n</ul>", detailKey: .codeDetailList)
        ]
    )

    static let css = CodeSyntax(
        language: .css,
        keywords: ["@media", "@import", "@keyframes", "@font-face", "@supports", "@charset", "important"],
        builtins: [
            "color", "background", "background-color", "background-image", "display", "flex", "grid", "position",
            "top", "right", "bottom", "left", "width", "height", "min-width", "max-width", "min-height",
            "max-height", "margin", "padding", "border", "border-radius", "font", "font-size", "font-family",
            "font-weight", "line-height", "text-align", "text-decoration", "letter-spacing", "opacity",
            "overflow", "z-index", "transform", "transition", "animation", "box-shadow", "cursor", "gap",
            "align-items", "align-content", "justify-content", "flex-direction", "flex-wrap", "grid-template-columns",
            "grid-template-rows", "visibility", "content", "outline", "filter", "object-fit", "white-space"
        ],
        comments: [CodeCommentStyle(block: "/*", "*/")],
        stringDelimiters: ["\"", "'"],
        isCaseInsensitive: true,
        snippets: [
            CodeSnippet(label: "flex", insertText: "display: flex;\nalign-items: center;\njustify-content: center;", detailKey: .codeDetailLayout),
            CodeSnippet(label: "grid", insertText: "display: grid;\ngrid-template-columns: repeat(3, 1fr);\ngap: 8px;", detailKey: .codeDetailLayout),
            CodeSnippet(label: "center", insertText: "position: absolute;\ntop: 50%;\nleft: 50%;\ntransform: translate(-50%, -50%);", detailKey: .codeDetailCenter),
            CodeSnippet(label: "media", insertText: "@media (max-width: 768px) {\n  \n}", detailKey: .codeDetailMedia)
        ]
    )

    static let json = CodeSyntax(
        language: .json,
        keywords: ["true", "false", "null"],
        comments: [CodeCommentStyle(line: "//"), CodeCommentStyle(block: "/*", "*/")],
        stringDelimiters: ["\""],
        snippets: [
            CodeSnippet(label: "object", insertText: "{\n  \"key\": \"value\"\n}", detailKey: .codeDetailObject),
            CodeSnippet(label: "array", insertText: "[\n  \n]", detailKey: .codeDetailArray)
        ]
    )

    static let python = CodeSyntax(
        language: .python,
        keywords: [
            "def", "class", "return", "if", "elif", "else", "for", "while", "break", "continue", "pass",
            "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "global",
            "nonlocal", "assert", "yield", "async", "await", "del", "in", "is", "not", "and", "or",
            "None", "True", "False", "self", "match", "case"
        ],
        builtins: [
            "print", "len", "range", "str", "int", "float", "bool", "list", "dict", "set", "tuple", "sum",
            "min", "max", "sorted", "enumerate", "zip", "open", "isinstance", "type", "super", "format",
            "abs", "round", "any", "all", "map", "filter"
        ],
        comments: [CodeCommentStyle(line: "#")],
        stringDelimiters: ["\"", "'"],
        snippets: [
            CodeSnippet(label: "def", insertText: "def name():\n    ", detailKey: .codeDetailFunction),
            CodeSnippet(label: "class", insertText: "class Name:\n    def __init__(self):\n        ", detailKey: .codeDetailClass),
            CodeSnippet(label: "main", insertText: "if __name__ == \"__main__\":\n    ", detailKey: .codeDetailEntry),
            CodeSnippet(label: "for", insertText: "for item in items:\n    ", detailKey: .codeDetailLoop),
            CodeSnippet(label: "try", insertText: "try:\n    \nexcept Exception as error:\n    print(error)", detailKey: .codeDetailException)
        ]
    )

    static let shell = CodeSyntax(
        language: .shell,
        keywords: [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
            "function", "return", "export", "local", "readonly", "source", "echo", "exit", "set", "unset"
        ],
        builtins: ["grep", "sed", "awk", "cat", "ls", "cd", "mkdir", "rm", "cp", "mv", "chmod", "curl", "git"],
        comments: [CodeCommentStyle(line: "#")],
        stringDelimiters: ["\"", "'"],
        snippets: [
            CodeSnippet(label: "if", insertText: "if [ condition ]; then\n  \nfi", detailKey: .codeDetailCondition),
            CodeSnippet(label: "for", insertText: "for item in items; do\n  \ndone", detailKey: .codeDetailLoop),
            CodeSnippet(label: "func", insertText: "name() {\n  \n}", detailKey: .codeDetailFunction)
        ]
    )

    static let yaml = CodeSyntax(
        language: .yaml,
        keywords: ["true", "false", "null", "yes", "no"],
        comments: [CodeCommentStyle(line: "#")],
        stringDelimiters: ["\"", "'"],
        snippets: [
            CodeSnippet(label: "map", insertText: "key: value", detailKey: .codeDetailMap),
            CodeSnippet(label: "list", insertText: "- item", detailKey: .codeDetailListItem)
        ]
    )

    /// Markdown 的**插入模板刻意用 ASCII 占位**（`## Heading` / `[text](url)`）：
    /// 插入的是**文档内容**，不该预设用户用什么语言写文档；而这一条说明文字（右侧 detail）
    /// 仍走文案表、按界面语言显示。这样也不会让"Core 里出现中文内容字面量"这种账目蒙混过关。
    static let markdown = CodeSyntax(
        language: .markdown,
        keywords: [],
        comments: [],
        stringDelimiters: ["`"],
        snippets: [
            CodeSnippet(label: "h2", insertText: "## Heading", detailKey: .codeDetailHeading),
            CodeSnippet(label: "code", insertText: "```\n\n```", detailKey: .codeDetailCodeBlock),
            CodeSnippet(label: "link", insertText: "[text](url)", detailKey: .codeDetailLink),
            CodeSnippet(label: "table", insertText: "| col | col |\n|---|---|\n|  |  |", detailKey: .codeDetailTable)
        ]
    )

    static let plainText = CodeSyntax(
        language: .plainText,
        keywords: [],
        comments: [],
        stringDelimiters: []
    )
}
