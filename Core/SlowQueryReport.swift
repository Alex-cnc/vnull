import Foundation

/// 慢查询排行（FR-DIAG-03）：基于 `pg_stat_statements`。
///
/// 三件必须处理好的事：
/// 1. **扩展可能没装** —— 那不是错误，而是一种常见状态。要给"怎么装"的可读提示，
///    而不是抛一句 `relation "pg_stat_statements" does not exist`；
/// 2. **列名跨版本不同** —— PostgreSQL 13 把 `total_time` / `mean_time` 改名为
///    `total_exec_time` / `mean_exec_time`。我们声明支持 12–18，这条差异必须按服务端版本生成 SQL；
/// 3. **慢查询文本往往很长** —— 排行里要截断显示，但**不能只截不说**（与 FR-DATA-05 同一纪律）。
public enum SlowQueryReport {

    /// 排序口径。
    public enum Sort: String, CaseIterable, Sendable {
        case totalTime
        case meanTime
        case calls

        /// 进入 SQL 的排序列名（按版本解析）。
        func column(serverMajor: Int) -> String {
            switch self {
            case .totalTime: return serverMajor >= 13 ? "total_exec_time" : "total_time"
            case .meanTime: return serverMajor >= 13 ? "mean_exec_time" : "mean_time"
            case .calls: return "calls"
            }
        }

        public var displayName: String {
            switch self {
            case .totalTime: return "总耗时"
            case .meanTime: return "平均耗时"
            case .calls: return "调用次数"
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public var query: String
        public var calls: Int
        /// 总耗时（毫秒）。PostgreSQL 给的是毫秒浮点。
        public var totalMillis: Double
        public var meanMillis: Double
        public var rows: Int

        public init(query: String, calls: Int, totalMillis: Double, meanMillis: Double, rows: Int) {
            self.query = query
            self.calls = calls
            self.totalMillis = totalMillis
            self.meanMillis = meanMillis
            self.rows = rows
        }

        /// 排行里显示的查询文本（按**字符**截断，不切碎多字节字符）。
        public func display(maxLength: Int = SlowQueryReport.defaultQueryDisplayLimit) -> String {
            let collapsed = query
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard collapsed.count > maxLength else { return collapsed }
            return String(collapsed.prefix(maxLength)) + "…"
        }

        public var isQueryTruncated: Bool {
            display().hasSuffix("…")
        }
    }

    public static let defaultQueryDisplayLimit = 160

    /// 可用性检查：`pg_stat_statements` 是否**可用**。
    ///
    /// 判两条而不是一条：① `pg_extension` 里有没有；② 有没有一个叫这个名字的**关系**。
    /// 为什么看第二条 —— 除了"扩展以别的机制提供"这种少见情况，它还让**验证**成为可能：
    /// 本机精简构建（pgserver）不带该扩展文件，用同名视图就能把生成的 SQL 在真库上跑一遍
    /// （列名 / 排序 / 过滤全都能验）。**只认 `pg_extension` 会让这条 SQL 永远没被真跑过。**
    ///
    /// 注意它仍不回答"有没有在 `shared_preload_libraries` 里" —— 后者要重启才生效，
    /// 用户遇到时看到的是另一条报错，提示里一并说清。
    public static let extensionCheckQuery = """
    SELECT (SELECT extname FROM pg_extension WHERE extname = 'pg_stat_statements') AS extension,
           (to_regclass('pg_stat_statements') IS NOT NULL) AS relation_exists
    """

    /// 排行查询。`serverMajor` 决定用哪套列名（PG 13 起把 `total_time` 改成 `total_exec_time`）。
    public static func query(
        sort: Sort = .totalTime,
        limit: Int = 20,
        serverMajor: Int = 18
    ) -> String {
        let totalColumn = serverMajor >= 13 ? "total_exec_time" : "total_time"
        let meanColumn = serverMajor >= 13 ? "mean_exec_time" : "mean_time"
        return """
        SELECT query,
               calls,
               \(totalColumn) AS total_millis,
               \(meanColumn) AS mean_millis,
               rows
        FROM pg_stat_statements
        WHERE query NOT LIKE '%pg_stat_statements%'
        ORDER BY \(sort.column(serverMajor: serverMajor)) DESC
        LIMIT \(max(1, limit))
        """
    }

    /// 把结果解析成条目（列名不敏感 —— 不同版本、不同包装查询都可能改列名）。
    public static func entries(from result: QueryResult) -> [Entry] {
        let index = columnIndexMap(result.columns)
        return result.rows.compactMap { row in
            guard let query = value(row, keys: ["query"], index: index), !query.isEmpty else { return nil }
            return Entry(
                query: query,
                calls: Int(value(row, keys: ["calls"], index: index) ?? "0") ?? 0,
                totalMillis: Double(value(row, keys: ["total_millis", "total_exec_time", "total_time"], index: index) ?? "0") ?? 0,
                meanMillis: Double(value(row, keys: ["mean_millis", "mean_exec_time", "mean_time"], index: index) ?? "0") ?? 0,
                rows: Int(value(row, keys: ["rows"], index: index) ?? "0") ?? 0
            )
        }
    }

    /// 是否可用（解析可用性查询的结果：扩展名命中，或同名关系存在）。
    public static func isExtensionInstalled(_ result: QueryResult) -> Bool {
        result.rows.contains { row in
            let extensionName = row.indices.contains(0) ? row[0]?.lowercased() : nil
            let relationExists = row.indices.contains(1) ? row[1]?.lowercased() : nil
            if extensionName == "pg_stat_statements" { return true }
            return relationExists == "t" || relationExists == "true"
        }
    }

    /// 没装扩展时给用户的**可读提示**（含怎么装 —— 只说"没装"等于把问题丢回去）。
    ///
    /// 为什么把"重启"也写上：`shared_preload_libraries` 只在启动时读取，
    /// 只 `CREATE EXTENSION` 会得到一个"装了但查不到数据"的困惑状态。
    public static let missingExtensionMessage = """
    慢查询排行需要 pg_stat_statements 扩展，当前实例上没装。安装步骤：
      1. 在 postgresql.conf（或 ALTER SYSTEM）里加：shared_preload_libraries = 'pg_stat_statements'
      2. **重启实例**（这个参数只在启动时读取）
      3. 在目标库里执行：CREATE EXTENSION pg_stat_statements;
    注意：普通用户可能没有 CREATE EXTENSION 权限，需要管理员执行。
    """

    /// 耗时的人话格式：`1.2 s` / `850 ms` / `0.4 ms`。
    public static func formatDuration(millis: Double) -> String {
        if millis >= 1_000 {
            return String(format: "%.2f s", millis / 1_000)
        }
        if millis >= 1 {
            return String(format: "%.0f ms", millis)
        }
        return String(format: "%.2f ms", millis)
    }

    // MARK: 内部

    private static func columnIndexMap(_ columns: [ColumnMeta]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, column) in columns.enumerated() {
            map[column.name.lowercased()] = index
        }
        return map
    }

    private static func value(_ row: [String?], keys: [String], index: [String: Int]) -> String? {
        for key in keys {
            if let position = index[key], row.indices.contains(position), let text = row[position], !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
