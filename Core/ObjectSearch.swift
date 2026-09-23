import Foundation

/// 全库对象搜索（FR-META-12）：输入名称片段，跨 schema 匹配表 / 视图 / 列 / 函数。
///
/// 两条口径（与需求一致）：
/// 1. **一次元数据查询**（一条 `UNION ALL`）而不是"每类各查一次" —— 少三次往返，
///    结果也更一致（同一时刻的同一份元数据）；
/// 2. **客户端过滤与排序**，并沿用元数据查询的 **10,000 行上限**（R-11）。
///    因此查询里带 `LIMIT`，并在结果上标出"可能被截断"，不假装搜遍了全库。
public enum ObjectSearch {

    /// 命中类型。顺序即"同分时的优先级"（表最常用，列次之，函数再次）。
    public enum Kind: String, CaseIterable, Sendable {
        case table
        case view
        case column
        case function
        case other

        /// 展示与排序优先级（越小越靠前）。
        var priority: Int {
            switch self {
            case .table: return 0
            case .view: return 1
            case .column: return 2
            case .function: return 3
            case .other: return 4
            }
        }

        /// 从服务端给的类型文本推断（PG 的 `table_type` 是 `BASE TABLE` / `VIEW`）。
        static func from(detail: String?) -> Kind? {
            guard let detail = detail?.uppercased() else { return nil }
            if detail.contains("VIEW") { return .view }
            if detail.contains("BASE TABLE") || detail.contains("TABLE") { return .table }
            return nil
        }
    }

    public struct Hit: Equatable, Sendable {
        public var kind: Kind
        public var schema: String?
        /// 名称：列命中时是 `表.列`（这样"名称片段"既能命中表也能命中列）。
        public var name: String
        /// 补充信息（类型 / 函数签名）。
        public var detail: String?

        public init(kind: Kind, schema: String?, name: String, detail: String? = nil) {
            self.kind = kind
            self.schema = schema
            self.name = name
            self.detail = detail
        }

        /// `schema.name`（schema 为空时退化为 name）。
        public var qualifiedName: String {
            guard let schema, !schema.isEmpty else { return name }
            return "\(schema).\(name)"
        }
    }

    public struct Match: Equatable, Sendable {
        public var hit: Hit
        public var score: Int
        public var highlighted: [Int]

        public init(hit: Hit, score: Int, highlighted: [Int]) {
            self.hit = hit
            self.score = score
            self.highlighted = highlighted
        }
    }

    /// 分档（与命令面板同一套思路：档位关系一目了然，便于断言）。
    enum Score {
        static let exact = 1000
        static let prefix = 800
        static let wordPrefix = 700
        static let substring = 600
        static let subsequence = 300
    }

    /// 元数据查询的默认上限（R-11：元数据查询 10,000 行保护）。
    public static let defaultLimit = 10_000

    // MARK: - 查询

    /// 生成**一次**取回四类对象的查询；方言不支持时返回 nil。
    ///
    /// 为什么不用 `information_schema.routines` 取函数：那需要跨三张表 join，
    /// 而 `pg_proc` + `pg_get_function_arguments` 一行就能给出可读签名。
    public static func query(schema: String? = nil, limit: Int = ObjectSearch.defaultLimit) -> String? {
        let schemaFilter: String
        if let schema, !schema.isEmpty {
            let literal = "'" + schema.replacingOccurrences(of: "'", with: "''") + "'"
            // 指定 schema 时只搜它 —— 用户已经缩小了范围，不必再扫全库。
            schemaFilter = "AND t.table_schema = \(literal)"
        } else {
            schemaFilter = "AND t.table_schema NOT IN ('pg_catalog', 'information_schema')"
        }

        let functionFilter = schemaFilter
            .replacingOccurrences(of: "t.table_schema", with: "n.nspname")

        return """
        SELECT CASE WHEN t.table_type = 'VIEW' THEN 'view' ELSE 'table' END AS kind,
               t.table_schema AS schema_name,
               t.table_name AS object_name,
               t.table_type AS detail
        FROM information_schema.tables t
        WHERE t.table_type IN ('BASE TABLE', 'VIEW') \(schemaFilter)
        UNION ALL
        SELECT 'column' AS kind,
               c.table_schema AS schema_name,
               c.table_name || '.' || c.column_name AS object_name,
               c.data_type AS detail
        FROM information_schema.columns c
        WHERE c.table_schema NOT IN ('pg_catalog', 'information_schema')
          \(schema.map { _ in schemaFilter.replacingOccurrences(of: "t.table_schema", with: "c.table_schema") } ?? "")
        UNION ALL
        SELECT 'function' AS kind,
               n.nspname AS schema_name,
               p.proname AS object_name,
               pg_catalog.pg_get_function_arguments(p.oid) AS detail
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE TRUE \(functionFilter)
        LIMIT \(max(1, limit))
        """
    }

