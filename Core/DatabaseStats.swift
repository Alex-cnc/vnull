import Foundation

/// 数据库统计指标（FR-DIAG-04）：表大小 / 索引命中率 / 连接数 / 缓存命中率。
///
/// 三条约定的口径：
/// 1. **只用 PG 12 起就有的视图**（`pg_statio_user_tables` / `pg_stat_user_tables` /
///    `pg_stat_activity` / `pg_stat_database`），**不用 `pg_stat_io`（16+）** ——
///    需求原文点名"按版本兼容"，这里就是它的落点。
/// 2. **比率算不出来时给 `nil`，不给 0 也不给 NaN**：刚建的库没有任何扫描，
///    "命中率"没有定义 —— 显示成 0% 会让人以为"索引完全没被用上"。
/// 3. 解析是**纯函数**（列名不敏感、缺列不崩），因此可以脱离数据库单测。
public enum DatabaseStats {

    /// 四类指标。
    public enum Metric: String, CaseIterable, Sendable {
        case tableSizes
        case indexHitRate
        case connections
        case cacheHitRate

        public var displayName: String {
            switch self {
            case .tableSizes: return "表大小"
            case .indexHitRate: return "索引命中率"
            case .connections: return "连接数"
            case .cacheHitRate: return "缓存命中率"
            }
        }
    }

    /// 一张表的大小。
    public struct TableSize: Equatable, Sendable {
        public var name: String
        public var bytes: Int64

        public init(name: String, bytes: Int64) {
            self.name = name
            self.bytes = bytes
        }

        public var displaySize: String { DatabaseStats.formatBytes(bytes) }
    }

    /// 一张表的扫描构成（用来算索引命中率）。
    public struct TableScans: Equatable, Sendable {
        public var name: String
        public var sequential: Int
        public var index: Int

        public init(name: String, sequential: Int, index: Int) {
            self.name = name
            self.sequential = sequential
            self.index = index
        }

        /// 索引命中率（0…1）。**总扫描为 0 时是 `nil`** —— 没有数据不等于 0%。
        public var indexHitRatio: Double? {
            let total = sequential + index
            guard total > 0 else { return nil }
            return Double(index) / Double(total)
        }

        public var displayRatio: String {
            guard let ratio = indexHitRatio else { return "无扫描数据" }
            return String(format: "%.1f%%", ratio * 100)
        }
    }

    /// 连接状态分布。
    public struct ConnectionSummary: Equatable, Sendable {
        public var byState: [String: Int]

        public init(byState: [String: Int]) {
            self.byState = byState
        }

        public var total: Int { byState.values.reduce(0, +) }

        /// 稳定顺序（按状态名排序），便于展示与断言。
        public var ordered: [(state: String, count: Int)] {
            byState.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
    }

    /// 缓存命中率。
    public struct CacheHit: Equatable, Sendable {
        public var hits: Int64
        public var reads: Int64

        public init(hits: Int64, reads: Int64) {
            self.hits = hits
            self.reads = reads
        }

        /// 命中率（0…1）。**总访问为 0 时是 `nil`**（同索引命中率的口径）。
        public var ratio: Double? {
            let total = hits + reads
            guard total > 0 else { return nil }
            return Double(hits) / Double(total)
        }

        public var displayRatio: String {
            guard let ratio else { return "无访问数据" }
            return String(format: "%.2f%%", ratio * 100)
        }
    }

    // MARK: 解析（纯函数）

