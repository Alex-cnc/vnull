import Foundation

/// 注入 `WHERE` 的结果。
public enum SQLFilterInjection: Equatable, Sendable {
    /// 注入成功，附带新 SQL。
    case injected(String)
    /// 原语句已有顶层 `WHERE`：**不替用户做决定**（合并条件很容易改错语义），交给用户自己并进去。
    case alreadyHasWhere
    /// 不适合注入（多条语句 / 非查询语句 / 含 UNION 等），原因为用户可读文案。
    case unsupported(reason: String)
}

/// 把 `WHERE` 片段安全地插进一条查询（R-21 的「用当前条件重新查询」入口）。
///
/// 为什么不能直接字符串查找 `where`：
/// - `select 'where' as x` 里的 `where` 是字符串；
/// - `-- where` 是注释；
/// - `where` 出现在子查询里（括号内）时，插到外层才是用户想要的位置；
/// - `$$ ... order by ... $$` 里的函数体更不能被当成子句。
/// 所以这里走一遍**轻量词法扫描**（字符串 / 行注释 / 块注释 / 美元引用 / 括号深度），
/// 只在**顶层**判定子句位置。它不校验 SQL 是否合法 —— 目标只是「插对地方 + 拿不准就别插」。
public enum SQLFilterInjector {

    /// 把 `whereClause`（形如 `WHERE a = 1`）插进 `sql`。
    public static func inject(whereClause: String, into sql: String) -> SQLFilterInjection {
        let clause = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clause.isEmpty else { return .unsupported(reason: "条件为空") }

        let scan = Scanner(sql)
        let topLevel = scan.topLevelWords

        // 非查询语句：EXPLAIN / INSERT / UPDATE / DELETE / SET / BEGIN… 注入 WHERE 没有意义。
        // `WITH` 开头可能是 SELECT 也可能是 INSERT，这里按「含顶层 FROM 或 SELECT」放行。
        let firstWord = topLevel.first?.word.uppercased()
        if let firstWord, !["SELECT", "WITH", "TABLE", "VALUES", "("].contains(firstWord) {
            return .unsupported(reason: "只支持在查询语句上注入条件（当前以 \(firstWord) 开头）")
        }

        // 多条语句：编辑器里可以有多条，插错语句比不插更糟。
        if scan.hasMultipleStatements {
            return .unsupported(reason: "编辑器里有多条语句，请先只保留要重新查询的那一条")
        }

        // UNION 两侧都可能有各自的 WHERE，插外层会改变语义。
        if topLevel.contains(where: { ["UNION", "INTERSECT", "EXCEPT"].contains($0.word.uppercased()) }) {
            return .unsupported(reason: "含 UNION / INTERSECT / EXCEPT，无法确定条件该插在哪一侧")
        }

        if topLevel.contains(where: { $0.word.uppercased() == "WHERE" }) {
            return .alreadyHasWhere
        }

        // 插入点：最早的顶层收尾子句之前；都没有就插在语句末尾（分号之前）。
        let trailers: Set<String> = ["ORDER", "GROUP", "LIMIT", "OFFSET", "FETCH", "FOR", "WINDOW"]
        var insertIndex = sql.endIndex
        for token in topLevel where trailers.contains(token.word.uppercased()) {
            if token.range.lowerBound < insertIndex {
                insertIndex = token.range.lowerBound
            }
        }
        if let semicolon = scan.topLevelSemicolon, semicolon < insertIndex {
            insertIndex = semicolon
        }

        var head = String(sql[sql.startIndex..<insertIndex])
        let tail = String(sql[insertIndex...])
        // 去掉 head 末尾空白，避免出现「…FROM t\n\nWHERE」这种两行空行。
        while let last = head.last, last.isWhitespace {
            head.removeLast()
        }
        let joined = head + "\n" + clause + (tail.isEmpty ? "" : "\n" + tail)
        return .injected(joined)
    }

    // MARK: - 轻量词法扫描

    /// 只做一件事：找出**顶层**（括号外、非字符串 / 非注释 / 非美元引用）的单词与分号位置。
    private struct Scanner {
        struct Token {
            var word: String
            var range: Range<String.Index>
        }

        private(set) var topLevelWords: [Token] = []
        private(set) var topLevelSemicolon: String.Index?
        private(set) var hasMultipleStatements = false

