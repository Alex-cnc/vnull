import Foundation

public struct SQLStatement: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sql: String
    public let index: Int

    public init(id: UUID = UUID(), sql: String, index: Int) {
        self.id = id
        self.sql = sql
        self.index = index
    }
}

/// 方言相关的 SQL 语句拆分器。
///
/// PostgreSQL 和 GBase 8a 的拆分规则完全不同：
/// - PostgreSQL 使用 `;` 作为语句分隔符，同时必须跳过 dollar-quoted string；
/// - GBase 8a 支持客户端 `DELIMITER` 指令，存储过程体内可以包含分号。
///
/// 拆分器不做任何 SQL 改写，只保留原文并识别语句边界。
public final class StatementSplitter: Sendable {
    public let databaseType: DatabaseType

    public init(databaseType: DatabaseType) {
        self.databaseType = databaseType
    }

    public func split(_ input: String) -> [SQLStatement] {
        let chars = Array(input)
        var statements: [SQLStatement] = []
        var current = ""
        var index = 0
        var statementIndex = 0
        var delimiter = ";"

        while index < chars.count {
            let character = chars[index]

            // GBase 客户端指令：DELIMITER $ / DELIMITER ;
            if databaseType == .gbase8a &&
                current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                matchesKeyword(chars, at: index, keyword: "DELIMITER") {
                if let result = parseDelimiter(chars, at: index) {
                    delimiter = result.delimiter
                    index = result.nextIndex
                    current = ""
                    continue
                }
            }

            // 行注释 -- ...
            if character == "-" && index + 1 < chars.count && chars[index + 1] == "-" {
                var end = index + 2
                while end < chars.count && chars[end] != "\n" {
                    end += 1
                }
                current.append(contentsOf: chars[index..<end])
                index = end
                continue
            }

            // GBase/MySQL 风格行注释 # ...
            if databaseType == .gbase8a && character == "#" {
                var end = index + 1
                while end < chars.count && chars[end] != "\n" {
                    end += 1
                }
                current.append(contentsOf: chars[index..<end])
                index = end
                continue
            }

            // 块注释 /* ... */，支持嵌套
            if character == "/" && index + 1 < chars.count && chars[index + 1] == "*" {
                var end = index + 2
                var depth = 1
                while end < chars.count && depth > 0 {
                    if end + 1 < chars.count && chars[end] == "/" && chars[end + 1] == "*" {
                        depth += 1
                        end += 2
                        continue
                    }
                    if end + 1 < chars.count && chars[end] == "*" && chars[end + 1] == "/" {
                        depth -= 1
                        end += 2
                        continue
                    }
                    end += 1
                }
                current.append(contentsOf: chars[index..<end])
                index = end
                continue
            }

            // 单引号字符串：处理 '' 与反斜杠转义
            if character == "'" {
                var end = index + 1
                var escaped = false
                while end < chars.count {
                    let currentChar = chars[end]
                    if escaped {
                        escaped = false
                        end += 1
                        continue
                    }
                    if currentChar == "\\" {
                        escaped = true
                        end += 1
                        continue
                    }
                    if currentChar == "'" {
                        if end + 1 < chars.count && chars[end + 1] == "'" {
                            end += 2
                            continue
                        }
                        end += 1
                        break
                    }
                    end += 1
                }
                current.append(contentsOf: chars[index..<end])
                index = end
                continue
            }

            // 双引号标识符
            if character == "\"" {
                var end = index + 1
                while end < chars.count {
                    if chars[end] == "\"" {
                        if end + 1 < chars.count && chars[end + 1] == "\"" {
                            end += 2
                            continue
                        }
                        end += 1
                        break
                    }
                    end += 1
                }
                current.append(contentsOf: chars[index..<end])
                index = end
                continue
            }

            // PostgreSQL dollar-quoted string：$$...$$ 或 $tag$...$tag$
            if databaseType == .postgresql && character == "$" {
                if let end = dollarQuoteEnd(chars, at: index) {
                    current.append(contentsOf: chars[index..<end])
                    index = end
                    continue
                }
            }

            // 当前分隔符匹配：结束一条语句
            if matchesDelimiter(chars, at: index, delimiter: delimiter) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    statements.append(SQLStatement(sql: current, index: statementIndex))
                    statementIndex += 1
                }
                current = ""
                index += delimiter.count
                continue
            }

            current.append(character)
            index += 1
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            statements.append(SQLStatement(sql: current, index: statementIndex))
        }

        return statements
    }

    private func matchesKeyword(_ chars: [Character], at index: Int, keyword: String) -> Bool {
        let keywordChars = Array(keyword)
        guard index + keywordChars.count <= chars.count else { return false }
        let candidate = String(chars[index..<index + keywordChars.count]).uppercased()
        guard candidate == keyword.uppercased() else { return false }

        let next = index + keywordChars.count
        if next < chars.count {
            return chars[next].isWhitespace
        }
        return true
    }

    private func matchesDelimiter(_ chars: [Character], at index: Int, delimiter: String) -> Bool {
        let delimiterChars = Array(delimiter)
        guard index + delimiterChars.count <= chars.count else { return false }
        for offset in 0..<delimiterChars.count {
            if chars[index + offset] != delimiterChars[offset] {
                return false
            }
        }
        return true
    }

    private func parseDelimiter(_ chars: [Character], at index: Int) -> (delimiter: String, nextIndex: Int)? {
        var cursor = index + "DELIMITER".count

        while cursor < chars.count && (chars[cursor] == " " || chars[cursor] == "\t") {
            cursor += 1
        }

        var token = ""
        while cursor < chars.count &&
            chars[cursor] != "\n" &&
            chars[cursor] != "\r" &&
            chars[cursor] != " " &&
            chars[cursor] != "\t" {
            token.append(chars[cursor])
            cursor += 1
        }

        while cursor < chars.count && chars[cursor] != "\n" && chars[cursor] != "\r" {
            cursor += 1
        }
        if cursor < chars.count {
            cursor += 1
        }
        if cursor < chars.count && chars[cursor - 1] == "\r" && chars[cursor] == "\n" {
            cursor += 1
        }

        guard !token.isEmpty else { return nil }
        return (token, cursor)
    }

    private func dollarQuoteEnd(_ chars: [Character], at index: Int) -> Int? {
        var cursor = index + 1
        var tag = "$"

        while cursor < chars.count && chars[cursor] != "$" {
            let character = chars[cursor]
            if character.isLetter || character.isNumber || character == "_" {
                tag.append(character)
                cursor += 1
            } else {
                return nil
            }
        }

        guard cursor < chars.count && chars[cursor] == "$" else { return nil }
        tag.append("$")

        var search = cursor + 1
        let tagChars = Array(tag)
        while search + tagChars.count <= chars.count {
            if Array(chars[search..<search + tagChars.count]) == tagChars {
                return search + tagChars.count
            }
            search += 1
        }

        return nil
    }
}
