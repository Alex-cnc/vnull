import Foundation

/// 记忆治理（FR-AI-15）：生命周期按类型分、每条可解释、环境层与通用层分离。
///
/// 四条不能被做松的口径：
/// 1. **不按天数一刀切**：例行与人工钉住（含"一年只用一次的巡检脚本"）**永不因时间遗忘** ——
///    按固定天数清理恰好会先清掉这类最该留的东西（验收①）。
/// 2. **遗忘要给数字**：理由里必须带实际的闲置天数与执行次数，不接受"太久没用"这种说法（验收③）。
/// 3. **环境层严格按连接隔离**：库表名 / 数据分布 / "这条在哪跑的"都属于环境层，
///    沿用 `QueryMemory.Memory.connections` 的口径 —— 每个登录用户有各自的记忆。
/// 4. **通用层提升要过脱敏闸**：通用写法里**不许留下任何具体库表名与数据值**（验收④）。
public enum MemoryGovernance {}

// MARK: - 类别与生命周期

/// 记忆类别。不同类别**不同生命周期**（这正是"不按固定天数一刀切"的落点）。
public enum MemoryKind: String, CaseIterable, Sendable {
    /// 例行：反复执行的同一条查询（FR-AI-14 说的"例行候选"）。
    case routine
    /// 排障：临时排查用过的语句。唯一可能被时间遗忘的类别。
    case troubleshooting
    /// 人工钉住：用户明确要留的（含巡检脚本）。
    case pinned
    /// 通用层：跨连接的写法经验（见 `MemoryLayer.general`）。
    case general

    public var label: String {
        switch self {
        case .routine: return "例行"
        case .troubleshooting: return "排障"
        case .pinned: return "已钉住"
        case .general: return "通用写法"
        }
    }
}

/// 评估遗忘所需的统计量（从 `QueryMemory.Memory` 组装，便于单测直接构造）。
public struct MemoryStats: Equatable, Sendable {
    public var runCount: Int
    public var dayCount: Int
    public var variantCount: Int
    public var lastExecutedAt: Date
    public var connections: [String]

    public init(
        runCount: Int,
        dayCount: Int,
        variantCount: Int,
        lastExecutedAt: Date,
        connections: [String]
    ) {
        self.runCount = runCount
        self.dayCount = dayCount
        self.variantCount = variantCount
        self.lastExecutedAt = lastExecutedAt
        self.connections = connections
    }

    public init(memory: QueryMemory.Memory) {
        self.init(
            runCount: memory.runCount,
            dayCount: memory.days.count,
            variantCount: memory.variantCount,
            lastExecutedAt: memory.lastExecutedAt,
            connections: memory.connections.sorted()
        )
    }
}

/// 生命周期策略。**只有排障类**会被时间遗忘，且必须"闲置够久**且**用得少"两条同时成立。
public struct RetentionPolicy: Equatable, Sendable {
    /// 排障类闲置多久才考虑遗忘。
    public var idleDays: Int
    /// 累计执行少于这个次数才算"用得少"。
    public var lowUseRunCount: Int

    public init(idleDays: Int = 180, lowUseRunCount: Int = 3) {
        self.idleDays = idleDays
        self.lowUseRunCount = lowUseRunCount
    }

    public static let standard = RetentionPolicy()

    /// 遗忘判定。`reason` 一定带实际数字（验收③）。
    public func evaluate(kind: MemoryKind, stats: MemoryStats, now: Date) -> RetentionVerdict {
        let idle = Self.idleDays(from: stats.lastExecutedAt, to: now)

        switch kind {
        case .routine, .pinned, .general:
            // 这三类**永不因时间遗忘**。措辞里点明理由，免得后人以为漏了清理逻辑。
            return RetentionVerdict(
                shouldForget: false,
                reason: "\(kind.label)类不按天数清理：已闲置 \(idle) 天、累计执行 \(stats.runCount) 次"
                    + "（一年只用一次的巡检脚本正是这一档要留的）"
            )
        case .troubleshooting:
            let idleEnough = idle >= idleDays
            let lowUse = stats.runCount < lowUseRunCount
            if idleEnough && lowUse {
                return RetentionVerdict(
                    shouldForget: true,
                    reason: "排障类且闲置 \(idle) 天（≥ \(idleDays)）且累计执行 \(stats.runCount) 次（< \(lowUseRunCount)）"
                )
            }
            let why = idleEnough
                ? "用得不少（累计 \(stats.runCount) 次 ≥ \(lowUseRunCount)）"
                : "闲置 \(idle) 天（< \(idleDays)）"
            return RetentionVerdict(shouldForget: false, reason: "排障类保留：\(why)")
        }
    }

