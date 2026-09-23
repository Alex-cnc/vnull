import Foundation

/// 把**客户端筛选条件**翻成 SQL `WHERE` 片段（FR-RES-09 的 R-21 兜底措施）。
///
/// 用途只有一个：用户在结果区筛出想要的行后，点「用筛选条件生成 WHERE」，
/// 把条件带回编辑器重新查询**全量数据**（客户端筛选只作用于已取回的行，这是个容易被误读的地方）。
///
/// ## 这是「近似」，不是「等价」——必须讲清
/// 客户端比较是**自然序 / 数字感知 / 可忽略大小写与变音符**的（`ResultFilter.matches` 用
/// `String.compare(options: [.numeric, .caseInsensitive])`），SQL 里没有完全对应的东西。
/// 因此这里生成的是**常见情形的近似式**：
/// - 一切比较都显式转换类型（`CAST(... AS TEXT)` / `CAST(... AS NUMERIC)`），
///   否则 `integer LIKE '%1%'` 在 PostgreSQL 上直接报「operator does not exist」；
/// - 「包含」用 `ILIKE`（不区分大小写）并在不需要时退化为 `LIKE`；
/// - 比较运算符只在**用户填的值能解析成数字**时才走数值比较，因为客户端就是「两侧都是数字才按数值比」；
/// - `%` `_` `\` 在 LIKE 模式下转义，字符串里的单引号按 SQL 规则双写 —— 用户输入不会被当成语法。
///
/// 生成结果由用户**在编辑器里过目后再执行**，绝不自动执行。
public enum ResultFilterSQL {

    /// 结果列在生成 SQL 时需要的元信息。
    public struct Column: Equatable, Sendable {
        public var name: String
        /// 该列被客户端当成数值列（决定比较用什么转换）。
        public var isNumeric: Bool

        public init(name: String, isNumeric: Bool = false) {
            self.name = name
            self.isNumeric = isNumeric
        }
    }

    /// 标识符加引号：`"` 双写。空名字退化为 `""`（调用方应避免，但至少不产生语法歧义）。
    public static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 字符串字面量：单引号双写。**不做** `\` 转义 —— 标准 SQL 的字符串里 `\` 就是普通字符，
    /// 只有 LIKE 模式串才需要另外处理（见 `escapeLikePattern`）。
    public static func quoteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// LIKE 模式里的通配符转义：`%` `_` `\` 前面加 `\`（配合 `ESCAPE '\'`）。
    /// 不转义的话，用户搜 `100%` 会变成「以 100 开头」——静默给出错误结果比报错更糟。
    public static func escapeLikePattern(_ value: String) -> String {
        var out = ""
        for character in value {
            if character == "\\" || character == "%" || character == "_" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    /// 单条筛选条件 → SQL 片段。`column` 用结果集里的列名。
    public static func predicate(for filter: ResultFilter, column: Column) -> String {
        let identifier = quoteIdentifier(column.name)
        let asText = "CAST(\(identifier) AS TEXT)"

        switch filter.op {
        case .isEmpty:
            // 客户端口径：SQL NULL 与空字符串都算「为空」。
            return "(\(identifier) IS NULL OR \(asText) = '')"
        case .isNotEmpty:
            return "(\(identifier) IS NOT NULL AND \(asText) <> '')"

        case .contains, .notContains:
            let pattern = escapeLikePattern(filter.value)
            let keyword = filter.caseSensitive ? "LIKE" : "ILIKE"
            let clause = "\(asText) \(keyword) \(quoteLiteral("%\(pattern)%")) ESCAPE '\\'"
            return filter.op == .contains ? clause : "NOT (\(clause))"

        case .equals, .notEquals:
            let clause = filter.caseSensitive
                ? "\(asText) = \(quoteLiteral(filter.value))"
                : "LOWER(\(asText)) = LOWER(\(quoteLiteral(filter.value)))"
            return filter.op == .equals ? clause : "NOT (\(clause))"

        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            let symbol: String
            switch filter.op {
            case .greaterThan: symbol = ">"
            case .greaterThanOrEqual: symbol = ">="
            case .lessThan: symbol = "<"
            default: symbol = "<="
            }
            // 用户填的是数字 → 按数值比（与客户端「两侧都能解析成数字才按数值比」一致）；
            // 否则按文本比。注意：数值分支要求该列**能转成 numeric**，非数值列会报错，
            // 这正是「近似」的一部分，已在类型注释里写明。
            if isNumericLiteral(filter.value) {
                return "CAST(\(identifier) AS NUMERIC) \(symbol) \(quoteLiteral(filter.value))"
            }
            return "\(asText) \(symbol) \(quoteLiteral(filter.value))"
        }
    }

    /// 整组条件 → `WHERE` 片段（多条件 AND）。无条件时返回 nil。
    /// 列号越界（结果集变了、列少了）的条件**丢弃**：宁少一条，不要生成引用不存在列的 SQL。
    public static func whereClause(filters: [ResultFilter], columns: [Column]) -> String? {
        let parts = filters.compactMap { filter -> String? in
            guard columns.indices.contains(filter.columnIndex) else { return nil }
            return predicate(for: filter, column: columns[filter.columnIndex])
        }
        guard !parts.isEmpty else { return nil }
        return "WHERE " + parts.joined(separator: "\n  AND ")
    }

    /// 该文本能否当成数字（与 `ResultView` 的数值判定同口径：允许正负号与小数点，不接受空串）。
    public static func isNumericLiteral(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return Double(trimmed) != nil
    }
}
