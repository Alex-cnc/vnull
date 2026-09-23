import Foundation

/// 按条件浏览 / 统计行数（FR-DATA-02）。
///
/// 与「客户端筛选」（FR-RES-09）的区别必须一句话讲清：**这里的条件是在服务端执行的**
/// —— 用户填 `WHERE` / `ORDER BY`，我们把它拼进 `SELECT` 发给数据库。
///
/// 因此有两条纪律：
/// 1. **片段原样下发**（这是使用者在自己的库上写 SQL，不做"聪明"的改写）；
/// 2. **但拒绝多语句**：`WHERE a = 1; DROP TABLE t` 这种输入不能因为一个"浏览"按钮被执行，
///    一个 `;` 就足以说明对方放错了地方 —— 此时拒绝并说清楚，比"尽力执行"安全得多。
public enum RowBrowsingQuery {

    /// 浏览条件。`whereClause` / `orderBy` 是**用户写的 SQL 片段**（可带也可不带关键字）。
    public struct Filter: Equatable, Sendable {
        public var whereClause: String
        public var orderBy: String
        public var limit: Int
        public var offset: Int

        public init(
            whereClause: String = "",
            orderBy: String = "",
            limit: Int = ObjectTreeActions.defaultBrowseLimit,
            offset: Int = 0
        ) {
            self.whereClause = whereClause
            self.orderBy = orderBy
            self.limit = limit
            self.offset = offset
        }

        /// 规范化后的条件（供预览与生成共用，**同一份输入只解析一次**）。
        public func normalized() -> Result<(where: String, orderBy: String), BuildError> {
            switch RowBrowsingQuery.split(whereClause: whereClause, orderBy: orderBy) {
            case .failure(let error): return .failure(error)
            case .success(let clauses): return .success(clauses)
            }
        }
    }

    /// 生成失败的原因。`Error` 是 `Result` 的要求，具体文案由界面层映射（Core 不硬编码语言）。
    public enum BuildError: Error, Equatable, Sendable {
        /// 片段里有多条语句（含分号）—— 拒绝执行，并要求把条件写成单条表达式。
        case multipleStatements
        /// `WHERE` 框里既写了 `ORDER BY`，又在 `ORDER BY` 框里写了一份：无法判断以哪个为准。
        case ambiguousOrderBy

        /// 给界面用的技术标识（本地化在界面层）。
        public var identifier: String {
            switch self {
            case .multipleStatements: return "multipleStatements"
            case .ambiguousOrderBy: return "ambiguousOrderBy"
            }
        }
    }

    /// 生成浏览语句：`SELECT * FROM <表> [WHERE …] [ORDER BY …] LIMIT … OFFSET …;`
    ///
    /// 顺序固定为 WHERE → ORDER BY → 分页：分页必须在最后，否则 `LIMIT` 之后的条件会被语法拒绝。
    public static func browse(
        table: String,
        schema: String? = nil,
        filter: Filter,
        dialect: any SQLDialect
    ) -> Result<String, BuildError> {
        switch filter.normalized() {
        case .failure(let error):
            return .failure(error)
        case .success(let clauses):
            var sql = "SELECT * FROM "
            sql += SQLGenerator.qualifiedName(table: table, schema: schema, dialect: dialect)
            if !clauses.where.isEmpty {
                sql += " WHERE \(clauses.where)"
            }
            if !clauses.orderBy.isEmpty {
                sql += " ORDER BY \(clauses.orderBy)"
            }
            // 分页用方言（GBase 是 `LIMIT offset, count`），放最后。
            sql += " " + dialect.limitClause(offset: max(0, filter.offset), count: max(0, filter.limit))
            return .success(sql + ";")
        }
    }

    /// 生成计数语句：`SELECT count(*) FROM <表> [WHERE …];`
    ///
    /// 计数**不带 ORDER BY**：它对结果没有影响，带上只会让数据库白排序一遍。
    public static func count(
        table: String,
        schema: String? = nil,
        filter: Filter,
        dialect: any SQLDialect
    ) -> Result<String, BuildError> {
        switch filter.normalized() {
        case .failure(let error):
            return .failure(error)
        case .success(let clauses):
            var sql = "SELECT count(*) FROM "
            sql += SQLGenerator.qualifiedName(table: table, schema: schema, dialect: dialect)
            if !clauses.where.isEmpty {
                sql += " WHERE \(clauses.where)"
            }
            return .success(sql + ";")
        }
    }

    /// 条件片段的规范化与拆分。
    static func split(
        whereClause: String,
        orderBy: String
    ) -> Result<(where: String, orderBy: String), BuildError> {
        guard var rawWhere = sanitize(whereClause) else { return .failure(.multipleStatements) }
        guard var rawOrder = sanitize(orderBy) else { return .failure(.multipleStatements) }

        // 用户在 WHERE 框里写了 ORDER BY：条件框只有一个，就顺手拆开（并只在他没另填时这么做）。
        if let range = topLevelOrderByRange(in: rawWhere) {
            guard rawOrder.isEmpty else { return .failure(.ambiguousOrderBy) }
            rawOrder = String(rawWhere[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            rawWhere = String(rawWhere[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return .success((stripLeadingKeyword(rawWhere, keyword: "where"), stripLeadingKeyword(rawOrder, keyword: "order by")))
    }

    /// 去掉首尾空白与**一个**结尾分号；若还剩分号（= 多条语句）返回 nil。
    private static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.contains(";") else { return nil }
        return text
    }

    /// 去掉用户可能一起粘进来的关键字（`WHERE a = 1` 与 `a = 1` 都接受）。
    private static func stripLeadingKeyword(_ text: String, keyword: String) -> String {
        let lowered = text.lowercased()
        guard lowered.hasPrefix(keyword) else { return text }
        let rest = text.dropFirst(keyword.count)
        // 必须是**独立的**关键字（`wherever` 不能被当成 `where`）。
        guard rest.isEmpty || rest.first.map({ $0.isWhitespace || $0 == "(" }) == true else { return text }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 找**顶层**的 `ORDER BY`（跳过单引号字符串、双引号标识符与括号内部）。
    ///
    /// 只做够用的一件事：这个条件框里出现 ORDER BY，几乎都是"顺手把整段条件粘进来"了。
    private static func topLevelOrderByRange(in text: String) -> Range<String.Index>? {
        var index = text.startIndex
        var depth = 0
        while index < text.endIndex {
            let character = text[index]

            if character == "'" || character == "\"" {
                let quote = character
                index = text.index(after: index)
                while index < text.endIndex {
                    if text[index] == quote {
                        let next = text.index(after: index)
                        if next < text.endIndex, text[next] == quote {
                            index = text.index(after: next)
                            continue
                        }
                        index = next
                        break
                    }
                    index = text.index(after: index)
                }
                continue
            }

            if character == "(" { depth += 1; index = text.index(after: index); continue }
            if character == ")" { depth = max(0, depth - 1); index = text.index(after: index); continue }

            if depth == 0, character.isWhitespace {
                let start = index
                var cursor = index
                while cursor < text.endIndex, text[cursor].isWhitespace {
                    cursor = text.index(after: cursor)
                }
                let tail = text[cursor...].lowercased()
                if tail.hasPrefix("order by") {
                    let afterKeyword = text.index(cursor, offsetBy: "order by".count)
                    // 关键字后面必须是空白或行尾，避免匹配到 `order byx`（列名）。
                    if afterKeyword == text.endIndex || text[afterKeyword].isWhitespace {
                        return start..<afterKeyword
                    }
                }
            }

            index = text.index(after: index)
        }
        return nil
    }
}
