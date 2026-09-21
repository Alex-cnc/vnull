import Foundation

/// 锁等待与阻塞链（FR-DIAG-05）。
///
/// 纯逻辑：把「锁等待查询」的结果集转成模型，并解析出阻塞链。
/// SQL 由方言层提供（`SQLDialect.lockWaitingQuery()`），执行仍走 `DatabaseService`。
///
/// 场景：线上卡住时先回答两个问题——「谁在等锁」「被谁挡住」，而不是只杀掉受害者。
public struct LockWait: Identifiable, Hashable, Sendable {
    public var pid: Int
    public var user: String?
    public var database: String?
    public var state: String?
    public var waitEventType: String?
    public var waitEvent: String?
    public var lockType: String?
    /// 锁模式，如 `AccessExclusiveLock`。
    public var mode: String?
    /// 该锁是否已授予；未授予即正在等锁。
    public var granted: Bool
    /// 被锁对象（`relation::regclass`）；不涉及关系时为 nil。
    public var relation: String?
    /// 直接阻塞该会话的后端 pid（服务端 `pg_blocking_pids()`）。
    public var blockingPids: [Int]
    public var query: String?
    /// 已等待秒数（`now() - query_start`）；无法计算时为 nil。
    public var waitingSeconds: Int?

    public var id: Int { pid }

    /// 是否正被其他会话阻塞。
    public var isBlocked: Bool { !blockingPids.isEmpty }

    public init(
        pid: Int,
        user: String? = nil,
        database: String? = nil,
        state: String? = nil,
        waitEventType: String? = nil,
        waitEvent: String? = nil,
        lockType: String? = nil,
        mode: String? = nil,
        granted: Bool = true,
        relation: String? = nil,
        blockingPids: [Int] = [],
        query: String? = nil,
        waitingSeconds: Int? = nil
    ) {
        self.pid = pid
        self.user = user
        self.database = database
        self.state = state
        self.waitEventType = waitEventType
        self.waitEvent = waitEvent
        self.lockType = lockType
        self.mode = mode
        self.granted = granted
        self.relation = relation
        self.blockingPids = blockingPids
        self.query = query
        self.waitingSeconds = waitingSeconds
    }
}

public enum LockMonitor {

    /// 把查询结果映射成锁等待列表；缺 `pid` 的行跳过（无法定位到会话）。
    ///
    /// `granted` 缺失时按「有无阻塞者」推断：被阻塞的一律视为未授予。
    public static func waits(from result: QueryResult) -> [LockWait] {
        let index = columnIndexMap(result.columns)

        return result.rows.compactMap { row -> LockWait? in
            guard let pidText = value(row, keys: ["pid"], index: index),
                  let pid = Int(pidText.trimmingCharacters(in: .whitespaces))
            else { return nil }

            let blockers = parsePidList(value(row, keys: ["blocking_pids", "blocking"], index: index))
            let granted = parseBool(value(row, keys: ["granted"], index: index)) ?? blockers.isEmpty

            return LockWait(
                pid: pid,
                user: value(row, keys: ["usename", "user"], index: index),
                database: value(row, keys: ["datname", "database"], index: index),
                state: value(row, keys: ["state"], index: index),
                waitEventType: value(row, keys: ["wait_event_type"], index: index),
                waitEvent: value(row, keys: ["wait_event"], index: index),
                lockType: value(row, keys: ["locktype"], index: index),
                mode: value(row, keys: ["mode"], index: index),
                granted: granted,
                relation: emptyToNil(value(row, keys: ["relation"], index: index)),
                blockingPids: blockers,
                query: value(row, keys: ["query"], index: index),
                waitingSeconds: value(row, keys: ["waiting_seconds"], index: index)
                    .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            )
        }
    }

    /// 从 `pid` 出发沿阻塞关系回溯，返回链路（含起点）。
    ///
    /// 例：200 被 101 阻塞、101 被 100 阻塞 → `[200, 101, 100]`。
    /// 出现环（服务端理论上不会，但数据脏了也不能死循环）时在重复节点处停止。
    public static func blockingChain(from pid: Int, in waits: [LockWait]) -> [Int] {
        let byPid = Dictionary(waits.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [Int] = []
        var seen: Set<Int> = []
        var current: Int? = pid
        while let candidate = current, !seen.contains(candidate) {
            seen.insert(candidate)
            chain.append(candidate)
            current = byPid[candidate]?.blockingPids.first
        }
        return chain
    }

    /// 被阻塞的会话数。
    public static func blockedCount(in waits: [LockWait]) -> Int {
        waits.filter(\.isBlocked).count
    }

    /// 面板顶部结论。
    public static func summaryLines(for waits: [LockWait]) -> [String] {
        guard !waits.isEmpty else { return ["当前无锁等待"] }
        var lines = ["锁等待记录 \(waits.count) 条，被阻塞会话 \(blockedCount(in: waits)) 个"]
        if let longest = waits.compactMap(\.waitingSeconds).max(), longest > 0 {
            lines.append("最长等待 \(longest) 秒")
        }
        return lines
    }

    // MARK: - 解析辅助

    /// `pg_blocking_pids()` 经 `array_to_string` 后是 `101,102`；直接取 int[] 时是 `{101,102}`，两种都吃。
    static func parsePidList(_ raw: String?) -> [Int] {
        guard let raw else { return [] }
        let cleaned = raw
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
        return cleaned
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func parseBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "t", "true", "1", "on", "yes", "y": return true
        case "f", "false", "0", "off", "no", "n": return false
        default: return nil
        }
    }

    static func emptyToNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func columnIndexMap(_ columns: [ColumnMeta]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (position, column) in columns.enumerated() {
            map[column.name.lowercased()] = position
        }
        return map
    }

    static func value(_ row: [String?], keys: [String], index: [String: Int]) -> String? {
        for key in keys {
            if let position = index[key], position < row.count, let cell = row[position] {
                return cell
            }
        }
        return nil
    }
}