    /// 把查询结果解析成命中列表。
    public static func hits(from result: QueryResult) -> [Hit] {
        result.rows.compactMap { row -> Hit? in
            guard row.indices.contains(0), let rawKind = row[0]?.lowercased(),
                  row.indices.contains(2), let name = row[2], !name.isEmpty
            else { return nil }

            let detail = row.indices.contains(3) ? row[3] : nil
            let kind: Kind
            switch rawKind {
            case "view": kind = .view
            case "table": kind = Kind.from(detail: detail) == .view ? .view : .table
            case "column": kind = .column
            case "function": kind = .function
            default: kind = .other
            }

            let schema = row.indices.contains(1) ? row[1] : nil
            return Hit(kind: kind, schema: schema, name: name, detail: detail)
        }
    }

    // MARK: - 匹配与排序

    /// 搜索。**空查询返回空**（对象搜索与命令面板不同：全库对象可能有上万条，
    /// 空输入列出前 N 条既没用又让人以为"搜到了什么"）。
    public static func search(_ query: String, in hits: [Hit], limit: Int = 200) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var matches: [Match] = []
        for hit in hits {
            if let match = match(trimmed, hit: hit) {
                matches.append(match)
            }
        }

        // 稳定排序：先按分值，再按**类型优先级**（表 > 视图 > 列 > 函数），
        // 最后按名称 —— 不能依赖输入顺序，否则"同一个词搜两次结果不一样"。
        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.hit.kind.priority != rhs.hit.kind.priority {
                return lhs.hit.kind.priority < rhs.hit.kind.priority
            }
            return lhs.hit.qualifiedName < rhs.hit.qualifiedName
        }
        return Array(matches.prefix(max(0, limit)))
    }

    public static func match(_ query: String, hit: Hit) -> Match? {
        let needle = query.lowercased()
        let name = hit.name
        let lowered = name.lowercased()

        if lowered == needle {
            return Match(hit: hit, score: Score.exact, highlighted: Array(0..<name.count))
        }
        if lowered.hasPrefix(needle) {
            return Match(hit: hit, score: Score.prefix, highlighted: Array(0..<needle.count))
        }
        // 词首：`orders.email` 里的 `email` 是"词首"（点号分隔），比中间子串更可能是想要的。
        if let range = wordPrefixRange(lowered: lowered, needle: needle) {
            let start = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
            return Match(hit: hit, score: Score.wordPrefix, highlighted: Array(start..<(start + needle.count)))
        }
        if let range = lowered.range(of: needle) {
            let start = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
            return Match(hit: hit, score: Score.substring, highlighted: Array(start..<(start + needle.count)))
        }
        if let positions = subsequencePositions(needle: needle, haystack: lowered) {
            return Match(hit: hit, score: Score.subsequence, highlighted: positions)
        }
        return nil
    }

    static func wordPrefixRange(lowered: String, needle: String) -> Range<String.Index>? {
        var index = lowered.startIndex
        var isAtWordStart = true
        while index < lowered.endIndex {
            if isAtWordStart, lowered[index...].hasPrefix(needle) {
                return index..<lowered.index(index, offsetBy: needle.count)
            }
            let character = lowered[index]
            isAtWordStart = character == "." || character == "_" || character == "-" || character == " "
            index = lowered.index(after: index)
        }
        return isAtWordStart && lowered[index...].hasPrefix(needle)
            ? index..<lowered.index(index, offsetBy: needle.count)
            : nil
    }

    static func subsequencePositions(needle: String, haystack: String) -> [Int]? {
        var positions: [Int] = []
        var needleIndex = needle.startIndex
        var index = haystack.startIndex
        while index < haystack.endIndex, needleIndex < needle.endIndex {
            if haystack[index] == needle[needleIndex] {
                positions.append(haystack.distance(from: haystack.startIndex, to: index))
                needleIndex = needle.index(after: needleIndex)
            }
            index = haystack.index(after: index)
        }
        return needleIndex == needle.endIndex ? positions : nil
    }
}