    /// 闲置天数（自然日之差，向下取整；未来时间按 0 算）。
    static func idleDays(from date: Date, to now: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        return max(0, days)
    }
}

public struct RetentionVerdict: Equatable, Sendable {
    public var shouldForget: Bool
    public var reason: String

    public init(shouldForget: Bool, reason: String) {
        self.shouldForget = shouldForget
        self.reason = reason
    }
}

// MARK: - 可解释

/// 「为什么记了它 / 为什么它被忘了」（验收③）。
///
/// 与 P5「可复核」同源：每条记忆都要能被复述出来路，而不是"客户端就是这么记的"。
public enum MemoryExplanation {

    public static func describe(
        memory: QueryMemory.Memory,
        kind: MemoryKind,
        verdict: RetentionVerdict
    ) -> [String] {
        let stats = MemoryStats(memory: memory)
        let stamp = Self.stamp(memory.lastExecutedAt)
        return [
            "聚类依据（粗指纹）：\(memory.fingerprint)",
            "来源：连接 \(stats.connections.isEmpty ? "（未知）" : stats.connections.joined(separator: " / "))"
                + " · 跨 \(stats.dayCount) 天 · 累计执行 \(stats.runCount) 次"
                + " · 变体 \(stats.variantCount) 条 · 最近执行 \(stamp)",
            "最近原文：\(memory.latestSQL.replacingOccurrences(of: "\n", with: " "))",
            (verdict.shouldForget ? "为什么它被忘了：" : "为什么记了它：") + verdict.reason
        ]
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 环境层 / 通用层

/// 记忆分层（验收④）。
public enum MemoryLayer: String, CaseIterable, Sendable {
    /// 环境层：库表名、数据分布、"这条在哪跑的"。**严格按连接隔离** —— 每个登录用户各自的记忆。
    case environment
    /// 通用层：方言写法、命名习惯、改写经验。可跨连接，但**不得携带具体库表名与数据值**。
    case general
}

/// 通用层提升与**脱敏闸**。
///
/// 通用化做两件事：**用户标识符** → `‹标识符›`、**字面量** → `?`；SQL 关键字原样保留
/// （关键字才是"方言写法"本身，替换掉就没意义了）。
/// 随后 `check` 逐个子串确认通用写法里**不含**原语句的任何标识符原词或字面量取值。
public enum MemoryPromotion {

    public struct Verdict: Equatable, Sendable {
        public var isAllowed: Bool
        /// 命中的泄漏词（空 = 通过）。
        public var leakedTerms: [String]
        public var reason: String
    }

    /// 通用化。返回 `nil` = 这条语句**不适合提升**（没有可用的标识符信息等）。
    public static func generalize(sql: String, dialect: SQLDialect) -> String? {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let keywords = vocabulary(of: dialect)
        var result = ""
        var index = trimmed.startIndex

        while index < trimmed.endIndex {
            let character = trimmed[index]

            // 字面量 → `?`（沿用与记忆层同一套切分，避免两处判据不一致）
            if let range = RoutineCandidate.literalRanges(in: trimmed).first(where: { $0.lowerBound == index }) {
                result += "?"
                index = range.upperBound
                continue
            }

            // 标识符：字母 / 下划线开头，吃掉后续字母数字下划线
            if character.isLetter || character == "_" {
                var cursor = index
                while cursor < trimmed.endIndex {
                    let current = trimmed[cursor]
                    guard current.isLetter || current.isNumber || current == "_" else { break }
                    cursor = trimmed.index(after: cursor)
                }
                let token = String(trimmed[index..<cursor])
                result += keywords.contains(token.uppercased()) ? token : placeholder
                index = cursor
                continue
            }

            result.append(character)
            index = trimmed.index(after: index)
        }
        return result
    }

    public static let placeholder = "‹标识符›"

    /// 保留词表 = 关键字 + **内置函数**。
    ///
    /// 内置函数要留：通用层存的是"方言写法"（`count(*)` / `coalesce(...)` 这类习惯），
    /// 把它们也替换成占位符，通用层就只剩下骨架、失去了它存在的意义。
    static func vocabulary(of dialect: SQLDialect) -> Set<String> {
        Set((dialect.keywords + dialect.builtinFunctions).map { $0.uppercased() })
    }

    /// **脱敏闸**：通用写法里若仍出现原语句的标识符原词或字面量取值 → 拒绝提升。
    public static func check(
        original: String,
        generalized: String,
        dialect: SQLDialect
    ) -> Verdict {
        let keywords = vocabulary(of: dialect)
        let haystack = generalized.lowercased()
        var leaked: [String] = []

        for identifier in identifiers(in: original, keywords: keywords) {
            if haystack.contains(identifier.lowercased()) { leaked.append(identifier) }
        }
        for literal in literalValues(in: original) {
            // 太短的取值（如 `1`）会在结构里偶然出现，不构成"携带了数据值"；
            // 但被替换成 `?` 的位置不会保留取值，所以这里只查长度 ≥ 2 的。
            guard literal.count >= 2 else { continue }
            if haystack.contains(literal.lowercased()) { leaked.append(literal) }
        }

        let unique = Array(Set(leaked)).sorted()
        return Verdict(
            isAllowed: unique.isEmpty,
            leakedTerms: unique,
            reason: unique.isEmpty
                ? "通过：通用写法里不含任何原标识符或数据值"
                : "拒绝：通用写法里仍带着 \(unique.joined(separator: "、"))"
        )
    }

    /// 原语句里的**用户标识符**（关键字不算）。
    public static func identifiers(in sql: String, keywords: Set<String>) -> [String] {
        var result: [String] = []
        var index = sql.startIndex
        while index < sql.endIndex {
            let character = sql[index]
            if character.isLetter || character == "_" {
                var cursor = index
                while cursor < sql.endIndex {
                    let current = sql[cursor]
                    guard current.isLetter || current.isNumber || current == "_" else { break }
                    cursor = sql.index(after: cursor)
                }
                let token = String(sql[index..<cursor])
                if !keywords.contains(token.uppercased()) { result.append(token) }
                index = cursor
                continue
            }
            index = sql.index(after: index)
        }
        return result
    }

    /// 原语句里的字面量取值（去掉字符串两端的引号）。
    public static func literalValues(in sql: String) -> [String] {
        RoutineCandidate.literalRanges(in: sql).map { range in
            var text = String(sql[range])
            if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 {
                text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            return text
        }
    }
}

// MARK: - 「本次执行不记录」

/// 归档策略（FR-AI-15 的「本次执行不记录」）。
///
/// 为什么做成显式的策略对象而不是一个散落的 `if`：这条开关会影响**用户对自己数据的信任**
/// （"我说了不记，它就不该记"），所以判定要能被单测钉住，而不是埋在归档调用点里。
public struct MemoryRecordingPolicy: Equatable, Sendable {
    /// 归档功能本身是否开启。
    public var isArchiveEnabled: Bool
    /// 本次执行是否被用户要求不记录（会话级开关）。
    public var suppressesCurrentRun: Bool

    public init(isArchiveEnabled: Bool, suppressesCurrentRun: Bool = false) {
        self.isArchiveEnabled = isArchiveEnabled
        self.suppressesCurrentRun = suppressesCurrentRun
    }

    public var shouldRecord: Bool { isArchiveEnabled && !suppressesCurrentRun }

    public var reason: String {
        if !isArchiveEnabled { return "归档功能未开启" }
        if suppressesCurrentRun { return "本次执行已选择不记录" }
        return "正常记录"
    }
}
