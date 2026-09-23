import Foundation

/// SQL 的**轻量词法切分**：把语句切成「代码区」与「非代码区」。
///
/// 谁需要它：任何"在 SQL 文本里找东西"的功能 —— 查询参数占位符（FR-EXEC-17）、
/// 条件注入的位置判定（R-21）、事务控制语句识别等。共同点是：
/// **必须跳过字符串、注释、dollar-quote 与带引号的标识符**，否则会把数据当成语法。
///
/// 为什么单独抽出来：这段逻辑一旦写错，后果是"悄悄改掉用户的数据"（例如把 `'a :name b'`
/// 里的 `:name` 替换掉）。抽成一层、单独测，比散在各功能里各写一遍安全得多。
public enum SQLLexer {

    /// 代码区范围（按出现顺序、互不相邻）。非代码区 = 字符串 / 行注释 / 块注释 / dollar-quote / 带引号标识符。
    public static func codeRanges(in sql: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = sql.startIndex
        var segmentStart: String.Index?

        func openSegment(at position: String.Index) {
            if segmentStart == nil { segmentStart = position }
        }
        func closeSegment(before position: String.Index) {
            if let start = segmentStart, start < position {
                ranges.append(start..<position)
            }
            segmentStart = nil
        }

        while index < sql.endIndex {
            let character = sql[index]

            // 行注释：`--` 到行尾
            if character == "-", let next = peek(sql, index, offset: 1), next == "-" {
                closeSegment(before: index)
                while index < sql.endIndex, sql[index] != "\n" { index = sql.index(after: index) }
                continue
            }

            // 块注释：`/* … */`（PostgreSQL 支持嵌套）
            if character == "/", let next = peek(sql, index, offset: 1), next == "*" {
                closeSegment(before: index)
                var depth = 1
                index = sql.index(index, offsetBy: 2)
                while index < sql.endIndex, depth > 0 {
                    if sql[index] == "/", let n = peek(sql, index, offset: 1), n == "*" {
                        depth += 1
                        index = sql.index(index, offsetBy: 2)
                    } else if sql[index] == "*", let n = peek(sql, index, offset: 1), n == "/" {
                        depth -= 1
                        index = sql.index(index, offsetBy: 2)
                    } else {
                        index = sql.index(after: index)
                    }
                }
                continue
            }

            // 单引号字符串（`''` 转义；`E'…\''` 的反斜杠转义一并处理）
            if character == "'" {
                closeSegment(before: index)
                index = skipQuoted(sql, from: index, quote: "'", allowsBackslashEscape: true)
                continue
            }

            // 双引号标识符：**也算非代码** —— `"col:name"` 里的 `:name` 是列名的一部分，不是参数。
            if character == "\"" {
                closeSegment(before: index)
                index = skipQuoted(sql, from: index, quote: "\"", allowsBackslashEscape: false)
                continue
            }

            // dollar-quote：`$$ … $$` / `$tag$ … $tag$`
            if character == "$", let tag = dollarTag(sql, at: index) {
                closeSegment(before: index)
                let closing = String(tag.dropFirst())
                var cursor = sql.index(index, offsetBy: tag.count)
                while cursor < sql.endIndex, !sql[cursor...].hasPrefix(closing) {
                    cursor = sql.index(after: cursor)
                }
                index = cursor < sql.endIndex ? sql.index(cursor, offsetBy: closing.count) : sql.endIndex
                continue
            }

            openSegment(at: index)
            index = sql.index(after: index)
        }

        closeSegment(before: sql.endIndex)
        return ranges
    }

    /// 该位置是否落在代码区（字符串 / 注释里返回 false）。
    public static func isCode(at position: String.Index, in sql: String) -> Bool {
        codeRanges(in: sql).contains { $0.contains(position) }
    }

    // MARK: 内部

    private static func peek(_ sql: String, _ index: String.Index, offset: Int) -> Character? {
        guard let target = sql.index(index, offsetBy: offset, limitedBy: sql.endIndex), target < sql.endIndex else {
            return nil
        }
        return sql[target]
    }

    /// 跳过一段引号包裹的内容，返回结束位置之后的下标（未闭合则到结尾）。
    private static func skipQuoted(
        _ sql: String,
        from index: String.Index,
        quote: Character,
        allowsBackslashEscape: Bool
    ) -> String.Index {
        var cursor = sql.index(after: index)
        while cursor < sql.endIndex {
            if sql[cursor] == quote {
                let next = sql.index(after: cursor)
                // 双写 = 转义，继续往下
                if next < sql.endIndex, sql[next] == quote {
                    cursor = sql.index(after: next)
                    continue
                }
                return next
            }
            // `E'…'` 里的反斜杠转义（PostgreSQL 扩展）
            if allowsBackslashEscape, sql[cursor] == "\\" {
                cursor = sql.index(after: cursor)
                if cursor < sql.endIndex { cursor = sql.index(after: cursor) }
                continue
            }
            cursor = sql.index(after: cursor)
        }
        return sql.endIndex
    }

    /// `$$` / `$tag$` 形式的完整标记；不是 dollar-quote 时返回 nil。
    static func dollarTag(_ sql: String, at index: String.Index) -> String? {
        var cursor = sql.index(after: index)
        while cursor < sql.endIndex {
            let character = sql[cursor]
            if character == "$" { return String(sql[index...cursor]) }
            guard character.isLetter || character.isNumber || character == "_" else { return nil }
            cursor = sql.index(after: cursor)
        }
        return nil
    }
}