        init(_ sql: String) {
            var index = sql.startIndex
            var depth = 0
            var statementEnded = false

            func isWordCharacter(_ character: Character) -> Bool {
                character.isLetter || character.isNumber || character == "_" || character == "$"
            }

            while index < sql.endIndex {
                let character = sql[index]

                // 空白
                if character.isWhitespace {
                    index = sql.index(after: index)
                    continue
                }

                // 行注释
                if character == "-", sql.index(after: index) < sql.endIndex, sql[sql.index(after: index)] == "-" {
                    while index < sql.endIndex, sql[index] != "\n" {
                        index = sql.index(after: index)
                    }
                    continue
                }

                // 块注释（PostgreSQL 支持嵌套，按深度处理）
                if character == "/", sql.index(after: index) < sql.endIndex, sql[sql.index(after: index)] == "*" {
                    var commentDepth = 1
                    index = sql.index(index, offsetBy: 2)
                    while index < sql.endIndex, commentDepth > 0 {
                        if sql[index] == "/", sql.index(after: index) < sql.endIndex, sql[sql.index(after: index)] == "*" {
                            commentDepth += 1
                            index = sql.index(index, offsetBy: 2)
                        } else if sql[index] == "*", sql.index(after: index) < sql.endIndex, sql[sql.index(after: index)] == "/" {
                            commentDepth -= 1
                            index = sql.index(index, offsetBy: 2)
                        } else {
                            index = sql.index(after: index)
                        }
                    }
                    continue
                }

                // 单引号字符串（`''` 转义；`E'..\'..'` 的反斜杠转义一并处理）
                if character == "'" {
                    index = sql.index(after: index)
                    while index < sql.endIndex {
                        if sql[index] == "'" {
                            let next = sql.index(after: index)
                            if next < sql.endIndex, sql[next] == "'" {
                                index = sql.index(after: next)
                                continue
                            }
                            index = next
                            break
                        }
                        if sql[index] == "\\" {
                            index = sql.index(after: index)
                            if index < sql.endIndex { index = sql.index(after: index) }
                            continue
                        }
                        index = sql.index(after: index)
                    }
                    continue
                }

                // 双引号标识符（`""` 转义）
                if character == "\"" {
                    index = sql.index(after: index)
                    while index < sql.endIndex {
                        if sql[index] == "\"" {
                            let next = sql.index(after: index)
                            if next < sql.endIndex, sql[next] == "\"" {
                                index = sql.index(after: next)
                                continue
                            }
                            index = next
                            break
                        }
                        index = sql.index(after: index)
                    }
                    continue
                }

                // 美元引用：$$ ... $$ 或 $tag$ ... $tag$
                if character == "$", let tag = Self.dollarTag(sql, at: index) {
                    let close = tag.dropFirst()
                    var search = sql.index(index, offsetBy: tag.count)
                    var closed = false
                    while search < sql.endIndex {
                        if sql[search...].hasPrefix(close) {
                            index = sql.index(search, offsetBy: close.count)
                            closed = true
                            break
                        }
                        search = sql.index(after: search)
                    }
                    if !closed { index = sql.endIndex }
                    continue
                }

                if character == "(" {
                    depth += 1
                    index = sql.index(after: index)
                    continue
                }
                if character == ")" {
                    depth = max(0, depth - 1)
                    index = sql.index(after: index)
                    continue
                }

                if character == ";" {
                    if depth == 0 {
                        if topLevelSemicolon == nil {
                            topLevelSemicolon = index
                            statementEnded = true
                        } else {
                            hasMultipleStatements = true
                        }
                    }
                    index = sql.index(after: index)
                    continue
                }

                if isWordCharacter(character) {
                    let start = index
                    while index < sql.endIndex, isWordCharacter(sql[index]) {
                        index = sql.index(after: index)
                    }
                    // 分号之后还有单词 → 多条语句。
                    if statementEnded {
                        hasMultipleStatements = true
                    }
                    if depth == 0 {
                        topLevelWords.append(Token(word: String(sql[start..<index]), range: start..<index))
                    }
                    continue
                }

                index = sql.index(after: index)
            }
        }

        /// 若 `index` 处是合法的美元引用起始（`$$` / `$tag$`），返回完整标记（含两侧 `$`）。
        static func dollarTag(_ sql: String, at index: String.Index) -> String? {
            var cursor = sql.index(after: index)
            while cursor < sql.endIndex {
                let character = sql[cursor]
                if character == "$" {
                    return String(sql[index...cursor])
                }
                guard character.isLetter || character.isNumber || character == "_" else { return nil }
                cursor = sql.index(after: cursor)
            }
            return nil
        }
    }
}
