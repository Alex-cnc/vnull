import Foundation

/// DBA 维护任务编排（FR-AI-04）。
///
/// 需求原文两句话定了这一层的形状：「由自然语言描述生成并执行维护任务（备份 / 恢复、`VACUUM` /
/// `ANALYZE` / `REINDEX`、索引建议、授权调整）」+「**每个写操作 / DDL 均需审批**；任务可预览、
/// 可编辑、可拒绝；**高开销操作限流**」。
///
/// 所以这里不做"一句话直接跑一串命令"，而是三件可单测的事：
///   ① **解析**：把（模型给的）计划文本按我们自己声明的行格式拆成任务；
///   ② **审阅**（`review`）：逐条定"能不能跑、要不要审批" —— 只读连接直接拒、高危/写操作要审批、
///      **高开销任务限流**、**外部程序类任务在沙箱构建下不可执行**（备份恢复走 `pg_dump`，见 R-18）；
///   ③ **状态机**：待批 → 已批 / 已拒 → 已执行 / 失败。**没有"跳过审批直接执行"的路径** ——
///      执行入口只收"已批准"的任务，这是类型上的约束，不是纪律口号。
public enum MaintenanceTaskKind: String, Codable, Hashable, CaseIterable, Sendable {
    case backup
    case restore
    case vacuum
    case analyze
    case reindex
    case indexSuggestion
    case grant
    case custom

    public var displayName: String {
        switch self {
        case .backup: return "backup"
        case .restore: return "restore"
        case .vacuum: return "vacuum"
        case .analyze: return "analyze"
        case .reindex: return "reindex"
        case .indexSuggestion: return "indexSuggestion"
        case .grant: return "grant"
        case .custom: return "custom"
        }
    }

    /// **在进程内执行**（发 SQL）的类别。备份 / 恢复走外部程序（`pg_dump` / `pg_restore`），
    /// 在沙箱构建下起不来 —— 这条差异必须显式表达，不能让用户点了"执行"才发现。
    public var runsInProcess: Bool {
        switch self {
        case .backup, .restore: return false
        default: return true
        }
    }

    /// 默认是否算高开销（限流判据）。`REINDEX` / `VACUUM FULL` 会长时间持锁或重写文件，属高开销。
    public var isHighCostByDefault: Bool {
        switch self {
        case .reindex, .backup, .restore: return true
        case .vacuum, .analyze, .indexSuggestion, .grant, .custom: return false
        }
    }

    /// 审批要求：写操作 / DDL 一律要批（需求原文）。索引建议本身不改库（只给语句），不用批。
    public var requiresApprovalByDefault: Bool {
        switch self {
        case .indexSuggestion: return false
        default: return true
        }
    }
}

/// 一条维护任务。
public struct MaintenanceTask: Identifiable, Equatable, Sendable {

    public enum State: Equatable, Sendable {
        case pending
        /// 已批准（可以执行）。
        case approved
        /// 被用户拒绝（**保留在计划里**：拒绝了什么要看得见）。
        case rejected
        case executed
        case failed(reason: String)

        public var isApproved: Bool { self == .approved }
        public var isFinished: Bool {
            switch self {
            case .executed, .failed, .rejected: return true
            case .pending, .approved: return false
            }
        }
    }

    public let id: String
    public var kind: MaintenanceTaskKind
    /// 人话描述（模型给的那句）。
    public var summary: String
    /// 进程内执行的语句（`runsInProcess` 为真时才有）。
    public var sql: String?
    /// 外部程序命令行（备份 / 恢复）。
    public var command: String?
    public var risk: AgentRiskLevel
    public var isHighCost: Bool
    public var requiresApproval: Bool
    public var state: State = .pending
    /// 审阅给出的说明（为什么需要审批 / 为什么被限流 / 为什么不建议）。
    public var reviewNotes: [String] = []

    public init(
        id: String,
        kind: MaintenanceTaskKind,
        summary: String,
        sql: String? = nil,
        command: String? = nil,
        risk: AgentRiskLevel = .low,
        isHighCost: Bool? = nil,
        requiresApproval: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.sql = sql
        self.command = command
        self.risk = risk
        self.isHighCost = isHighCost ?? kind.isHighCostByDefault
        self.requiresApproval = requiresApproval ?? kind.requiresApprovalByDefault
    }

    /// 能不能被执行：**已批准 + 有可执行内容 + （外部程序类）不在沙箱里**。
    public func isExecutable(isSandboxed: Bool) -> Bool {
        guard state.isApproved else { return false }
        if kind.runsInProcess { return sql?.isEmpty == false }
        guard !isSandboxed else { return false }
        return command?.isEmpty == false
    }
}

/// 审阅策略（限流与连接属性都从调用方来，Core 不猜）。
public struct MaintenancePolicy: Equatable, Sendable {
    /// 一次计划里允许的**高开销任务**数量上限（默认 1）。
    public var maxHighCostTasks: Int
    /// 显式放行"多个高开销任务"（用户知情的例外）。
    public var allowMultipleHighCost: Bool
    /// 只读连接：写操作直接拒（与 `ExecutionSafety` 同一条口径）。
    public var isReadOnly: Bool
    /// 沙箱构建：外部程序类任务不可执行（R-18）。
    public var isSandboxed: Bool

