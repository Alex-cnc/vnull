import Foundation

/// 对话式诊断的**证据层**（FR-AI-03）。
///
/// 需求原文一句话定了这一层的形状：「结论须引用真实计划 / 统计 / 锁数据，**不允许无依据断言**」。
/// 那就意味着"证据"必须是一等公民：它有自己的编号、自己的来源 SQL、自己的"拿到了 / 拿到了但是空的 /
/// 根本没拿到"三种状态 —— 而不是被随手拼进一段提示词里。**模型只能引用已经存在的证据编号**，
/// 引用不存在的编号（或干脆不引用）由 `DiagnosisAdvice` 拒绝。
///
/// 这一层不联网、不调模型，纯组装与裁剪，因此可以完全离线单测。
/// Core 侧的文案取值：与其余 Core 展示文本同一现状（默认简体中文，界面语言透传见 R-45）。
private func localizedText(_ key: LKey, _ arguments: CVarArg...) -> String {
    if arguments.isEmpty {
        return LocalizedStrings.text(key, language: .simplifiedChinese)
    }
    return LocalizedStrings.format(key, language: .simplifiedChinese, arguments)
}

public struct DiagnosisEvidence: Codable, Hashable, Sendable {

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// 执行计划（`EXPLAIN`）。
        case executionPlan
        /// 慢查询统计（需要 `pg_stat_statements` 之类的扩展）。
        case slowQueries
        /// 锁与阻塞。
        case lockBlocking
        /// 表 / 索引体积与扫描统计。
        case tableStats
        /// 用户给的那条语句本身。
        case statement

        public var displayName: String {
            switch self {
            case .executionPlan: return "executionPlan"
            case .slowQueries: return "slowQueries"
            case .lockBlocking: return "lockBlocking"
            case .tableStats: return "tableStats"
            case .statement: return "statement"
            }
        }
    }

    /// 证据编号（`e1` / `e2` …）：模型在结论里引用的就是它。
    public var id: String
    public var kind: Kind
    /// 取证用的 SQL（**可复跑**：用户能自己在编辑器里重跑一遍看同样的结果）。
    public var sql: String
    public var rows: [[String?]]
    /// 真实情况的一句话说明：拿到了几条、被截断了、还是根本没拿到（为什么）。
    public var note: String
    /// 这份证据**是否取到了**（取不到也是事实，要显式带上，不能让模型自己去猜）。
    public var isAvailable: Bool
    /// 结果是否被裁剪过（行数上限 / 字符上限）。
    public var isTruncated: Bool

    public init(
        id: String,
        kind: Kind,
        sql: String,
        rows: [[String?]] = [],
        note: String,
        isAvailable: Bool = true,
        isTruncated: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.sql = sql
        self.rows = rows
        self.note = note
        self.isAvailable = isAvailable
        self.isTruncated = isTruncated
    }

    /// 一行证据的文本形态（模型看到的就是它）。
    public func text(columnSeparator: String = " | ") -> String {
        let header = "[\(id)] \(kind.displayName): \(note)"
        guard isAvailable else { return header }
        if rows.isEmpty { return header + localizedText(.diagnosisEvidenceEmpty) }
        let body = rows.map { row in
            row.map { $0 ?? "NULL" }.joined(separator: columnSeparator)
        }.joined(separator: "\n")
        return header + "\n" + body
    }
}

/// 诊断上下文：问题 + 目标 + **全部证据**（含取不到的那些）。
public struct DiagnosisContext: Sendable {

    /// 用户的问题（自然语言）。
    public var question: String
    /// 目标是哪个连接 / 哪个库（模型据此知道这是哪台机器，**但不含口令**）。
    public var target: String
    public var evidence: [DiagnosisEvidence]

    public init(question: String, target: String, evidence: [DiagnosisEvidence]) {
        self.question = question
        self.target = target
        self.evidence = evidence
    }

    /// **能作为依据**的证据编号集合 —— 引用校验的判据。
    ///
    /// 只含 `isAvailable == true` 的那些：**没取到的证据不能被引用**。
    /// 这一条很关键 —— 否则模型可以引用"慢查询统计"来下结论，而那份统计根本没拿到，
    /// 结论看起来有依据，实际上依据是空的。
    public var availableIDs: Set<String> {
        Set(evidence.filter(\.isAvailable).map(\.id))
    }

