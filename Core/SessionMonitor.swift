import Foundation

/// 服务器会话（`pg_stat_activity` / `SHOW PROCESSLIST` 的一行）（FR-SESS-01）。
///
/// 字段全部做成可选：不同数据库、不同版本返回的列不一样，
/// 缺失的列不该让整行解析失败，界面按「有就显示」处理。
public struct ServerSession: Identifiable, Hashable, Sendable {
    public var pid: Int
    public var user: String?
    public var database: String?
    public var clientAddress: String?
    public var applicationName: String?
    /// 状态文本，例如 `active` / `idle` / `idle in transaction`。
    public var state: String?
    public var waitEventType: String?
    public var waitEvent: String?
    public var backendStart: String?
    public var queryStart: String?
    public var query: String?

    public var id: Int { pid }

    public init(
        pid: Int,
        user: String? = nil,
        database: String? = nil,
        clientAddress: String? = nil,
        applicationName: String? = nil,
        state: String? = nil,
        waitEventType: String? = nil,
        waitEvent: String? = nil,
        backendStart: String? = nil,
        queryStart: String? = nil,
        query: String? = nil
    ) {
        self.pid = pid
        self.user = user
        self.database = database
        self.clientAddress = clientAddress
        self.applicationName = applicationName
        self.state = state
        self.waitEventType = waitEventType
        self.waitEvent = waitEvent
        self.backendStart = backendStart
        self.queryStart = queryStart
        self.query = query
    }

    /// 是否正在执行语句。
    ///
    /// 跨库判定：PostgreSQL 的 `state` 用 `active`；
    /// MySQL 的 `SHOW PROCESSLIST` 用 `Command = Query` 表示在跑，`State` 形如 `executing`。
    /// 没有 `application_name` 列时，`Command` 会回退落在 `applicationName` 上。
    public var isActive: Bool {
        let value = (state ?? "").lowercased()
        if value.hasPrefix("active") || value == "query" || value.hasPrefix("executing") {
            return true
        }
        return (applicationName ?? "").lowercased() == "query"
    }

    /// 是否空闲（`idle in transaction` 不算空闲）。
    ///
    /// 跨库判定：PostgreSQL 是 `idle`；MySQL 的 `Command = Sleep` 对应空闲连接。
    public var isIdle: Bool {
        let value = (state ?? "").lowercased()
        return value == "idle" || value == "sleep"
    }

    /// 是否被锁 / 等待事件阻塞。
    public var isWaiting: Bool {
        guard let waitEventType, !waitEventType.isEmpty else { return false }
        return waitEventType.lowercased() != "client"
    }

    /// 单行查询摘要（供列表显示）。
    public var querySummary: String {
        SessionMonitor.summarize(query)
    }

    /// 语句已运行时长（秒）；无法解析时间时返回 nil。
    public func elapsedSeconds(now: Date = Date()) -> TimeInterval? {
        SessionMonitor.elapsedSeconds(since: queryStart, now: now)
    }
}

/// 会话监控的解析与判定（FR-SESS-01、FR-SESS-02）。
///
/// 只做「结果集 → 模型」的纯逻辑转换，SQL 由方言层给出
/// （`SQLDialect.serverActivityQuery()` 等），执行仍走 `DatabaseService`。
public enum SessionMonitor {

    /// 把查询结果按列名映射成会话列表。
    ///
    /// 列名匹配不区分大小写，并兼容 `SHOW PROCESSLIST` 的 `Id` / `User` / `db` / `Info`
    /// 与 `pg_stat_activity` 的 `pid` / `usename` / `datname` / `query` 两套命名。
    public static func sessions(from result: QueryResult) -> [ServerSession] {
        let index = columnIndexMap(result.columns)

        return result.rows.compactMap { row -> ServerSession? in
            guard let pidText = value(row, keys: ["pid", "id", "processlist_id"], index: index),
                  let pid = Int(pidText.trimmingCharacters(in: .whitespaces))
            else {
                return nil
            }

            return ServerSession(
                pid: pid,
                user: value(row, keys: ["usename", "user"], index: index),
                database: value(row, keys: ["datname", "db", "database"], index: index),
                clientAddress: value(row, keys: ["client_addr", "host", "client_address"], index: index),
                applicationName: value(row, keys: ["application_name", "command"], index: index),
                state: value(row, keys: ["state", "command"], index: index),
                waitEventType: value(row, keys: ["wait_event_type"], index: index),
                waitEvent: value(row, keys: ["wait_event"], index: index),
                backendStart: value(row, keys: ["backend_start"], index: index),
                queryStart: value(row, keys: ["query_start", "time"], index: index),
                query: value(row, keys: ["query", "info"], index: index)
            )
        }
    }

    /// 多行 SQL 压成一行，去掉多余空白，供列表显示。
    public static func summarize(_ sql: String?, limit: Int = 160) -> String {
        guard let sql else { return "" }
        let collapsed = sql
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// 「时间戳 → 距今多少秒」。
    ///
    /// PostgreSQL 默认输出形如 `2026-09-20 22:00:00.123456+08`（带时区偏移、
    /// 小数位可能是 0/1/3/6 位），这里按几种常见形态依次尝试解析；
    /// 都失败时返回 nil，界面显示原始字符串就好，不猜。
    public static func elapsedSeconds(since timestamp: String?, now: Date = Date()) -> TimeInterval? {
        guard let date = parseTimestamp(timestamp) else { return nil }
        return now.timeIntervalSince(date)
    }

    /// 解析 PostgreSQL / MySQL 常见时间戳文本。
    public static func parseTimestamp(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        let text = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let formats = [
            "yyyy-MM-dd HH:mm:ss.SSSSSSxx",
            "yyyy-MM-dd HH:mm:ss.SSSxx",
            "yyyy-MM-dd HH:mm:ssxx",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            // 不带时区的格式按 UTC 解释：会话监控只看「相对时长」，
            // 用哪个时区解释只影响绝对时刻，不影响差值。
            if let date = formatter.date(from: text) {
                return date
            }
        }

        return nil
    }

    /// 会话列表排序：活跃的、等待的排前面，其余按 pid。
    public static func sorted(_ sessions: [ServerSession]) -> [ServerSession] {
        sessions.sorted { lhs, rhs in
            let lhsRank = rank(lhs)
            let rhsRank = rank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.pid < rhs.pid
        }
    }

    private static func rank(_ session: ServerSession) -> Int {
        if session.isWaiting { return 0 }
        if session.isActive { return 1 }
        return 2
    }

    // MARK: - 内部

    /// 列名（小写）→ 列下标。
    private static func columnIndexMap(_ columns: [ColumnMeta]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (position, column) in columns.enumerated() {
            let key = column.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if map[key] == nil {
                map[key] = position
            }
        }
        return map
    }

    /// 按候选键取第一个非空值（NULL 不参与匹配，避免 `command` 覆盖 `state` 之类的问题）。
    private static func value(
        _ row: [String?],
        keys: [String],
        index: [String: Int]
    ) -> String? {
        for key in keys {
            guard let position = index[key], position < row.count, let cell = row[position] else { continue }
            return cell
        }
        return nil
    }
}