    public static func tableSizes(from result: QueryResult, limit: Int = 20) -> [TableSize] {
        let index = columnIndexMap(result.columns)
        let sizes = result.rows.compactMap { row -> TableSize? in
            guard let name = value(row, keys: ["name", "table", "relname"], index: index) else { return nil }
            let raw = value(row, keys: ["bytes", "size"], index: index) ?? "0"
            return TableSize(name: name, bytes: Int64(raw) ?? 0)
        }
        // 按大小降序、再按名字升序（稳定）：同名大小相同时顺序不抖
        return sizes
            .sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.name < rhs.name
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public static func tableScans(from result: QueryResult, limit: Int = 20) -> [TableScans] {
        let index = columnIndexMap(result.columns)
        let scans = result.rows.compactMap { row -> TableScans? in
            guard let name = value(row, keys: ["name", "table", "relname"], index: index) else { return nil }
            let sequential = Int(value(row, keys: ["seq_scan", "sequential"], index: index) ?? "0") ?? 0
            let idx = Int(value(row, keys: ["idx_scan", "index"], index: index) ?? "0") ?? 0
            return TableScans(name: name, sequential: sequential, index: idx)
        }
        // 总扫描多的排前面；都是 0 时按名字（否则顺序不稳定）
        return scans
            .sorted { lhs, rhs in
                let lhsTotal = lhs.sequential + lhs.index
                let rhsTotal = rhs.sequential + rhs.index
                if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
                return lhs.name < rhs.name
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public static func connections(from result: QueryResult) -> ConnectionSummary {
        let index = columnIndexMap(result.columns)
        var byState: [String: Int] = [:]
        for row in result.rows {
            let state = value(row, keys: ["state"], index: index) ?? "unknown"
            let count = Int(value(row, keys: ["count", "connections"], index: index) ?? "0") ?? 0
            byState[state, default: 0] += count
        }
        return ConnectionSummary(byState: byState)
    }

    public static func cacheHit(from result: QueryResult) -> CacheHit? {
        let index = columnIndexMap(result.columns)
        guard let row = result.rows.first else { return nil }
        let hits = Int64(value(row, keys: ["hits", "blks_hit"], index: index) ?? "0") ?? 0
        let reads = Int64(value(row, keys: ["reads", "blks_read"], index: index) ?? "0") ?? 0
        return CacheHit(hits: hits, reads: reads)
    }

    // MARK: 报告组装（App 面板与 CLI 共用，避免两处各写一套）

    /// 一次采集的四类指标。缺的那一类是 `nil`（方言不支持，或该条查询没跑成）。
    public struct Report: Equatable, Sendable {
        public var tableSizes: [TableSize]
        public var tableScans: [TableScans]
        public var connections: ConnectionSummary
        public var cacheHit: CacheHit?
        /// 四类里至少拿到一类，才算"这个方言支持统计"。
        public var isSupported: Bool

        public init(
            tableSizes: [TableSize] = [],
            tableScans: [TableScans] = [],
            connections: ConnectionSummary = ConnectionSummary(byState: [:]),
            cacheHit: CacheHit? = nil,
            isSupported: Bool = false
        ) {
            self.tableSizes = tableSizes
            self.tableScans = tableScans
            self.connections = connections
            self.cacheHit = cacheHit
            self.isSupported = isSupported
        }
    }

    /// 把四条查询的结果组装成报告。**纯函数**：`nil` 参与不了就跳过，
    /// 不会因为某一类拿不到而把整份报告判为失败（诊断面板要的是"有什么看什么"）。
    public static func report(
        tableSizes sizesResult: QueryResult?,
        tableScans scansResult: QueryResult?,
        connections connectionsResult: QueryResult?,
        cacheHit cacheResult: QueryResult?,
        limit: Int = 20
    ) -> Report {
        Report(
            tableSizes: sizesResult.map { tableSizes(from: $0, limit: limit) } ?? [],
            tableScans: scansResult.map { tableScans(from: $0, limit: limit) } ?? [],
            connections: connectionsResult.map { connections(from: $0) } ?? ConnectionSummary(byState: [:]),
            cacheHit: cacheResult.flatMap { cacheHit(from: $0) },
            isSupported: sizesResult != nil || scansResult != nil || connectionsResult != nil || cacheResult != nil
        )
    }

    // MARK: 展示

    /// 人类可读的字节数（`1.5 MB` 这类）。
    public static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }

    // MARK: Helpers

    private static func columnIndexMap(_ columns: [ColumnMeta]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (position, column) in columns.enumerated() {
            map[column.name.lowercased()] = position
        }
        return map
    }

    private static func value(_ row: [String?], keys: [String], index: [String: Int]) -> String? {
        for key in keys {
            if let position = index[key.lowercased()], row.indices.contains(position), let raw = row[position] {
                return raw
            }
        }
        return nil
    }
}
