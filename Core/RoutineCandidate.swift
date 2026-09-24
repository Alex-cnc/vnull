import Foundation

/// 参数化与技能候选（FR-AI-14 / 能力规划 §4.4 的 S3）。
///
/// 消费顺序里它排在补全之后（见 `QueryMemory` 类型注释「补全 > 参数化 > 主动建议」）：
/// 补全回答"你现在要写什么"，这一层回答"你反复在做什么" —— 后者**只产建议**。
///
/// 四条不能松的口径：
/// 1. **只建议，不落盘**：`evaluate` 是**纯函数** —— 不写文件、不建任务、不改归档。
///    误判代价不对称：把例行当排障只是没省事，把排障当例行去定时是危险的。
///    所以这里连"顺手建个任务"的便利都不提供，人工决定另走 `MemoryDecisions`（那也是人显式触发的）。
/// 2. **两级指纹不混用**：聚类与频次用**粗指纹**（结构骨架），"同一条"计数用**精指纹**（原文）。
///    拿粗指纹数"有几条不同的原文"会把不同取值算成一条，拿精指纹聚合会把同一查询碎成几千条。
/// 3. **保守侧**：四条判据**全部**满足才算候选；未满足的每一条都给出"实际值 vs 阈值"的**机器可读**原因，
///    而不是"看起来不像例行就不算"这种主观规则 —— 主观规则没法被单测和脚本逐条钉住。
/// 4. **判据本身就是排障脚本的挡板**：一次性排障（单日、单时刻、多值）不需要额外特判，
///    它天然过不了「跨越天数 / 跨天频次」—— 多一条"像排障脚本就排除"的规则只会多一处会漂移的猜法。
public enum RoutineCandidate {

    // MARK: - 参数模板

    /// 一组「只有字面量不同」的原文对齐出来的参数模板。
    ///
    /// 为什么存**结构**（代码片段 + 每个位置的字面量/槽位）而不只存渲染好的模板字符串：
    /// 人工「保留字面量」决定要在**评估时**把某个槽位改回字面量，光有一串 `?` 改不回去
    /// （用户自己写的 `?` 占位符与槽位长得一模一样）。
    public struct Parameterization: Equatable, Sendable {
        /// 代码片段，逐字保留；段数恒为「位置数 + 1」（首尾都算段）。
        public var codes: [String]
        /// 每个位置：固定字面量（所有原文在这里取值相同）或 `nil`（槽位 —— 取值有差异）。
        public var literals: [String?]
        /// 槽位（按出现顺序）的取值样例：去重、排序、**有界**（默认最多 5 个）。
        public var samples: [[String]]

        public init(codes: [String], literals: [String?], samples: [[String]]) {
            self.codes = codes
            self.literals = literals
            self.samples = samples
        }

        /// 槽位数量。
        public var slotCount: Int { literals.reduce(0) { $0 + ($1 == nil ? 1 : 0) } }

        /// 渲染模板：槽位默认是 `?`；被人工标记为「保留字面量」的取值改回它自己。
        ///
        /// 口径（与 `MemoryDecisions` 的注释一致）：**只影响渲染**，不改聚类、不改频次。
        /// 一个槽位里若有多个被保留的字面量，取排序后的第一个 —— 排序保证同一输入两次渲染逐字一致。
        public func template(keepingLiterals: [String] = []) -> String {
            var result = ""
            var slotOrdinal = 0
            for position in literals.indices {
                if position < codes.count { result += codes[position] }
                if let fixed = literals[position] {
                    result += fixed
                } else {
                    let values = slotOrdinal < samples.count ? samples[slotOrdinal] : []
                    if let kept = values.first(where: { keepingLiterals.contains($0) }) {
                        result += kept
                    } else {
                        result += "?"
                    }
                    slotOrdinal += 1
                }
            }
            if let tail = codes.last { result += tail }
            return result
        }
    }

