import Foundation

/// SQL 词法单元，用于编辑器着色。
public struct SQLToken: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case keyword
        case function
        case string
        case quotedIdentifier
        case comment
        case number
        case operatorSymbol
    }

    public var kind: Kind
    /// 相对于整个 SQL 文本的 UTF-16 范围（与 NSTextStorage 一致）。
    public var range: NSRange

    public init(kind: Kind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

/// 只读词法扫描器：把 SQL 拆成可着色的 token。
///
/// 与 `StatementSplitter` 一样，扫描过程不改写任何字符；
/// 未闭合的字符串 / 注释会被宽容地延伸到文本末尾，避免编辑器闪烁。
public struct SQLTokenizer: Sendable {
    public let databaseType: DatabaseType
    /// 大写形式的关键字。
    public let keywords: Set<String>
    /// 小写形式的函数名。
    public let functions: Set<String>

    public init(databaseType: DatabaseType, keywords: [String], functions: [String]) {
        self.databaseType = databaseType
        self.keywords = Set(keywords.map { $0.uppercased() })
        self.functions = Set(functions.map { $0.lowercased() })
    }

    public static func standard(_ databaseType: DatabaseType) -> SQLTokenizer {
        let dialect: any SQLDialect = databaseType == .postgresql ? PostgresDialect() : GBaseDialect()
        return SQLTokenizer(
            databaseType: databaseType,
            keywords: dialect.keywords,
            functions: dialect.builtinFunctions
        )
    }

    public func tokenize(_ sql: String) -> [SQLToken] {
        let units = Array(sql.utf16)
        var tokens: [SQLToken] = []
        var index = 0

        while index < units.count {
            let unit = units[index]

            // 空白
            if isWhitespace(unit) {
                index += 1
                continue
            }

            // -- 行注释
            if unit == 0x2D, index + 1 < units.count, units[index + 1] == 0x2D {
                var end = index + 2
                while end < units.count && units[end] != 0x0A {
                    end += 1
                }
                tokens.append(SQLToken(kind: .comment, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // /* */ 块注释（支持嵌套）
            if unit == 0x2F, index + 1 < units.count, units[index + 1] == 0x2A {
                var end = index + 2
                var depth = 1
                while end < units.count && depth > 0 {
                    if end + 1 < units.count, units[end] == 0x2F, units[end + 1] == 0x2A {
                        depth += 1
                        end += 2
                        continue
                    }
                    if end + 1 < units.count, units[end] == 0x2A, units[end + 1] == 0x2F {
                        depth -= 1
                        end += 2
                        continue
                    }
                    end += 1
                }
                tokens.append(SQLToken(kind: .comment, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // # 行注释（GBase）
            if databaseType == .gbase8a, unit == 0x23 {
                var end = index + 1
                while end < units.count && units[end] != 0x0A {
                    end += 1
                }
                tokens.append(SQLToken(kind: .comment, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // 单引号字符串
            if unit == 0x27 {
                var end = index + 1
                var escaped = false
                while end < units.count {
                    let current = units[end]
                    if escaped {
                        escaped = false
                        end += 1
                        continue
                    }
                    if current == 0x5C {
                        escaped = true
                        end += 1
                        continue
                    }
                    if current == 0x27 {
                        if end + 1 < units.count && units[end + 1] == 0x27 {
                            end += 2
                            continue
                        }
                        end += 1
                        break
                    }
                    end += 1
                }
                tokens.append(SQLToken(kind: .string, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // 双引号标识符
            if unit == 0x22 {
                var end = index + 1
                while end < units.count {
                    if units[end] == 0x22 {
                        if end + 1 < units.count && units[end + 1] == 0x22 {
                            end += 2
                            continue
                        }
                        end += 1
                        break
                    }
                    end += 1
                }
                tokens.append(SQLToken(kind: .quotedIdentifier, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // PostgreSQL dollar-quoted 字符串
            if databaseType == .postgresql, unit == 0x24, let tag = dollarQuoteTag(units: units, at: index) {
                let tagLength = tag.count
                var end = index + tagLength
                var closed = false
                while end + tagLength <= units.count {
                    if Array(units[end..<end + tagLength]) == Array(tag) {
                        end += tagLength
                        closed = true
                        break
                    }
                    end += 1
                }
                _ = closed
                tokens.append(SQLToken(kind: .string, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // 数字
            if isDigit(unit) {
                var end = index + 1
                while end < units.count {
                    let current = units[end]
                    if isDigit(current) || current == 0x2E {
                        end += 1
                        continue
                    }
                    if (current == 0x65 || current == 0x45), end + 1 < units.count {
                        let sign = units[end + 1]
                        if isDigit(sign) || sign == 0x2B || sign == 0x2D {
                            end += 2
                            while end < units.count && isDigit(units[end]) {
                                end += 1
                            }
                            continue
                        }
                    }
                    break
                }
                tokens.append(SQLToken(kind: .number, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            // 标识符 / 关键字 / 函数
            if isIdentifierStart(unit) {
                var end = index + 1
                while end < units.count && isIdentifierPart(units[end]) {
                    end += 1
                }
                let word = String(decoding: units[index..<end], as: UTF16.self)
                let upper = word.uppercased()
                let lower = word.lowercased()

                if keywords.contains(upper) {
                    tokens.append(SQLToken(kind: .keyword, range: NSRange(location: index, length: end - index)))
                } else if functions.contains(lower) {
                    tokens.append(SQLToken(kind: .function, range: NSRange(location: index, length: end - index)))
                }
                index = end
                continue
            }

            // 其余运算符 / 标点：不单独着色，直接跳过
            tokens.append(SQLToken(kind: .operatorSymbol, range: NSRange(location: index, length: 1)))
            index += 1
        }

        return tokens
    }

    private func dollarQuoteTag(units: [UInt16], at index: Int) -> [UInt16]? {
        var cursor = index + 1
        var tag: [UInt16] = [0x24]

        while cursor < units.count, units[cursor] != 0x24 {
            let unit = units[cursor]
            guard isIdentifierPart(unit) else { return nil }
            tag.append(unit)
            cursor += 1
        }

        guard cursor < units.count, units[cursor] == 0x24 else { return nil }
        tag.append(0x24)
        return tag
    }

    private func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    private func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    private func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) ||
        (unit >= 0x61 && unit <= 0x7A) ||
        unit == 0x5F ||
        unit >= 0x80
    }

    private func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }
}