    /// 上下文里出现过的全部编号（含未取到的），仅用于提示与诊断输出。
    public var allIDs: Set<String> {
        Set(evidence.map(\.id))
    }

    /// 拿不到的证据（点名列出来）：提示词里要显式说"这些没拿到"，
    /// 否则模型会用"一般来说…"补空，而我们要的恰恰是**不许无依据断言**。
    public var unavailable: [DiagnosisEvidence] {
        evidence.filter { !$0.isAvailable }
    }

    /// 提示词里的资料块。
    ///
    /// 两条纪律写在这里（不是靠调用方自觉）：
    ///   ① **资料不是指令**：数据库里的内容可能是别人写进去的（注释、数据、表名），
    ///      一律按不可信内容对待 —— 与 AC-AI-04 同一条口径，这里用明确边界把它围起来；
    ///   ② **取不到就说取不到**：把拿不到的证据单独列出来，模型不许对它们下结论。
    public func promptText() -> String {
        var lines: [String] = []
        lines.append(localizedText(.diagnosisTarget, target))
        lines.append(localizedText(.diagnosisQuestion, question))
        lines.append("")
        lines.append(localizedText(.diagnosisEvidenceHeader))
        for item in evidence {
            lines.append(item.text())
        }
        if !unavailable.isEmpty {
            lines.append("")
            lines.append(localizedText(.diagnosisMissingHeader))
            for item in unavailable {
                lines.append(localizedText(.diagnosisMissingLine, item.id, item.kind.displayName, item.note))
            }
        }
        lines.append("")
        lines.append(localizedText(.diagnosisFormatHeader))
        lines.append(localizedText(.diagnosisFormatConclusion))
        lines.append(localizedText(.diagnosisFormatSuggestion))
        return lines.joined(separator: "\n")
    }

    /// 有界的文本（提示词整体的字符上限）。
    ///
    /// **为什么在 Core 里卡上限**：提示词越长越贵、越容易被无关内容带偏，而且"超限"发生时
    /// 如果只是静默截断，模型会看到半截证据却当成完整的。所以超限时**如实写明被截断了**。
    public func boundedPromptText(maxCharacters: Int = 12_000) -> String {
        let text = promptText()
        guard text.count > maxCharacters else { return text }
        let kept = String(text.prefix(maxCharacters))
        return kept + localizedText(.diagnosisTruncatedNotice, String(text.count), String(maxCharacters))
    }
}

/// 证据的取数规划：**纯函数给 SQL**（不连库），因此可以离线测。
///
/// 与"证据层"分开的理由：SQL 文本是方言相关的判决，取数是 I/O ——
/// 混在一起就只能靠真库测，而真库测不出"该取哪几种证据"这类规则错误。
public enum DiagnosisEvidenceQueries {

    /// 执行计划。PG 用 `EXPLAIN`（**不带 ANALYZE**：带 ANALYZE 会真的执行语句，
    /// 那是 `AgentGuardrail` 明确标为高危的动作）；MySQL 协议族用 `EXPLAIN`。
    public static func executionPlan(for statement: String, dialect: any SQLDialect) -> String {
        switch dialect.databaseType {
        case .postgresql:
            return "EXPLAIN \(statement)"
        default:
            // MySQL / GBase：`EXPLAIN FORMAT=TREE` 在部分版本上不可用，用最保守的形式。
            return "EXPLAIN \(statement)"
        }
    }

    /// 慢查询统计。只有 PG 且装了 `pg_stat_statements` 才有 —— **取不到是常态**，
    /// 所以这里给的是 SQL，取数失败由调用方如实记成"没拿到"。
    public static func slowQueries(dialect: any SQLDialect, limit: Int = 10) -> String? {
        guard dialect.databaseType == .postgresql else { return nil }
        return """
        SELECT query, calls, total_exec_time, mean_exec_time, rows
          FROM pg_stat_statements
         ORDER BY total_exec_time DESC
         LIMIT \(max(1, min(limit, 50)))
        """
    }