    /// 把一组原文按**字面量序列**对齐成参数模板。
    ///
    /// 规则（照需求原文，不放宽）：
    /// - 按字面量序列对齐；字面量取值有差异的位置 → 槽位（`?`），其余**原样保留**；
    /// - 每个槽位给出取值样例（去重、有界）。
    ///
    /// 返回 `nil` = **结构不一致**：字面量个数不同，或字面量之间的**代码片段不完全相同**。
    /// 这道 `nil` 就是防粗指纹碰撞的闸 —— 粗指纹把 `SELECT …` 与 `select …` 归成一个骨架
    /// （它整体小写化），但两者不可能由同一个模板逐字还原，必须在这里被挡下。
    ///
    /// 输入先 `Set` 去重再 `sorted()`：结果与调用方给的顺序、以及集合遍历顺序**无关**，
    /// 否则"同一目录两次运行结果一致"这条会被一个不稳定的遍历顺序打破。
    public static func align(_ sqls: [String], maximumSamples: Int = 5) -> Parameterization? {
        let variants = Array(Set(sqls)).sorted()
        guard let first = variants.first else { return nil }

        let firstParts = splitLiterals(first)
        var valuesByPosition: [[String]] = firstParts.literals.map { [$0] }

        for variant in variants.dropFirst() {
            let parts = splitLiterals(variant)
            // 位置数不同 = 结构不同；代码片段不同 = 大小写/空白/标点不同，逐字还原不可能。
            guard parts.literals.count == firstParts.literals.count,
                  parts.codes == firstParts.codes else {
                return nil
            }
            for position in parts.literals.indices {
                valuesByPosition[position].append(parts.literals[position])
            }
        }

        var literals: [String?] = []
        var samples: [[String]] = []
        for values in valuesByPosition {
            let unique = Set(values)
            if unique.count <= 1 {
                literals.append(unique.first)
            } else {
                literals.append(nil)
                samples.append(Array(unique.sorted().prefix(max(0, maximumSamples))))
            }
        }
        return Parameterization(codes: firstParts.codes, literals: literals, samples: samples)
    }

    // MARK: - 字面量切分

    /// 字面量在原文里的位置（升序、互不相交）。
    ///
    /// 判据必须与 `QueryMemory.coarseFingerprint` 归一化的东西**完全一致** ——
    /// 否则会出现"粗指纹认为是参数、这里没当参数"的错位：那样两条原文永远对不齐，
    /// 而原因却是切分规则不同（最难查的一类 bug）。所以这里照抄粗指纹的分支顺序：
    /// 单引号字符串（含 `''` 转义）与**以数字开头的独立词**是字面量；
    /// 引号标识符（`"t1"`）与含数字的标识符（`orders1`）**整词保留、不是字面量**。
    public static func literalRanges(in sql: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = sql.startIndex

        while index < sql.endIndex {
            let character = sql[index]

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
                ranges.append(index..<cursor)
                index = cursor
                continue
            }

            // 引号标识符：整词原样保留（与粗指纹一致 —— `"t1"` 里的数字不是参数）。
            if character == "\"" || character == "`" {
                let quote = character
                var cursor = sql.index(after: index)
                while cursor < sql.endIndex {
                    let current = sql[cursor]
                    cursor = sql.index(after: cursor)
                    if current == quote {
                        if cursor < sql.endIndex, sql[cursor] == quote {
                            cursor = sql.index(after: cursor)
                            continue
                        }
                        break
                    }
                }
                index = cursor
                continue
            }

            // 标识符：连同其中的数字整体跳过（不是字面量）。
            if character.isLetter || character == "_" || character == "$" {
                var cursor = index
                while cursor < sql.endIndex {
                    let current = sql[cursor]
                    guard current.isLetter || current.isNumber || current == "_" || current == "$" else { break }
                    cursor = sql.index(after: cursor)
                }
                index = cursor
                continue
            }

            if character.isNumber {
                var cursor = index
                while cursor < sql.endIndex, sql[cursor].isNumber || sql[cursor] == "." {
                    cursor = sql.index(after: cursor)
                }
                ranges.append(index..<cursor)
                index = cursor
                continue
            }

            index = sql.index(after: index)
        }

