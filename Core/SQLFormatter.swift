import Foundation

/// 保守的 SQL 格式化器。
///
/// 只做四件事：关键字大写、主要子句换行、括号内按层缩进、空白规整；
/// 不改变任何 token（字符串 / 注释 / 数字 / 标识符原样保留），避免改变语义。
public struct SQLFormatter: Sendable {
    public let databaseType: DatabaseType
    private let tokenizer: SQLTokenizer

    /// 在括号深度为 0 时另起一行的关键字。
    private static let lineStartKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET",
        "UNION", "INSERT", "UPDATE", "DELETE", "VALUES", "SET", "RETURNING",
        "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "FULL", "ON"
    ]

    public init(databaseType: DatabaseType) {
        self.databaseType = databaseType
        self.tokenizer = SQLTokenizer.standard(databaseType)
    }

    public func format(_ sql: String, indentUnit: String = "    ") -> String {
        let tokens = tokenizer.tokenize(sql)
        guard !tokens.isEmpty else {
            return sql.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let ns = sql as NSString
        var output = ""
        var depth = 0
        var needSpace = false
        var lineStart = true
        var afterSemicolon = false
        var previousKind: SQLToken.Kind?
        var cursor = 0

        for token in tokens {
            guard token.range.location + token.range.length <= ns.length else { continue }

            // 词法器只输出「可着色」的 token，普通标识符在间隔里；
            // 这里把间隔中的非空白内容（标识符等）按原样接回来，空白折叠为一个空格。
            if token.range.location > cursor {
                let gapRange = NSRange(location: cursor, length: token.range.location - cursor)
                let gap = ns.substring(with: gapRange)
                let normalized = gap.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !normalized.isEmpty {
                    if needSpace, !lineStart {
                        output += " "
                    }
                    output += normalized
                    needSpace = true
                    lineStart = false
                }
            }
            cursor = NSMaxRange(token.range)

            var text = ns.substring(with: token.range)
            if token.kind == .keyword {
                text = text.uppercased()
            }

            if afterSemicolon {
                output += "\n"
                lineStart = true
                afterSemicolon = false
            }

            switch token.kind {
            case .operatorSymbol:
                switch text {
                case "(":
                    if needSpace, previousKind != .function, previousKind != .operatorSymbol {
                        output += " "
                    }
                    output += "("
                    depth += 1
                    needSpace = false
                    lineStart = false

                case ")":
                    depth = max(0, depth - 1)
                    output += ")"
                    needSpace = true
                    lineStart = false

                case ",":
                    output += ","
                    needSpace = true
                    lineStart = false

                case ".":
                    output += "."
                    needSpace = false
                    lineStart = false

                case ";":
                    output += ";"
                    needSpace = true
                    lineStart = false
                    afterSemicolon = true

                default:
                    if needSpace, !lineStart {
                        output += " "
                    }
                    output += text
                    needSpace = true
                    lineStart = false
                }

            default:
                if lineStart {
                    if !output.isEmpty {
                        output += String(repeating: indentUnit, count: max(depth, 0))
                    }
                    lineStart = false
                } else if token.kind == .keyword,
                          Self.lineStartKeywords.contains(text.uppercased()),
                          depth == 0 {
                    output += "\n"
                    if !output.isEmpty {
                        output += String(repeating: indentUnit, count: max(depth, 0))
                    }
                } else if needSpace {
                    output += " "
                }

                output += text
                needSpace = true
                lineStart = false
            }

            previousKind = token.kind
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
