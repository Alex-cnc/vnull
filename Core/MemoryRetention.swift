import Foundation

/// 记忆的生命周期**执行者**（FR-AI-15）。
///
/// 存在的理由：`RetentionPolicy.evaluate` 早就给出了"该不该忘"的判定，但**没有执行者** ——
/// 判定只被打印在命令输出里，谁也不会照着它动手。判定与执行分家时，
/// "按类型分生命周期"就只是一句好看的话。
///
/// 三条纪律（与前几轮一致）：
/// 1. **计划与执行分开**：`build` 是纯函数（给定记忆与策略 → 该忘哪些），执行由调用方做；
/// 2. **默认不删**：调用方必须先拿计划、打印给人看，显式确认后才动归档；
/// 3. **分类要说出理由**：谁是"排障"谁是"例行"是**推断**（归档里没有类别字段），
///    所以每条都带 `classificationReason`，用户看到不对可以直接改用显式删除。
public extension MemoryGovernance {

    /// 一条记忆的分类结果。
    public struct Classification: Equatable, Sendable {
        public var kind: MemoryKind
        /// 为什么归到这一类（带实际数字；用户据此判断推断对不对）。
        public var reason: String

        public init(kind: MemoryKind, reason: String) {
            self.kind = kind
            self.reason = reason
        }
    }

    /// 归档里**没有**"这是例行还是排障"的字段，只能按可观测的行为推断。
    ///
    /// 判据（`RetentionPolicy.standard` 的阈值）：跨天出现 **或** 累计执行达到低使用阈值 → **例行**；
    /// 只在一天里跑过一两次 → **排障**（这一档才可能被时间遗忘）。
    ///
    /// 已知边界（写出来而不是留给读者发现）：这是**推断**。一个"一年只用一次但很关键"的巡检脚本
    /// 会被归成排障；真要留住它，用 `memory --delete` 之外的手段 —— 即**显式指定类别**（CLI `--kind`）
    /// 或在界面上把它标成钉住。因此执行者删之前一定要把分类理由打出来。
    public static func classify(
        memory: QueryMemory.Memory,
        policy: RetentionPolicy = .standard
    ) -> Classification {
        let stats = MemoryStats(memory: memory)
        let crossDay = stats.dayCount >= 2
        let usedEnough = stats.runCount >= policy.lowUseRunCount
        if crossDay || usedEnough {
            let why = crossDay
                ? "跨 \(stats.dayCount) 天出现过（≥ 2 天）"
                : "累计执行 \(stats.runCount) 次（≥ \(policy.lowUseRunCount)）"
            return Classification(kind: .routine, reason: "按行为推断为例行：\(why)")
        }
        return Classification(
            kind: .troubleshooting,
            reason: "按行为推断为排障：只在 \(stats.dayCount) 天里出现过、累计执行 \(stats.runCount) 次"
                + "（既没跨天、也没到 \(policy.lowUseRunCount) 次）"
        )
    }

    /// 生命周期计划：哪些该忘、哪些留着，每条都带分类理由与判定理由。
    public struct Plan: Equatable, Sendable {
        public struct Item: Equatable, Sendable {
            public var fingerprint: String
            public var sql: String
            public var kind: MemoryKind
            public var classificationReason: String
            public var verdict: RetentionVerdict
            public var runCount: Int
            public var dayCount: Int
            public var lastExecutedAt: Date

            public var willBeDeleted: Bool { verdict.shouldForget }
        }

        public var policy: RetentionPolicy
        public var generatedAt: Date
        /// 将被删除的（`verdict.shouldForget == true`）。
        public var forgettable: [Item]
        /// 保留的，附带理由。
        public var retained: [Item]

        public var isEmpty: Bool { forgettable.isEmpty && retained.isEmpty }

        /// 可读的一整段（CLI 直接打印；界面按行渲染）。
        public func describe() -> [String] {
            var lines: [String] = []
            lines.append(
                "生命周期计划（策略：排障类闲置 ≥ \(policy.idleDays) 天且累计执行 < \(policy.lowUseRunCount) 次才遗忘）"
            )
            lines.append("将被删除 \(forgettable.count) 条 / 保留 \(retained.count) 条")
            for item in forgettable {
                lines.append("  ✗ \(item.fingerprint) · \(item.kind.label) · \(item.verdict.reason)")
                lines.append("      原文：\(item.sql.replacingOccurrences(of: "\n", with: " "))")
            }
            for item in retained {
                lines.append("  ✓ \(item.fingerprint) · \(item.kind.label) · \(item.verdict.reason)")
            }
            return lines
        }
    }

    /// 生成计划（**纯函数**：不读盘、不写盘、不删任何东西）。
    public static func plan(
        memories: [QueryMemory.Memory],
        policy: RetentionPolicy = .standard,
        now: Date = Date()
    ) -> Plan {
        var forgettable: [Plan.Item] = []
        var retained: [Plan.Item] = []

        for memory in memories.sorted(by: { $0.fingerprint < $1.fingerprint }) {
            let classification = classify(memory: memory, policy: policy)
            let verdict = policy.evaluate(
                kind: classification.kind,
                stats: MemoryStats(memory: memory),
                now: now
            )
            let item = Plan.Item(
                fingerprint: memory.fingerprint,
                sql: memory.latestSQL,
                kind: classification.kind,
                classificationReason: classification.reason,
                verdict: verdict,
                runCount: memory.runCount,
                dayCount: memory.days.count,
                lastExecutedAt: memory.lastExecutedAt
            )
            if verdict.shouldForget {
                forgettable.append(item)
            } else {
                retained.append(item)
            }
        }

        return Plan(policy: policy, generatedAt: now, forgettable: forgettable, retained: retained)
    }
}
