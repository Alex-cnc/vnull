import Foundation

/// 工作区里「这是什么语言的文本」的判定（FR-EDIT-36）。
///
/// 为什么单独一层：判语言这件事被**三个**地方同时需要 —— 打开文件时决定用什么高亮、
/// 补全时决定给哪套候选、保存时决定用什么缩进 / 注释风格。各写一份迟早不一致
/// （典型症状：`.tsx` 打开是纯文本，但补全却给了 JS 关键字）。
///
/// **语言名刻意用 ASCII**（`JavaScript` / `Python` / `HTML`…）：这些是专有名词，
/// 中文界面里也这么写；放进 `LocalizedStrings` 只会多出一堆同值条目，
/// 而 Core 的展示文本本地化棘轮要的是"该翻译的翻译"，不是"所有字面量都进表"。
public enum TextLanguage: String, CaseIterable, Sendable {
    case sql
    case javascript
    case typescript
    case html
    case css
    case json
    case markdown
    case yaml
    case shell
    case python
    case plainText

    /// 界面上的语言名（ASCII 专有名词，见类型注释）。
    public var displayName: String {
        switch self {
        case .sql: return "SQL"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .yaml: return "YAML"
        case .shell: return "Shell"
        case .python: return "Python"
        case .plainText: return "Plain Text"
        }
    }

    /// 这个语言是否支持**代码编辑**（关键字着色 + 补全）。
    ///
    /// `plainText` / `markdown` 高亮有限、`yaml` 只有少量字面量 —— 但它们都能编辑，
    /// 所以这里不是"能不能打开"，而是"要不要按代码去着色与补全"。
    public var isCode: Bool {
        switch self {
        case .sql, .javascript, .typescript, .html, .css, .json, .python: return true
        case .markdown, .yaml, .shell, .plainText: return false
        }
    }

    /// 扩展名（小写、不含点）。顺序不重要，**一张表只在一个地方**。
    public var fileExtensions: [String] {
        switch self {
        case .sql: return ["sql", "psql", "ddl", "dml"]
        case .javascript: return ["js", "mjs", "cjs", "jsx"]
        case .typescript: return ["ts", "tsx", "mts", "cts"]
        case .html: return ["html", "htm", "xhtml"]
        case .css: return ["css", "scss", "sass", "less"]
        case .json: return ["json", "jsonc", "geojson"]
        case .markdown: return ["md", "markdown", "mdx"]
        case .yaml: return ["yml", "yaml"]
        case .shell: return ["sh", "bash", "zsh", "fish", "command"]
        case .python: return ["py", "pyw", "pyi"]
        case .plainText: return ["txt", "text", "log", "csv", "tsv"]
        }
    }

    /// 没有扩展名但**一眼能认出**的文件名（小写）。
    ///
    /// 只收我们有语言支持的：`Makefile` / `Dockerfile` 之类暂时**如实回落纯文本** ——
    /// 给它们随便安一个语言（比如把 Dockerfile 当 Shell）只会给出错的着色与补全。
    public var fileNames: [String] {
        switch self {
        case .shell: return [".bashrc", ".bash_profile", ".zshrc", ".profile", ".bash_aliases"]
        case .json: return [".eslintrc", ".prettierrc", "package-lock.json"]
        default: return []
        }
    }

    /// 按路径判语言：**文件名优先，其次扩展名**，都不认就纯文本。
    ///
    /// `path` 可以是绝对路径、相对路径或只有一个文件名 —— 只看最后一段。
    public static func detect(path: String) -> TextLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard !name.isEmpty else { return .plainText }

        for language in allCases where language.fileNames.contains(name) {
            return language
        }

        // `a.b.ts` → `ts`；`.gitignore` → `gitignore`（认不出就纯文本，这是对的）
        guard let dot = name.lastIndex(of: "."), dot < name.index(before: name.endIndex) else {
            return .plainText
        }
        let fileExtension = String(name[name.index(after: dot)...])
        for language in allCases where language.fileExtensions.contains(fileExtension) {
            return language
        }
        return .plainText
    }
}