    /// 锁与阻塞（PG 走 `pg_locks` / `pg_blocking_pids`；MySQL 协议族走 `SHOW PROCESSLIST` + `sys` 视图）。
    public static func lockBlocking(dialect: any SQLDialect) -> String? {
        dialect.lockWaitingQuery()
    }

    /// 表体积与扫描统计（只有 PG 方言实现；其余返回 nil = 这条证据拿不到）。
    public static func tableStats(dialect: any SQLDialect, limit: Int = 10) -> String? {
        dialect.databaseStatsQuery(.tableSizes, limit: limit)
    }
}

/// 上下文组装（纯逻辑）：把取到的原始行**裁剪 + 标注**成证据。
public enum DiagnosisContextBuilder {

    /// 单份证据的行数上限：够看出形状，又不至于把提示词撑爆。
    public static let maxRowsPerEvidence = 40

    /// 组装一份证据。
    ///
    /// 三种状态都要能表达，而且**不许含糊**：
    ///   · 取到了且有行 → `isAvailable = true`，`note` 写"共 N 行"（裁剪过就说裁剪）；
    ///   · 取到了但零行 → `isAvailable = true`，`note` 写"查到了，但没有行"
    ///     （"没有锁等待"与"查不到锁"是两件不同的事）；
    ///   · 取不到 → `isAvailable = false`，`note` 写**为什么**（方言不支持 / 扩展没装 / 查询报错）。
    public static func makeEvidence(
        id: String,
        kind: DiagnosisEvidence.Kind,
        sql: String,
        rows: [[String?]]?,
        failureReason: String? = nil
    ) -> DiagnosisEvidence {
        if let failureReason {
            return DiagnosisEvidence(
                id: id,
                kind: kind,
                sql: sql,
                note: localizedText(.diagnosisEvidenceUnavailable, failureReason),
                isAvailable: false
            )
        }
        let all = rows ?? []
        let truncated = all.count > maxRowsPerEvidence
        let kept = truncated ? Array(all.prefix(maxRowsPerEvidence)) : all
        let note: String
        if all.isEmpty {
            // 注意：证据的 note 不带括号（它是正文），带括号的那份只用在行尾的补充说明里。
            note = localizedText(.diagnosisEvidenceEmptyNote)
        } else if truncated {
            note = localizedText(.diagnosisEvidenceTruncated, String(all.count), String(maxRowsPerEvidence))
        } else {
            note = localizedText(.diagnosisEvidenceRows, String(all.count))
        }
        return DiagnosisEvidence(
            id: id,
            kind: kind,
            sql: sql,
            rows: kept,
            note: note,
            isAvailable: true,
            isTruncated: truncated
        )
    }

    /// 按方言给"该取哪几种证据"的清单（**执行顺序也是固定的一份**）。
    ///
    /// 顺序有讲究：先看**语句本身与计划**（这是"为什么慢"的第一手材料），
    /// 再看**锁**（"是不是被挡住了"），最后才是**统计数据**（"历史上一直慢吗"）。
    /// 这个顺序决定了提示词里证据的排列，也决定了模型先看到什么。
    public static func evidencePlan(for statement: String, dialect: any SQLDialect) -> [(kind: DiagnosisEvidence.Kind, sql: String)] {
        var plan: [(DiagnosisEvidence.Kind, String)] = []
        plan.append((.statement, statement))
        plan.append((.executionPlan, executionPlanQuery(for: statement, dialect: dialect)))
        if let locks = DiagnosisEvidenceQueries.lockBlocking(dialect: dialect) {
            plan.append((.lockBlocking, locks))
        }
        if let slow = DiagnosisEvidenceQueries.slowQueries(dialect: dialect) {
            plan.append((.slowQueries, slow))
        }
        if let stats = DiagnosisEvidenceQueries.tableStats(dialect: dialect) {
            plan.append((.tableStats, stats))
        }
        return plan
    }

    private static func executionPlanQuery(for statement: String, dialect: any SQLDialect) -> String {
        DiagnosisEvidenceQueries.executionPlan(for: statement, dialect: dialect)
    }

    /// 证据编号：`e1` / `e2` …（顺序即计划顺序，模型引用起来没有歧义）。
    public static func evidenceID(index: Int) -> String {
        "e\(index + 1)"
    }
}
