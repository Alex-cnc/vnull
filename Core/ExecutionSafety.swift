import Foundation

/// 手动执行 SQL 前的安全检查策略（FR-EXEC-16「Safe Mode」）。
public struct ExecutionSafetyPolicy: Equatable, Sendable {
    /// Safe Mode 总开关。关闭后一切照旧（验收要点允许「可跳过」）。
    public var isEnabled: Bool
    /// 是否连普通写操作（带条件的 UPDATE / DELETE、INSERT 等）也要确认。
    /// 默认只确认**高危**语句 —— 凡事都弹窗会让人养成闭眼点「继续」的习惯。
    public var confirmAllWrites: Bool

    public init(isEnabled: Bool = true, confirmAllWrites: Bool = false) {
        self.isEnabled = isEnabled
        self.confirmAllWrites = confirmAllWrites
    }

    /// 默认：开启，只确认高危语句。
    public static let `default` = ExecutionSafetyPolicy()
}

/// 高危语句保护（FR-EXEC-16）。
///
/// 纯客户端静态判定：不连库、不发请求，只对**将要执行的那几条语句**做词法分析。
/// 判定逻辑完全复用 `AgentGuardrail` —— 同一套词法扫描既服务于智能体护栏，
/// 也服务于「人手敲的 SQL」，避免两处规则各自演化、互相矛盾。
///
/// 与验收要点的对应：
/// - 「对不带 `WHERE` 的 `UPDATE` / `DELETE`，以及 `DROP` / `TRUNCATE` 执行前二次确认」→
///   `updateWithoutWhere` / `deleteWithoutWhere` / `dropStatement` / `truncateStatement` 四类发现；
/// - 「可跳过」→ `policy.isEnabled = false` 直接放行；
/// - 「只读连接或生产标签连接下强制确认」→ 依赖 FR-CONN-16 / FR-CONN-17（连接颜色标签与只读连接），
///   这两条尚未实现，故当前由 `policy.isEnabled` 全局开关承担；联动留待那两条落地。
public enum ExecutionSafety {

    /// 检查结论。
    public enum Decision: Equatable, Sendable {
        /// 可以直接执行。
        case allow
        /// 需要用户二次确认。
        case needsConfirmation(reasons: [String], findings: [AgentGuardFinding], statements: [String])

        public var isAllowed: Bool {
            if case .allow = self { return true }
            return false
        }

        /// 弹窗正文：逐条说明风险，并列出涉事语句。
        public var message: String {
            switch self {
            case .allow:
                return ""
            case .needsConfirmation(let reasons, _, let statements):
                var lines = reasons
                if !statements.isEmpty {
                    lines.append("")
                    lines.append(contentsOf: statements.map { "· " + ExecutionSafety.oneLine($0) })
                }
                return lines.joined(separator: "\n")
            }
        }
    }

    /// 检查一整段 SQL（内部按语句拆分后逐条判定）。
    public static func check(
        sql: String,
        databaseType: DatabaseType = .postgresql,
        policy: ExecutionSafetyPolicy = .default
    ) -> Decision {
        guard policy.isEnabled else { return .allow }

        let statements = StatementSplitter(databaseType: databaseType)
            .split(sql)
            .map(\.sql)
        return check(statements: statements, databaseType: databaseType, policy: policy)
    }

    /// 检查一组**将要执行**的语句（配合运行范围控制 FR-EXEC-14 使用）。
    public static func check(
        statements: [String],
        databaseType: DatabaseType = .postgresql,
        policy: ExecutionSafetyPolicy = .default
    ) -> Decision {
        guard policy.isEnabled else { return .allow }
        guard !statements.isEmpty else { return .allow }

        var findings: [AgentGuardFinding] = []
        var offenders: [String] = []
        var hasWrite = false

        for statement in statements {
            let assessment = AgentGuardrail.evaluate(
                sql: statement,
                databaseType: databaseType,
                policy: AgentGuardPolicy(readOnly: false, requireApprovalForHighRisk: true)
            )

            for item in assessment.statements {
                if item.kind.changesDataOrSchema { hasWrite = true }
                guard !item.findings.isEmpty else { continue }
                findings.append(contentsOf: item.findings)
                offenders.append(statement)
            }
            findings.append(contentsOf: assessment.documentFindings)
        }

        let unique = dedupe(findings)

        if !unique.isEmpty {
            return .needsConfirmation(
                reasons: unique.map(\.message),
                findings: unique,
                statements: dedupeStrings(offenders)
            )
        }

        // 普通写操作：仅在用户主动要求「每次写入都确认」时才拦一下。
        if policy.confirmAllWrites, hasWrite {
            return .needsConfirmation(
                reasons: ["这条语句会修改数据或结构。"],
                findings: [],
                statements: dedupeStrings(statements)
            )
        }

        return .allow
    }

    /// 按需取「将被执行的部分」：整篇 / 选中片段 / 光标所在语句（FR-EXEC-14 也用同一套判定）。
    public static func riskSummary(for findings: [AgentGuardFinding], language: AppLanguage) -> String {
        findings.map { $0.message }.joined(separator: " ")
    }

    /// 压成单行，便于弹窗里列语句。
    static func oneLine(_ sql: String, limit: Int = 120) -> String {
        let collapsed = sql
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    static func dedupe(_ findings: [AgentGuardFinding]) -> [AgentGuardFinding] {
        var seen: Set<AgentGuardFinding> = []
        return findings.filter { seen.insert($0).inserted }
    }

    static func dedupeStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
