import Foundation

/// 查询记忆索引（FR-AI-13 / 能力规划 §4.4 的 S2）与补全（S4）。
///
/// **事实源是归档 `.sql` 文件**（FR-EDIT-31），索引是**纯派生缓存**：
/// 删掉它不丢任何数据，重建即可 —— 这条不是洁癖，它让"索引这一层出错"变成无害的失败，
/// 也就不需要再建一份侧车日志去纠缠"文件和日志谁是真相"。
///
/// 三条设计口径（与规划书 §4 的决定一致）：
/// 1. **两级指纹**：粗指纹（结构骨架，用于聚类与频次）与精指纹（原文，用于"同一条"计数）。
///    统得太松会把语义不同的语句并成一条（补全给出错误候选），太紧则同一查询碎成几千条（候选全是噪音）。
/// 2. **按连接隔离**：记忆的键是连接名（连接里已含环境与登录账号）——
///    生产库的记忆不流进测试库，别人的记忆不流进我的。
/// 3. **消费顺序：补全 > 参数化 > 主动建议**。这里只做补全 —— 它是"你敲前几个字符就知道你要什么"，
///    而不是替用户决定该定时跑什么（后者误判代价不对称）。
public enum QueryMemory {

    /// 一条记忆（按粗指纹聚合）。
    public struct Memory: Equatable, Sendable {
        /// 粗指纹：结构骨架，用于聚类。
        public var fingerprint: String
        /// 最近一次执行的**完整原文**（补全时优先给最近写过的那版）。
        public var latestSQL: String
        /// 该骨架下出现过的原文数量（同一骨架的不同具体值）。
        public var variantCount: Int
        /// 累计执行次数（来自归档元信息）。
        public var runCount: Int
        /// 出现过的日期（跨天分布）。
        public var days: Set<String>
        /// 来源连接（按连接隔离用）。
        public var connections: Set<String>
        /// 最近执行时间。
        public var lastExecutedAt: Date

        public init(
            fingerprint: String,
            latestSQL: String,
            variantCount: Int,
            runCount: Int,
            days: Set<String>,
            connections: Set<String>,
            lastExecutedAt: Date
        ) {
            self.fingerprint = fingerprint
            self.latestSQL = latestSQL
            self.variantCount = variantCount
            self.runCount = runCount
            self.days = days
            self.connections = connections
            self.lastExecutedAt = lastExecutedAt
        }

        /// 是不是"跨越了多天"的重复劳动（规划书里"例行候选"的第一条统计判据）。
        /// 这里只作为展示信息 —— **不据此建任务**（判据要四条全满足，且只产生建议）。
        public var spansMultipleDays: Bool { days.count > 1 }
    }

    /// 索引本体。
    public struct Index: Equatable, Sendable {
        public var memories: [Memory]
        /// 读到的归档条目数（诊断用：索引是从多少条事实派生出来的）。
        public var parsedEntryCount: Int
        /// 被跳过的文件（读不了 / 不是归档格式），带原因 —— 不静默吞掉。
        public var skippedFiles: [String]

        public init(memories: [Memory] = [], parsedEntryCount: Int = 0, skippedFiles: [String] = []) {
            self.memories = memories
            self.parsedEntryCount = parsedEntryCount
            self.skippedFiles = skippedFiles
        }

        public var isEmpty: Bool { memories.isEmpty }
    }

    /// 一条补全候选。
    public struct Suggestion: Equatable, Sendable {
        public var memory: Memory
        /// 命中的原文（可能与 `memory.latestSQL` 不同：取的是**最匹配前缀**的那条）。
        public var sql: String
        public var score: Int

        public init(memory: Memory, sql: String, score: Int) {
            self.memory = memory
            self.sql = sql
            self.score = score
        }
    }

    // MARK: - S2 索引构建