    public init(
        maxHighCostTasks: Int = 1,
        allowMultipleHighCost: Bool = false,
        isReadOnly: Bool = false,
        isSandboxed: Bool = false
    ) {
        self.maxHighCostTasks = maxHighCostTasks
        self.allowMultipleHighCost = allowMultipleHighCost
        self.isReadOnly = isReadOnly
        self.isSandboxed = isSandboxed
    }
}

/// 解析结果：计划 + **被拒绝的行**（认不出 / 不合法的行要显式留下）。
public struct MaintenancePlanReview: Equatable, Sendable {
    public var tasks: [MaintenanceTask]
    /// 整份计划的说明（限流是否触发、哪些任务被拒、为什么）。
    public var notes: [String]
    /// 解析阶段认不出的行（原样保留）。
    public var unparsableLines: [String]

    public init(tasks: [MaintenanceTask], notes: [String], unparsableLines: [String]) {
        self.tasks = tasks
        self.notes = notes
        self.unparsableLines = unparsableLines
    }

    /// 已批准、可执行的任务（执行入口**只认这个**）。
    public func executableTasks(isSandboxed: Bool) -> [MaintenanceTask] {
        tasks.filter { $0.isExecutable(isSandboxed: isSandboxed) }
    }

    public var pendingApproval: [MaintenanceTask] {
        tasks.filter { $0.state == .pending && $0.requiresApproval }
    }
}

public enum MaintenancePlanner {

