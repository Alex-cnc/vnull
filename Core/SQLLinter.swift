import Foundation

/// SQL 语法检查结果（客户端静态检查，不连接数据库）。
public struct SQLDiagnostic: Identifiable, Hashable, Sendable {
    public enum Severity: String, Codable, Hashable, Sendable {
        case error
        case warning
    }

    public let id: UUID
    public var severity: Severity
    public var message: String
    /// 1-based 行号。
    public var line: Int
    /// 1-based 列号。
    public var column: Int
    /// 用于编辑器下划线的 UTF-16 位置与长度。
    public var utf16Location: Int
    public var utf16Length: Int

    public init(
        id: UUID = UUID(),
        severity: Severity,
        message: String,
        line: Int,
        column: Int,
        utf16Location: Int,
        utf16Length: Int
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.line = line
        self.column = column
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
    }

    public var locationDescription: String {
        "第 \(line) 行第 \(column) 列"
    }
}

/// SQL 静态检查器。
///
/// 只做词法层面的检查（不解析语法树）：
/// - 字符串 / 双引号标识符 / 块注释 / PostgreSQL dollar-quoted 是否闭合
/// - 括号是否配对
///
/// 这样可以在执行前就给出确定的错误，且不会对合法 SQL 产生误报。
public struct SQLLinter: Sendable {
    public let databaseType: DatabaseType
    /// 诊断文案语言（默认中文，便于 Core 单测与 CLI 使用）。
    public let language: AppLanguage

    public init(databaseType: DatabaseType, language: AppLanguage = .simplifiedChinese) {
        self.databaseType = databaseType
        self.language = language
    }

    public func analyze(_ sql: String) -> [SQLDiagnostic] {
        let chars = Array(sql)
        guard !chars.isEmpty else { return [] }

        var utf16Offsets = [Int](repeating: 0, count: chars.count + 1)
        var offset = 0
        for (index, character) in chars.enumerated() {
            utf16Offsets[index] = offset
            offset += String(character).utf16.count
        }
        utf16Offsets[chars.count] = offset

        var diagnostics: [SQLDiagnostic] = []
        var parenStack: [Int] = []
        var index = 0

        func location(_ charIndex: Int, length: Int = 1) -> (Int, Int, Int, Int) {
            let bounded = min(max(charIndex, 0), chars.count)
            let (line, column) = lineColumn(at: bounded, chars: chars)
            let location = utf16Offsets[bounded]
            let endIndex = min(bounded + max(length, 1), chars.count)
            return (line, column, location, utf16Offsets[endIndex] - location)
        }

        func append(_ severity: SQLDiagnostic.Severity, _ message: String, _ charIndex: Int, length: Int = 1) {
            guard diagnostics.count < 20 else { return }
            let (line, column, location, utf16Length) = location(charIndex, length: length)
            diagnostics.append(
                SQLDiagnostic(
                    severity: severity,
                    message: message,
                    line: line,
                    column: column,
                    utf16Location: location,
                    utf16Length: max(utf16Length, 1)
                )
            )
        }

        while index < chars.count {
            let character = chars[index]

            // -- 行注释
            if character == "-" && index + 1 < chars.count && chars[index + 1] == "-" {
                while index < chars.count && chars[index] != "\n" {
                    index += 1
                }
                continue
            }

            // # 行注释（GBase / MySQL）
            if databaseType == .gbase8a && character == "#" {
                while index < chars.count && chars[index] != "\n" {
                    index += 1
                }
                continue
            }

            // /* */ 块注释（支持嵌套）
            if character == "/" && index + 1 < chars.count && chars[index + 1] == "*" {
                let start = index
                var cursor = index + 2
                var depth = 1
                while cursor < chars.count && depth > 0 {
                    if cursor + 1 < chars.count && chars[cursor] == "/" && chars[cursor + 1] == "*" {
                        depth += 1
                        cursor += 2
                        continue
                    }
                    if cursor + 1 < chars.count && chars[cursor] == "*" && chars[cursor + 1] == "/" {
                        depth -= 1
                        cursor += 2
                        continue
                    }
                    cursor += 1
                }

                if depth > 0 {
                    append(.error, LocalizedStrings.text(.lintBlockComment, language: language), start, length: 2)
                }
                index = cursor
                continue
            }

            // 单引号字符串
            if character == "'" {
                let start = index
                var cursor = index + 1
                var escaped = false
                var closed = false

                while cursor < chars.count {
                    let current = chars[cursor]
                    if escaped {
                        escaped = false
                        cursor += 1
                        continue
                    }
                    if current == "\\" {
                        escaped = true
                        cursor += 1
                        continue
                    }
                    if current == "'" {
                        if cursor + 1 < chars.count && chars[cursor + 1] == "'" {
                            cursor += 2
                            continue
                        }
                        cursor += 1
                        closed = true
                        break
                    }
                    cursor += 1
                }

                if !closed {
                    append(.error, LocalizedStrings.text(.lintString, language: language), start, length: cursor - start)
                }
                index = cursor
                continue
            }

            // 双引号标识符
            if character == "\"" {
                let start = index
                var cursor = index + 1
                var closed = false

                while cursor < chars.count {
                    if chars[cursor] == "\"" {
                        if cursor + 1 < chars.count && chars[cursor + 1] == "\"" {
                            cursor += 2
                            continue
                        }
                        cursor += 1
                        closed = true
                        break
                    }
                    cursor += 1
                }

                if !closed {
                    append(.error, LocalizedStrings.text(.lintQuotedIdentifier, language: language), start, length: cursor - start)
                }
                index = cursor
                continue
            }

            // PostgreSQL dollar-quoted 字符串
            if databaseType == .postgresql && character == "$" {
                if let tag = dollarQuoteTag(chars: chars, at: index) {
                    let start = index
                    var cursor = index + tag.count
                    var closed = false
                    while cursor + tag.count <= chars.count {
                        if Array(chars[cursor..<cursor + tag.count]) == Array(tag) {
                            cursor += tag.count
                            closed = true
                            break
                        }
                        cursor += 1
                    }

                    if !closed {
                        append(.error, LocalizedStrings.format(.lintDollarQuote, language: language, tag), start, length: cursor - start)
                    }
                    index = cursor
                    continue
                }
            }

            // 括号配对
            if character == "(" {
                parenStack.append(index)
                index += 1
                continue
            }

            if character == ")" {
                if parenStack.isEmpty {
                    append(.error, LocalizedStrings.text(.lintExtraCloseParen, language: language), index)
                } else {
                    parenStack.removeLast()
                }
                index += 1
                continue
            }

            index += 1
        }

        for opener in parenStack.prefix(5) {
            append(.error, LocalizedStrings.text(.lintMissingCloseParen, language: language), opener)
        }

        return diagnostics.sorted { $0.utf16Location < $1.utf16Location }
    }

    /// 如果 `$...$` 是一个合法的 dollar-quote 开头，返回完整 tag（含两侧的 $）。
    private func dollarQuoteTag(chars: [Character], at index: Int) -> String? {
        var cursor = index + 1
        var tag = "$"

        while cursor < chars.count && chars[cursor] != "$" {
            let character = chars[cursor]
            guard character.isLetter || character.isNumber || character == "_" else { return nil }
            tag.append(character)
            cursor += 1
        }

        guard cursor < chars.count && chars[cursor] == "$" else { return nil }
        tag.append("$")
        return tag
    }

    private func lineColumn(at charIndex: Int, chars: [Character]) -> (Int, Int) {
        var line = 1
        var column = 1
        for index in 0..<min(charIndex, chars.count) {
            if chars[index] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return (line, column)
    }
}