    /// 从归档目录重建索引。
    ///
    /// - 逐文件解析（按文件名排序，日期早 → 晚），因此"最近执行"的判定与文件顺序无关；
    /// - 读不了的文件记进 `skippedFiles` 并继续（一个坏文件不该让整个记忆层不可用）。
    public static func buildIndex(
        directory: URL,
        fileManager: FileManager = .default
    ) -> Index {
        var memories: [String: Memory] = [:]
        var variants: [String: Set<String>] = [:]
        var parsedCount = 0
        var skipped: [String] = []

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "sql" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return Index(skippedFiles: ["（目录不可读：\(error.localizedDescription)）"])
        }

        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                skipped.append(file.lastPathComponent)
                continue
            }
            let entries = SQLArchive.parse(text)
            guard !entries.isEmpty else {
                // 空的 / 不是归档格式的文件：记下来但不报错（用户目录里可能有别的 .sql）。
                skipped.append(file.lastPathComponent)
                continue
            }
            parsedCount += entries.count

            for entry in entries {
                let fingerprint = coarseFingerprint(entry.sql)
                guard !fingerprint.isEmpty else { continue }

                var memory = memories[fingerprint] ?? Memory(
                    fingerprint: fingerprint,
                    latestSQL: entry.sql,
                    variantCount: 0,
                    runCount: 0,
                    days: [],
                    connections: [],
                    lastExecutedAt: entry.lastExecutedAt
                )

                memory.runCount += max(1, entry.runCount)
                memory.days.insert(dayKey(entry.lastExecutedAt))
                memory.connections.insert(entry.connection)
                if entry.lastExecutedAt >= memory.lastExecutedAt {
                    memory.lastExecutedAt = entry.lastExecutedAt
                    // 最近的原文优先（补全给"最近写过的那版"）。
                    memory.latestSQL = entry.sql
                }
                memories[fingerprint] = memory
                variants[fingerprint, default: []].insert(entry.sql)
            }
        }

        for (fingerprint, variantSet) in variants {
            memories[fingerprint]?.variantCount = variantSet.count
        }

        return Index(
            memories: memories.values.sorted { lhs, rhs in
                if lhs.runCount != rhs.runCount { return lhs.runCount > rhs.runCount }
                return lhs.fingerprint < rhs.fingerprint
            },
            parsedEntryCount: parsedCount,
            skippedFiles: skipped
        )
    }

    // MARK: - S4 补全

    /// 按前缀（或子串）给补全候选。
    ///
    /// 打分：前缀命中 > 词首命中 > 子串命中；同档再按**执行次数**、然后**最近执行**、
    /// 最后按 SQL 文本排序 —— **稳定**，否则同一个前缀每次给出的顺序都不一样（那比不给还烦）。
    ///
    /// - Parameter connection: 传了就**只在那个连接的记忆里找**（按连接隔离，见类型说明）。
    public static func suggestions(
        prefix: String,
        in index: Index,
        connection: String? = nil,
        limit: Int = 10
    ) -> [Suggestion] {
        let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        var results: [Suggestion] = []
        for memory in index.memories {
            if let connection, !memory.connections.contains(connection) { continue }

            // 在该骨架的最近原文里找匹配位置。
            let haystack = memory.latestSQL.lowercased()
            let score: Int
            if haystack.hasPrefix(needle) {
                score = 900
            } else if let range = haystack.range(of: needle) {
                // 词首（前面是空白或标点）比中间子串更可能是想要的。
                let isWordStart = range.lowerBound == haystack.startIndex
                    || haystack[haystack.index(before: range.lowerBound)].isWhitespace
                    || ".,;()".contains(haystack[haystack.index(before: range.lowerBound)])
                score = isWordStart ? 700 : 500
            } else {
                continue
            }

            results.append(Suggestion(memory: memory, sql: memory.latestSQL, score: score))
        }

        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.memory.runCount != rhs.memory.runCount { return lhs.memory.runCount > rhs.memory.runCount }
            if lhs.memory.lastExecutedAt != rhs.memory.lastExecutedAt {
                return lhs.memory.lastExecutedAt > rhs.memory.lastExecutedAt
            }
            return lhs.sql < rhs.sql
        }
        return Array(results.prefix(max(0, limit)))
    }

    // MARK: - 指纹

    /// **粗指纹**：结构骨架 —— 字符串字面量 → `'…'`、数字 → `?`、空白折叠、关键字小写。
    ///
    /// 为什么保留标识符：`FROM orders` 与 `FROM customers` 必须算**不同**的骨架，
    /// 否则补全会把查订单的语句推荐给正在查客户的人。
    /// 为什么归一化字面量与大小写：那是同一件事的不同取值/写法，不该碎成多条。
    public static func coarseFingerprint(_ sql: String) -> String {
        var result = ""
        var index = sql.startIndex

        while index < sql.endIndex {
            let character = sql[index]

            // 字符串字面量 → `'…'`（用 SQL 词法器同一套规则，避免把 `'a''b'` 判错）。
            if character == "'" {
                var cursor = sql.index(after: index)
                while cursor < sql.endIndex {
                    if sql[cursor] == "'" {
                        let next = sql.index(after: cursor)
                        if next < sql.endIndex, sql[next] == "'" {
                            cursor = sql.index(after: next)
                            continue
                        }
                        cursor = next
                        break
                    }
                    cursor = sql.index(after: cursor)
                }
                result += "'?'"
                index = cursor
                continue
            }

            // 数字字面量 → `?`
            if character.isNumber {
                var cursor = index
                while cursor < sql.endIndex, sql[cursor].isNumber || sql[cursor] == "." {
                    cursor = sql.index(after: cursor)
                }
                result += "?"
                index = cursor
                continue
            }

            // 空白折叠成单个空格
            if character.isWhitespace {
                if !result.hasSuffix(" ") { result += " " }
                index = sql.index(after: index)
                continue
            }

            result.append(character)
            index = sql.index(after: index)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 日期键（跨天分布用）。
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