    /// 计划文本的行格式（写在这里，解析与提示词共用一份）：
    ///
    /// ```
    /// task: vacuum | 整理 customers 表的膨胀 | sql: VACUUM (ANALYZE) public.customers
    /// task: backup | 备份 analytics 库 | command: pg_dump -Fc analytics
    /// ```
    ///
    /// **为什么用 `|` 分隔而不是自然语言**：解析器认不出的东西只能报"没看懂"，
    /// 而"没看懂"在维护任务这个场景里代价很高（用户以为它没做，其实模型想做 `DROP`）。
    /// 所以宁可要求一个明确的行格式，把自由发挥留在 `summary` 那一栏里。
    public static func parse(_ text: String) -> (tasks: [MaintenanceTask], unparsable: [String]) {
        var tasks: [MaintenanceTask] = []
        var unparsable: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard line.lowercased().hasPrefix("task:") else {
                unparsable.append(line)
                continue
            }
            let body = String(line.dropFirst("task:".count))
            let fields = body.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // **大小写不敏感**：模型写 `indexsuggestion` / `IndexSuggestion` 都得认
            // （只有 `indexSuggestion` 这种驼峰 rawValue 会让人踩空）。
            guard let kindField = fields.first,
                  let kind = MaintenanceTaskKind.allCases.first(where: {
                      $0.rawValue.lowercased() == kindField.lowercased()
                  }) else {
                unparsable.append(line)
                continue
            }
            var summary = ""
            var sql: String?
            var command: String?
            for field in fields.dropFirst() {
                let lowered = field.lowercased()
                if lowered.hasPrefix("sql:") {
                    sql = String(field.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                } else if lowered.hasPrefix("command:") {
                    command = String(field.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                } else if lowered.hasPrefix("cost:") {
                    // `cost: high` 由模型显式声明高开销（缺省按类别默认值），下面统一读。
                    continue
                } else if !field.isEmpty {
                    summary = field
                }
            }
            guard summary.isEmpty == false || sql != nil || command != nil else {
                unparsable.append(line)
                continue
            }
            let explicitHighCost = body.lowercased().contains("cost: high")
            tasks.append(
                MaintenanceTask(
                    id: "m\(tasks.count + 1)",
                    kind: kind,
                    summary: summary.isEmpty ? kind.displayName : summary,
                    sql: sql,
                    command: command,
                    risk: classify(sql: sql, kind: kind),
                    isHighCost: kind.isHighCostByDefault || explicitHighCost,
                    requiresApproval: kind.requiresApprovalByDefault
                )
            )
        }
        return (tasks, unparsable)
    }

    /// 逐条审阅：定"要不要审批 / 能不能跑"，并**把理由写在任务上**（界面照着显示）。
    ///
    /// 与 `ExecutionSafety` 的分工：后者判"这条语句该不该被拦"（只读 / 高危确认），
    /// 这里判"这条**维护任务**在编排层面该怎么对待"（限流、外部程序、审批必要性）。
    /// 两者都要过 —— 谁也不替代谁。
    public static func review(
        _ tasks: [MaintenanceTask],
        policy: MaintenancePolicy,
        databaseType: DatabaseType = .postgresql
    ) -> MaintenancePlanReview {
        var reviewed: [MaintenanceTask] = []
        var notes: [String] = []
        var highCostSeen = 0

        for var task in tasks {
            if let sql = task.sql, !sql.isEmpty {
                let decision = ExecutionSafety.check(
                    sql: sql,
                    databaseType: databaseType,
                    policy: ExecutionSafetyPolicy(
                        isEnabled: true,
                        isReadOnly: policy.isReadOnly
                    )
                )
                switch decision {
                case .refused(let reasons, _):
                    task.reviewNotes.append(contentsOf: reasons)
                    task.reviewNotes.append(text(.maintenanceRefusedReadOnly))
                    // 只读连接上的写任务：**连批准都不允许**（不可绕过，与 `ExecutionSafety` 同口径）。
                    task.requiresApproval = true
                    task.state = .rejected
                    reviewed.append(task)
                    continue
                case .needsConfirmation(let reasons, _, _):
                    task.reviewNotes.append(contentsOf: reasons)
                case .allow:
                    break
                }
            }

            if task.requiresApproval {
                task.reviewNotes.append(
                    task.kind == .indexSuggestion
                        ? text(.maintenanceNoApprovalNeeded)
                        : text(.maintenanceNeedsApproval)
                )
            }

            if task.isHighCost {
                highCostSeen += 1
                if highCostSeen > policy.maxHighCostTasks, !policy.allowMultipleHighCost {
                    task.reviewNotes.append(
                        text(.maintenanceHighCostRateLimited, String(policy.maxHighCostTasks))
                    )
                    task.state = .rejected
                    reviewed.append(task)
                    continue
                }
            }

            if !task.kind.runsInProcess, policy.isSandboxed {
                task.reviewNotes.append(text(.maintenanceSandboxedExternal))
            }

            reviewed.append(task)
        }

        if reviewed.contains(where: { $0.isHighCost }) {
            notes.append(text(.maintenanceHighCostCounted, String(highCostSeen)))
        }
        if policy.isReadOnly {
            notes.append(text(.maintenanceReadOnlyConnection))
        }
        return MaintenancePlanReview(tasks: reviewed, notes: notes, unparsableLines: [])
    }

    /// 从计划文本一步到位：解析 + 审阅。
    public static func makePlan(
        from text: String,
        policy: MaintenancePolicy,
        databaseType: DatabaseType = .postgresql
    ) -> MaintenancePlanReview {
        let parsed = parse(text)
        var review = review(parsed.tasks, policy: policy, databaseType: databaseType)
        review.unparsableLines = parsed.unparsable
        return review
    }

    /// 按编号批准（`["m1", "m3"]`）或全部批准。**只改状态，不执行** ——
    /// 执行是另一个入口，它只认"已批准"的任务。
    public static func approve(_ review: MaintenancePlanReview, ids: [String]?) -> MaintenancePlanReview {
        var updated = review
        for index in updated.tasks.indices {
            let task = updated.tasks[index]
            guard !task.state.isFinished else { continue }
            if task.requiresApproval == false { continue }
            if let ids, !ids.contains(task.id) { continue }
            updated.tasks[index].state = .approved
        }
        return updated
    }

    /// 按编号拒绝（拒绝的任务**留在计划里**，让"拒绝了什么"看得见）。
    public static func reject(_ review: MaintenancePlanReview, ids: [String]) -> MaintenancePlanReview {
        var updated = review
        for index in updated.tasks.indices where ids.contains(updated.tasks[index].id) {
            guard !updated.tasks[index].state.isFinished else { continue }
            updated.tasks[index].state = .rejected
        }
        return updated
    }

    /// 记录执行结果（成功 / 失败）。失败要带**服务端说的话**。
    public static func record(
        _ review: MaintenancePlanReview,
        taskID: String,
        failureReason: String? = nil
    ) -> MaintenancePlanReview {
        var updated = review
        for index in updated.tasks.indices where updated.tasks[index].id == taskID {
            updated.tasks[index].state = failureReason.map { .failed(reason: $0) } ?? .executed
        }
        return updated
    }

    private static func classify(sql: String?, kind: MaintenanceTaskKind) -> AgentRiskLevel {
        guard let sql, !sql.isEmpty else {
            // 备份 / 恢复是**高影响**操作（动的是整库的文件），按 destructive 对待：
            // 它的"破坏性"不体现在 SQL 关键字上，体现在"它动的是整个数据库"。
            return kind == .backup || kind == .restore ? .destructive : .low
        }
        let assessment = AgentGuardrail.evaluate(sql: sql, policy: .readOnlyDefault)
        return assessment.statements.reduce(AgentRiskLevel.low) { AgentRiskLevel.max($0, $1.risk) }
    }
}

/// Core 侧的文案取值（与其余 Core 展示文本同一现状：默认简体中文，界面语言透传见 R-45）。
private func text(_ key: LKey, _ arguments: CVarArg...) -> String {
    if arguments.isEmpty {
        return LocalizedStrings.text(key, language: .simplifiedChinese)
    }
    return LocalizedStrings.format(key, language: .simplifiedChinese, arguments)
}