        return ranges
    }

    /// 把原文切成「代码片段 / 字面量」交替序列（`codes.count == literals.count + 1`）。
    static func splitLiterals(_ sql: String) -> (codes: [String], literals: [String]) {
        var codes: [String] = []
        var literals: [String] = []
        var cursor = sql.startIndex
        for span in literalRanges(in: sql) {
            codes.append(String(sql[cursor..<span.lowerBound]))
            literals.append(String(sql[span]))
            cursor = span.upperBound
        }
        codes.append(String(sql[cursor...]))
        return (codes, literals)
    }

    // MARK: - 判据阈值

    /// 四条判据的阈值。写成参数是为了单测能逐条挪动阈值、证明每条判据**单独**在起作用。
    public struct Thresholds: Equatable, Sendable {
        public var minimumRunCount: Int
        public var minimumDayCount: Int
        public var windowHours: Int
        public var minimumWindowRatio: Double
        public var minimumVariantCount: Int
        public var maximumSlotSamples: Int

        public init(
            minimumRunCount: Int = 5,
            minimumDayCount: Int = 3,
            windowHours: Int = 3,
            minimumWindowRatio: Double = 0.6,
            minimumVariantCount: Int = 2,
            maximumSlotSamples: Int = 5
        ) {
            self.minimumRunCount = minimumRunCount
            self.minimumDayCount = minimumDayCount
            self.windowHours = windowHours
            self.minimumWindowRatio = minimumWindowRatio
            self.minimumVariantCount = minimumVariantCount
            self.maximumSlotSamples = maximumSlotSamples
        }

        public static let standard = Thresholds()
    }

    // MARK: - 时刻集中度

    /// 一天内执行时刻的集中程度。
    public struct Concentration: Equatable, Sendable {
        /// 最佳窗口的起点小时（0..23）。
        public var startHour: Int
        /// 窗口内的执行次数。
        public var windowRunCount: Int
        /// 总执行次数（直方图之和）。
        public var totalRunCount: Int
        public var windowHours: Int

        public init(startHour: Int, windowRunCount: Int, totalRunCount: Int, windowHours: Int) {
            self.startHour = startHour
            self.windowRunCount = windowRunCount
            self.totalRunCount = totalRunCount
            self.windowHours = windowHours
        }

        /// 窗口内执行占比（0…1；总次数为 0 时按 0 算 —— 没有证据就不算集中）。
        public var ratio: Double {
            guard totalRunCount > 0 else { return 0 }
            return Double(windowRunCount) / Double(totalRunCount)
        }

        /// 百分比整数（报告用；取整保证输出逐字稳定）。
        public var percent: Int { Int((ratio * 100).rounded()) }
    }

    /// 最佳滚动窗口。
    ///
    /// 窗口**跨午夜**（23 点起的窗口含 23 / 0 / 1 点）：每天 23:40 跑的脚本与 00:20 跑的
    /// 在钟面上是挨着的，不许跨界会把它俩拆成两个"都不集中"的时刻。
    ///
    /// 并列时取**最小起点**（`>` 而非 `>=`）：并列是常态（数据稀疏时很多窗口都是 0），
    /// 不定死一个规则就等于让报告每次不一样。
    public static func concentration(histogram: [Int], windowHours: Int = 3) -> Concentration {
        let span = max(1, windowHours)
        let total = histogram.reduce(0, +)
        var bestStart = 0
        var bestCount = -1
        for start in 0..<24 {
            var sum = 0
            for offset in 0..<span {
                let index = (start + offset) % 24
                if index < histogram.count { sum += histogram[index] }
            }
            if sum > bestCount {
                bestCount = sum
                bestStart = start
            }
        }
        return Concentration(
            startHour: bestStart,
            windowRunCount: max(0, bestCount),
            totalRunCount: total,
            windowHours: span
        )
    }

    // MARK: - 候选与评估

    /// 一条升格建议。
    public struct Candidate: Equatable, Sendable {
        /// 该建议所属的粗指纹（人工否决 / 保留字面量都以它为键）。
        public var fingerprint: String
        /// 渲染后的模板：槽位 `?`；被人工标记「保留字面量」的位置已改回字面量。
        public var template: String
        /// 槽位取值样例（按槽位顺序、去重排序、最多 5 个）。
        public var slotSamples: [[String]]
        public var runCount: Int
        public var dayCount: Int
        public var concentration: Concentration
        public var variantCount: Int
        public var connections: Set<String>
        public var lastExecutedAt: Date
    }

    /// 一条记忆的评估结果（候选与非候选都有 —— 非候选必须能说清"差在哪"）。
    public struct Assessment: Equatable, Sendable {
        public var fingerprint: String
        public var isCandidate: Bool
        /// 未达标原因（机器可读：判据名 + 实际值 vs 阈值）；候选为空数组。
        public var reasons: [String]
        public var runCount: Int
        public var dayCount: Int
        public var concentration: Concentration
        public var variantCount: Int
        public var connections: Set<String>
        public var candidate: Candidate?
    }

    /// 一次评估的完整结果。
    public struct Report: Equatable, Sendable {
        /// 候选（按执行次数降序、再按指纹升序）。
        public var candidates: [Candidate]
        /// 未被人工否决的记忆的评估结果（含候选本身），排序同上。
        public var assessments: [Assessment]
        /// 被人工否决、因此完全不参与评估的指纹（排序）。
        public var vetoedFingerprints: [String]

        public var isEmpty: Bool { candidates.isEmpty }
    }

    // MARK: - 评估（纯函数）

    /// 从记忆索引评估例行候选。**纯函数：不写任何文件、不建任何任务。**
    ///
    /// 四条判据全部满足才算候选：
    /// 1. 跨天频次 `runCount >= 5`
    /// 2. 跨越天数 `days.count >= 3`
    /// 3. 时刻集中度：某个 3 小时滚动窗口内的执行占比 >= 60%
    /// 4. 只改参数：≥2 条不同原文（精指纹），且都能被同一个模板逐字还原
    ///
    /// 被否决的指纹直接不进评估（长期生效，见 `MemoryDecisions`）。
    public static func evaluate(
        index: QueryMemory.Index,
        decisions: MemoryDecisions = MemoryDecisions(),
        thresholds: Thresholds = .standard
    ) -> Report {
        var candidates: [Candidate] = []
        var assessments: [Assessment] = []
        var vetoed: [String] = []

        for memory in index.memories {
            if decisions.isVetoed(memory.fingerprint) {
                vetoed.append(memory.fingerprint)
                continue
            }

            let concentration = concentration(
                histogram: memory.hourHistogram,
                windowHours: thresholds.windowHours
            )

            var reasons: [String] = []
            if memory.runCount < thresholds.minimumRunCount {
                reasons.append("跨天频次 \(memory.runCount) < \(thresholds.minimumRunCount)")
            }
            if memory.days.count < thresholds.minimumDayCount {
                reasons.append("跨越天数 \(memory.days.count) < \(thresholds.minimumDayCount)")
            }
            if concentration.ratio < thresholds.minimumWindowRatio {
                reasons.append(
                    "时刻集中度 \(concentration.percent)% < \(Int((thresholds.minimumWindowRatio * 100).rounded()))%"
                        + "（最佳 \(thresholds.windowHours) 小时窗口自 \(concentration.startHour) 点起）"
                )
            }
            if memory.variantCount < thresholds.minimumVariantCount {
                // 单条原文重复执行 N 次**不算**满足本条 —— 那不是参数化，只是重复。
                reasons.append("只改参数 变体 \(memory.variantCount) 条 < \(thresholds.minimumVariantCount) 条")
            } else if memory.parameterization == nil {
                reasons.append("只改参数 模板不一致（粗指纹碰撞：原文结构不同，不能逐字还原）")
            }

            let candidate: Candidate?
            if reasons.isEmpty, let parameterization = memory.parameterization {
                candidate = Candidate(
                    fingerprint: memory.fingerprint,
                    template: parameterization.template(
                        keepingLiterals: decisions.keptLiterals(for: memory.fingerprint)
                    ),
                    slotSamples: parameterization.samples,
                    runCount: memory.runCount,
                    dayCount: memory.days.count,
                    concentration: concentration,
                    variantCount: memory.variantCount,
                    connections: memory.connections,
                    lastExecutedAt: memory.lastExecutedAt
                )
            } else {
                candidate = nil
                if reasons.isEmpty {
                    // 防御性兜底：阈值被调到 `minimumVariantCount <= 1` 时仍可能走到这里，
                    // 不允许出现"不是候选但一条原因都没有"（那样的报告等于没说）。
                    reasons.append("只改参数 拿不到参数模板")
                }
            }

            if let candidate {
                candidates.append(candidate)
            }
            assessments.append(Assessment(
                fingerprint: memory.fingerprint,
                isCandidate: candidate != nil,
                reasons: reasons,
                runCount: memory.runCount,
                dayCount: memory.days.count,
                concentration: concentration,
                variantCount: memory.variantCount,
                connections: memory.connections,
                candidate: candidate
            ))
        }

        // 排序必须确定：同一输入两次运行的输出要逐字一致。
        candidates.sort { lhs, rhs in
            if lhs.runCount != rhs.runCount { return lhs.runCount > rhs.runCount }
            return lhs.fingerprint < rhs.fingerprint
        }
        assessments.sort { lhs, rhs in
            if lhs.runCount != rhs.runCount { return lhs.runCount > rhs.runCount }
            return lhs.fingerprint < rhs.fingerprint
        }
        return Report(
            candidates: candidates,
            assessments: assessments,
            vetoedFingerprints: vetoed.sorted()
        )
    }
}
