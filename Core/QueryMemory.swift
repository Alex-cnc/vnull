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
        /// 执行时刻的小时直方图（下标 0..23）。
        ///
        /// 为什么要直方图而不是时间戳列表：时间戳会随执行次数**无上限增长**，
        /// 24 个计数器是**恒定**的 —— 而「时刻集中度」这条判据只需要小时分布。
        /// 时刻取归档条目的 `lastExecutedAt`（同一天里最晚那次执行），本地时区；
        /// 用文件名里的日期算不出小时分布（那会让所有执行都落在 0 点，是假集中）。
        public var hourHistogram: [Int]
        /// 参数化结果：把该骨架下**精指纹不同**的原文按字面量序列对齐得到的模板与槽位样例。
        ///
        /// `nil` = 该骨架下的原文**结构并不一致**（大小写 / 空白 / 字面量种类不同，
        /// 即粗指纹碰撞）—— 于是「只改参数」判据不成立。这是保守侧的落点：
        /// 拿不准就不升格，宁可漏掉一个真例行，也不要建议去定时一个结构不明的脚本。
        ///
        /// 存结构而不是只存渲染好的模板字符串，是因为人工「保留字面量」决定要在**评估时**
        /// 把某个槽位改回字面量：光有一串 `?` 改不回去（用户自己写的 `?` 占位符长得一样）。
        public var parameterization: RoutineCandidate.Parameterization?

        public init(
            fingerprint: String,
            latestSQL: String,
            variantCount: Int,
            runCount: Int,
            days: Set<String>,
            connections: Set<String>,
            lastExecutedAt: Date,
            hourHistogram: [Int] = Array(repeating: 0, count: 24),
            parameterization: RoutineCandidate.Parameterization? = nil
        ) {
            self.fingerprint = fingerprint
            self.latestSQL = latestSQL
            self.variantCount = variantCount
            self.runCount = runCount
            self.days = days
            self.connections = connections
            self.lastExecutedAt = lastExecutedAt
            self.hourHistogram = hourHistogram
            self.parameterization = parameterization
        }

        /// 是不是"跨越了多天"的重复劳动（规划书里"例行候选"的第一条统计判据）。
        /// 这里只作为展示信息 —— **不据此建任务**（判据要四条全满足，且只产生建议）。
        public var spansMultipleDays: Bool { days.count > 1 }

        /// 「只改参数」判据的结构前提：该骨架下必须有 **≥2 条不同的原文（精指纹）**，
        /// 且每条原文都能被同一个模板**逐字还原**（把槽位换成各自取值即可）。
        ///
        /// 单条原文重复执行 N 次**不算**满足 —— 那不是参数化，只是重复；
        /// 而结构不一致（模板为 nil）说明粗指纹发生了碰撞，必须按"不是参数化查询"处理。
        public var variantsMatchOneTemplate: Bool {
            variantCount >= 2 && parameterization != nil
        }
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
        fileManager: FileManager = .default,
        calendar: Calendar = .current
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
                // 合法的**空归档**（删完条目后只剩文件头）不是可疑文件：静默跳过。
                if SQLArchive.isArchiveText(text) { continue }
                // 其余"空 / 不是归档格式"的文件记下来但不报错（用户目录里可能有别的 .sql）。
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
                memory.days.insert(dayKey(entry.lastExecutedAt, calendar: calendar))
                memory.connections.insert(entry.connection)
                // 时刻集中度用的是**归档条目里的执行时间戳**（不是文件名）。
                // 按条目计一次所有权重（runCount 全部记在它最晚那次执行的小时上）：
                // 归档只保留首/末两个时间点，把次数摊到未知的中间时刻是编造数据；
                // 记在末次时刻至少是"确实发生过"的一个时刻。
                let hour = calendar.component(.hour, from: entry.lastExecutedAt)
                if memory.hourHistogram.indices.contains(hour) {
                    memory.hourHistogram[hour] += max(1, entry.runCount)
                }
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
            // 参数化只在这一步做：它需要该骨架下**全部不同的原文**，而 `variantSet` 正是那个集合。
            // 传入前排序 —— `Set` 的遍历顺序不稳定，不排序就等于埋一颗"同一目录两次运行结果不同"的雷。
            // 粗指纹只负责**分成一组**，而"这些原文是不是只差参数"必须由这里逐字判定：
            // 粗指纹小写化 + 折叠空白，会把 `SELECT …` 与 `select …` 归成同一个骨架。
            memories[fingerprint]?.parameterization = RoutineCandidate.align(variantSet.sorted())
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

            // 引号包起来的**标识符**（`"orders1"` / `` `orders1` ``）原样保留。
            //
            // 这一步不能省：只按"逐个字符扫"的写法，引号内的数字会在下面那条
            // 数字分支里被换成 `?`，于是 `"t1"` 与 `"t2"` 变成同一个骨架。
            if character == "\"" || character == "`" {
                let quote = character
                var cursor = sql.index(after: index)
                while cursor < sql.endIndex {
                    let current = sql[cursor]
                    cursor = sql.index(after: cursor)
                    if current == quote {
                        // 双写引号是转义（`"a""b"` 是一个标识符）。
                        if cursor < sql.endIndex, sql[cursor] == quote {
                            cursor = sql.index(after: cursor)
                            continue
                        }
                        break
                    }
                }
                result += String(sql[index..<cursor])
                index = cursor
                continue
            }

            // 标识符：**连同其中的数字一起**原样保留。
            //
            // 2026-09-23 修：原先逐字符扫描，`FROM orders1` 与 `FROM orders2` 都会被归一成
            // `from orders?` 而**并成一条记忆** —— 频次被合并、补全会把 orders1 的语句推给
            // 正在查 orders2 的人，正是本文件注释里声称要防的"张冠李戴"。当初的 16 项单测
            // 与验证脚本没用过"只有数字不同的表名"这种现场，所以没抓出来。
            if character.isLetter || character == "_" || character == "$" {
                var cursor = index
                while cursor < sql.endIndex {
                    let current = sql[cursor]
                    guard current.isLetter || current.isNumber || current == "_" || current == "$" else { break }
                    cursor = sql.index(after: cursor)
                }
                result += String(sql[index..<cursor])
                index = cursor
                continue
            }

            // 数字**字面量** → `?`（只有以数字开头的独立词才走这里）
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
