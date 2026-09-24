import Foundation

// MARK: - 任务定义（FR-AI-05）

/// 数据任务定义：由自然语言 specs 转成的可执行任务（源头 → 转换 → 目标 → 调度 → 导出）。
///
/// 两条设计约束直接来自验收要点：
/// - `specs` 原样保留在定义里 —— 「specs 与生成的任务定义同时留存、均为可编辑文本」，
///   两者都是普通字符串，人可以看、可以改、可以 diff（NFR-AI-05）；
/// - 定义是纯值类型 + `Codable`，不持有任何执行状态，执行历史另存（FR-AI-06）。
public struct DataTaskDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// 生成该定义的原始规格说明（自然语言）。与定义同时留存。
    public var specs: String
    public var source: Source
    public var transformations: [Transformation]
    public var target: Target
    public var schedule: TaskSchedule
    public var output: ExportSettings?
    /// 是否启用（停用后调度器不会排期）。
    public var isEnabled: Bool
    public var createdAt: Date
    /// 最近一次修改时间。
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        specs: String,
        source: Source,
        transformations: [Transformation] = [],
        target: Target,
        schedule: TaskSchedule = TaskSchedule(),
        output: ExportSettings? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.specs = specs
        self.source = source
        self.transformations = transformations
        self.target = target
        self.schedule = schedule
        self.output = output
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 数据来源。
    public struct Source: Codable, Equatable, Sendable {
        public var connectionName: String?
        public var database: String?
        public var schema: String?
        public var table: String
        /// 需要读取的列；空数组表示全部列。
        public var columns: [String]
        /// 过滤条件（`WHERE` 之后的片段）；`nil` 表示不过滤。
        public var filter: String?

        public init(
            connectionName: String? = nil,
            database: String? = nil,
            schema: String? = nil,
            table: String,
            columns: [String] = [],
            filter: String? = nil
        ) {
            self.connectionName = connectionName
            self.database = database
            self.schema = schema
            self.table = table
            self.columns = columns
            self.filter = filter
        }
    }

    /// 一步转换。
    public struct Transformation: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            case rename
            case cast
            case derive
            case drop
            case mask

            public var displayName: String {
                switch self {
                case .rename: return "重命名"
                case .cast: return "类型转换"
                case .derive: return "派生列"
                case .drop: return "丢弃列"
                case .mask: return "脱敏"
                }
            }
        }

        public var kind: Kind
        /// 源列名（`derive` 时可为空）。
        public var column: String?
        /// 目标列名（`rename` 用）。
        public var targetColumn: String?
        /// 表达式（`cast` / `derive` / `mask` 用）。
        public var expression: String?
        public var note: String?

        public init(
            kind: Kind,
            column: String? = nil,
            targetColumn: String? = nil,
            expression: String? = nil,
            note: String? = nil
        ) {
            self.kind = kind
            self.column = column
            self.targetColumn = targetColumn
            self.expression = expression
            self.note = note
        }
    }

    /// 写入目标。
    public struct Target: Codable, Equatable, Sendable {
        /// 写入语义；对应 FR-AI-11 的「重跑幂等语义（覆盖 / 追加 / 断点）」。
        public enum WriteMode: String, Codable, Sendable, CaseIterable {
            case append
            case overwrite
            case upsert

            public var displayName: String {
                switch self {
                case .append: return "追加"
                case .overwrite: return "覆盖"
                case .upsert: return "更新插入"
                }
            }
        }

        public var connectionName: String?
        public var database: String?
        public var schema: String?
        public var table: String
        public var writeMode: WriteMode
        /// `upsert` 的冲突键。
        public var keyColumns: [String]

        public init(
            connectionName: String? = nil,
            database: String? = nil,
            schema: String? = nil,
            table: String,
            writeMode: WriteMode = .append,
            keyColumns: [String] = []
        ) {
            self.connectionName = connectionName
            self.database = database
            self.schema = schema
            self.table = table
            self.writeMode = writeMode
            self.keyColumns = keyColumns
        }
    }

    /// 任务产物的导出设置（FR-AI-08 的安全作用域目录在 T-55 落地，这里只存书签标识）。
    public struct ExportSettings: Codable, Equatable, Sendable {
        public enum Format: String, Codable, Sendable, CaseIterable {
            case csv
            case json
            case tsv
        }

        public var format: Format
        /// 目标目录的 security-scoped bookmark（T-55 负责生成与解析）。
        public var directoryBookmark: Data?
        public var fileNameTemplate: String?

        public init(format: Format = .csv, directoryBookmark: Data? = nil, fileNameTemplate: String? = nil) {
            self.format = format
            self.directoryBookmark = directoryBookmark
            self.fileNameTemplate = fileNameTemplate
        }
    }
}

// MARK: - 调度（FR-AI-06）

/// 调度设置。
public struct TaskSchedule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// 仅手动触发。
        case manual
        /// 一次性。
        case once
        /// 周期。
        case recurring

        public var displayName: String {
            switch self {
            case .manual: return "手动"
            case .once: return "一次性"
            case .recurring: return "周期"
            }
        }
    }

    public var kind: Kind
    /// `once`：计划执行时刻。
    public var runAt: Date?
    /// `recurring`：周期（秒），必须为正。
    public var intervalSeconds: TimeInterval?
    /// `recurring`：首次执行时刻；缺省用任务创建时间。
    public var startAt: Date?

    public init(
        kind: Kind = .manual,
        runAt: Date? = nil,
        intervalSeconds: TimeInterval? = nil,
        startAt: Date? = nil
    ) {
        self.kind = kind
        self.runAt = runAt
        self.intervalSeconds = intervalSeconds
        self.startAt = startAt
    }

    public static let manual = TaskSchedule()
}

/// 调度判定结果（FR-AI-06）。
public enum ScheduleDecision: Equatable, Sendable {
    /// 未排期（手动任务、未启用、或调度参数不全）。
    case notScheduled
    /// 任务被停用。
    case disabled
    /// 还没到时间。
    case waiting(until: Date)
    /// 到点了。
    case due(plannedAt: Date)
    /// 错过了窗口：**不静默补跑**，而是给出明确提示交给用户决定。
    case missed(plannedAt: Date, overdueBy: TimeInterval)

    public var message: String {
        switch self {
        case .notScheduled:
            return "该任务未设置自动排期。"
        case .disabled:
            return "该任务已停用。"
        case .waiting(let until):
            return "下次执行时间：\(TaskScheduler.describe(until))。"
        case .due(let plannedAt):
            return "计划执行时间已到（\(TaskScheduler.describe(plannedAt))）。"
        case .missed(let plannedAt, let overdueBy):
            let minutes = Int(overdueBy / 60)
            return "已错过计划执行时间（\(TaskScheduler.describe(plannedAt))，晚了约 \(minutes) 分钟）。"
                + "为避免意外补跑，请确认是否现在执行。"
        }
    }

    public var isDue: Bool {
        if case .due = self { return true }
        return false
    }
}

/// 调度骨架（FR-AI-06）。
///
/// 只做**纯时间计算**：不启动定时器、不持有状态。App 层每隔一段时间（或从睡眠唤醒后）
/// 调一次 `decision` 即可；这样调度逻辑可以在单测里完全确定性地覆盖。
///
/// 关于「错过窗口」的取舍：默认**不自动补跑**。客户端可能整天没打开，
/// 一打开就补跑十几个任务（尤其写库 / 调模型的任务）风险远大于收益；
/// 因此返回 `.missed` 由界面明确提示、由用户决定（这正是验收要点要求的「错过窗口给出明确提示」）。
public enum TaskScheduler {

    /// 判断现在是否应当执行。
    ///
    /// - Parameters:
    ///   - lastRun: 上一次**成功**执行的时刻（没有则传 `nil`）。
    ///   - grace: 允许的宽限（秒）：计划时间过去不超过该值仍视为「到点」。
    ///     默认 0 —— 只要晚了一秒就会被判为 `.missed`，由界面提示而不是静默执行。
    public static func decision(
        for task: DataTaskDefinition,
        now: Date = Date(),
        lastRun: Date? = nil,
        grace: TimeInterval = 0
    ) -> ScheduleDecision {
        guard task.isEnabled else { return .disabled }
        guard let planned = pendingPlannedTime(for: task, lastRun: lastRun) else {
            return .notScheduled
        }

        if planned <= now {
            let overdue = now.timeIntervalSince(planned)
            return overdue <= grace ? .due(plannedAt: planned) : .missed(plannedAt: planned, overdueBy: overdue)
        }
        return .waiting(until: planned)
    }

    /// 严格晚于 `date` 的下一次计划时刻；一次性任务已到期时返回 `nil`。
    public static func nextRun(
        for task: DataTaskDefinition,
        after date: Date,
        lastRun: Date? = nil
    ) -> Date? {
        guard task.isEnabled, let planned = pendingPlannedTime(for: task, lastRun: lastRun) else {
            return nil
        }
        if planned > date { return planned }

        switch task.schedule.kind {
        case .manual, .once:
            // 一次性任务的时刻已过且未执行 —— 它属于「错过」，不存在「下一次」。
            return nil
        case .recurring:
            guard let interval = task.schedule.intervalSeconds, interval > 0 else { return nil }
            let start = task.schedule.startAt ?? task.createdAt
            let steps = ((date.timeIntervalSince(start)) / interval).rounded(.down) + 1
            return start.addingTimeInterval(steps * interval)
        }
    }

    /// 区间 `[from, to)` 内被错过的计划时刻（用于「错过窗口」提示与执行历史补记）。
    ///
    /// 上限默认 100 条：周期很短、客户端很久没打开时，没必要算出上万个时间点。
    public static func missedRuns(
        for task: DataTaskDefinition,
        from: Date,
        to: Date,
        lastRun: Date? = nil,
        limit: Int = 100
    ) -> [Date] {
        guard task.isEnabled, from < to, limit > 0 else { return [] }

        switch task.schedule.kind {
        case .manual:
            return []

        case .once:
            guard let runAt = task.schedule.runAt, runAt >= from, runAt < to else { return [] }
            if let lastRun, lastRun >= runAt { return [] }
            return [runAt]

        case .recurring:
            guard let interval = task.schedule.intervalSeconds, interval > 0 else { return [] }
            let start = task.schedule.startAt ?? task.createdAt

            // 第一个 >= from 的计划时刻。
            var steps: Double = 0
            if from > start {
                steps = ((from.timeIntervalSince(start)) / interval).rounded(.up)
            }

            var results: [Date] = []
            var candidate = start.addingTimeInterval(steps * interval)
            while candidate < to, results.count < limit {
                if candidate >= from, !(lastRun.map { $0 >= candidate } ?? false) {
                    results.append(candidate)
                }
                steps += 1
                candidate = start.addingTimeInterval(steps * interval)
            }
            return results
        }
    }

    /// 「已到期但尚未成功执行」的那个计划时刻；没有则返回 `nil`。
    ///
    /// 与 `nextRun` 的区别：这里允许返回值落在过去（表示漏掉了），
    /// `decision` 据此区分「到点」与「错过」。
    static func pendingPlannedTime(for task: DataTaskDefinition, lastRun: Date?) -> Date? {
        let schedule = task.schedule
        switch schedule.kind {
        case .manual:
            return nil

        case .once:
            guard let runAt = schedule.runAt else { return nil }
            if let lastRun, lastRun >= runAt { return nil }
            return runAt

        case .recurring:
            guard let interval = schedule.intervalSeconds, interval > 0 else { return nil }
            let start = schedule.startAt ?? task.createdAt
            guard let lastRun, lastRun >= start else { return start }
            let steps = ((lastRun.timeIntervalSince(start)) / interval).rounded(.down) + 1
            return start.addingTimeInterval(steps * interval)
        }
    }

    /// 人类可读的时间描述（提示文案用）。
    public static func describe(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 试运行与校验（FR-AI-05）

/// 试运行预览结果（FR-AI-05「保存前必须试运行 + 预览」）。
///
/// **不真正执行**：只把「将要做什么」摊开给人看。
public struct TaskDryRun: Equatable, Sendable {
    /// 「源 → 转换 → 目标」的可读步骤。
    public var steps: [String]
    /// 预览 SQL（只读探测 + 目标写入语句的形态）。
    public var previewStatements: [String]
    public var warnings: [String]
    public var issues: [String]

    public init(
        steps: [String] = [],
        previewStatements: [String] = [],
        warnings: [String] = [],
        issues: [String] = []
    ) {
        self.steps = steps
        self.previewStatements = previewStatements
        self.warnings = warnings
        self.issues = issues
    }

    public var isRunnable: Bool { issues.isEmpty }
}

public extension DataTaskDefinition {

    /// 定义本身的问题（保存前拦一道）。
    var issues: [String] {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("任务名不能为空。")
        }
        if specs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("规格说明（specs）不能为空 —— 它是任务定义的来源，必须与定义一起留存。")
        }
        if source.table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("数据来源表不能为空。")
        }
        if target.table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("目标表不能为空。")
        }

        switch schedule.kind {
        case .manual:
            break
        case .once:
            if schedule.runAt == nil { issues.append("一次性任务必须指定执行时间。") }
        case .recurring:
            if let interval = schedule.intervalSeconds {
                if interval <= 0 { issues.append("周期必须为正数。") }
            } else {
                issues.append("周期任务必须指定执行间隔。")
            }
        }

        if target.writeMode == .upsert, target.keyColumns.isEmpty {
            issues.append("更新插入（upsert）必须指定冲突键列。")
        }

        // 源列清单为空 = `SELECT *`：此时「丢弃列」挑不出列，更新插入也写不出冲突更新子句。
        let explicitColumns = source.columns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if explicitColumns.isEmpty {
            if transformations.contains(where: { $0.kind == .drop }) {
                issues.append("未指定源列清单时无法执行「丢弃列」转换（请先列出要读取的列）。")
            }
            if target.writeMode == .upsert {
                issues.append("更新插入（upsert）需要明确的源列清单，不能使用全部列。")
            }
        }

        for transformation in transformations {
            if transformation.kind == .derive,
               (transformation.expression ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("派生列转换缺少表达式。")
            }
            if transformation.kind == .derive,
               (transformation.targetColumn ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("派生列转换缺少目标列名。")
            }
            if transformation.kind != .derive,
               (transformation.column ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(transformation.kind.displayName)转换缺少源列名。")
            }
            // 转换引用的列必须在读进来的源列里 —— 不然后面编译 SQL 时才发现，属于白填一遍。
            if let rawColumn = transformation.column {
                let column = rawColumn.trimmingCharacters(in: .whitespacesAndNewlines)
                if !column.isEmpty, !explicitColumns.isEmpty, !explicitColumns.contains(column) {
                    issues.append("\(transformation.kind.displayName)转换引用的源列「\(column)」不在源列清单里。")
                }
            }
            if let expression = transformation.expression, !expression.isEmpty,
               AgentGuardrail.detectsEmbeddedStatement(expression) {
                issues.append("转换表达式里出现了形似语句的片段，已拒绝。")
            }
        }

        if let filter = source.filter, !filter.isEmpty,
           AgentGuardrail.detectsEmbeddedStatement(filter) {
            issues.append("过滤条件里出现了形似语句的片段，已拒绝。")
        }

        return issues
    }

    var isValid: Bool { issues.isEmpty }

    /// 试运行预览（FR-AI-05）。
    func dryRun(dialect: any SQLDialect = PostgresDialect()) -> TaskDryRun {
        var steps: [String] = []
        var statements: [String] = []
        var warnings: [String] = []

        let sourceName = qualified(source.schema, source.table, dialect: dialect)
        let targetName = qualified(target.schema, target.table, dialect: dialect)

        steps.append("读取：\(sourceName)" + (source.columns.isEmpty ? "（全部列）" : "（\(source.columns.joined(separator: ", "))）"))
        if let filter = source.filter, !filter.isEmpty {
            steps.append("过滤：\(filter)")
        }
        for transformation in transformations {
            steps.append("转换：\(transformation.kind.displayName) \(transformation.column ?? transformation.targetColumn ?? "")")
        }
        steps.append("写入：\(targetName)（\(target.writeMode.displayName)）")

        var select = "SELECT "
        select += source.columns.isEmpty ? "*" : source.columns.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")
        select += " FROM \(sourceName)"
        if let filter = source.filter, !filter.isEmpty {
            select += " WHERE \(filter)"
        }
        // 预览只取少量行，避免「试运行」本身变成重查询。
        select += " " + dialect.limitClause(offset: 0, count: 10) + ";"
        statements.append(select)

        switch target.writeMode {
        case .append:
            statements.append("-- 追加写入 \(targetName)（执行时按列映射生成 INSERT 或 COPY）")
        case .overwrite:
            statements.append("TRUNCATE TABLE \(targetName);")
            warnings.append("覆盖模式会先清空目标表。")
        case .upsert:
            let keys = target.keyColumns.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")
            statements.append("-- 以 (\(keys)) 为冲突键更新插入 \(targetName)")
        }

        let issues = self.issues
        return TaskDryRun(steps: steps, previewStatements: statements, warnings: warnings, issues: issues)
    }

    private func qualified(_ schema: String?, _ table: String, dialect: any SQLDialect) -> String {
        guard let schema, !schema.isEmpty, dialect.featureSet.contains(.supportsSchemas) else {
            return dialect.quoteIdentifier(table)
        }
        return "\(dialect.quoteIdentifier(schema)).\(dialect.quoteIdentifier(table))"
    }
}

// MARK: - 执行历史（FR-AI-06）

/// 一次执行的记录。
public struct TaskRunRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case running
        case succeeded
        case failed
        /// 因为错过窗口且未被确认，本次跳过。
        case skipped

        public var displayName: String {
            switch self {
            case .running: return "执行中"
            case .succeeded: return "成功"
            case .failed: return "失败"
            case .skipped: return "已跳过"
            }
        }
    }

    public var id: UUID
    public var taskID: UUID
    /// 计划执行时刻（可能是补记的错过时刻）。
    public var plannedAt: Date?
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var rowsWritten: Int?
    public var message: String?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        plannedAt: Date? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: Status = .running,
        rowsWritten: Int? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.plannedAt = plannedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.rowsWritten = rowsWritten
        self.message = message
    }

    /// 耗时（秒）；未结束时为 `nil`。
    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

// MARK: - 持久化

/// 数据任务与执行历史的持久化（FR-AI-05、FR-AI-06）。
///
/// 任务定义存 `data-tasks.json`；执行历史追加到 `task-runs.jsonl`
/// （历史只追加、写入频繁，用 JSONL 避免每次重写整份文件）。
public actor DataTaskStore {
    public static let shared = DataTaskStore()

    private let tasksURL: URL
    private let runsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL? = nil) {
        let baseURL: URL
        if let directoryURL {
            baseURL = directoryURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            baseURL = applicationSupport.appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
        }

        self.tasksURL = baseURL.appendingPathComponent("data-tasks.json", isDirectory: false)
        self.runsURL = baseURL.appendingPathComponent("task-runs.jsonl", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func tasksFileLocation() -> URL { tasksURL }
    public func runsFileLocation() -> URL { runsURL }

    // MARK: 任务定义

    public func tasks() throws -> [DataTaskDefinition] {
        guard FileManager.default.fileExists(atPath: tasksURL.path) else { return [] }
        do {
            return try decoder.decode([DataTaskDefinition].self, from: Data(contentsOf: tasksURL))
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    /// 新增或替换（按 `id` 匹配）一个任务。
    ///
    /// 保存是**版本化的唯一收口点**（FR-AI-11）：放在这里，界面 / 命令行 / 数据任务调度
    /// 无论从哪条路径改定义，历史都会自动留下；散在各处写"记一条版本"必漏。
    /// 内容没变时不记新版本（`SpecVersionStore.record` 自己判定），免得历史被噪音淹掉。
    @discardableResult
    public func save(_ task: DataTaskDefinition) throws -> DataTaskDefinition {
        var stored = task
        stored.updatedAt = Date()
        var all = try tasks()
        if let index = all.firstIndex(where: { $0.id == task.id }) {
            all[index] = stored
        } else {
            all.append(stored)
        }
        try write(all)
        // 版本记录失败**不该让保存失败**（与归档同一条纪律：历史是附加价值，
        // 不是用户这次操作的必要条件），但要看得到。
        do {
            try SpecVersionStore(directoryURL: tasksURL.deletingLastPathComponent()).record(definition: stored)
        } catch {
            lastVersioningError = error.localizedDescription
        }
        return stored
    }

    /// 最近一次版本记录失败的原因（`nil` = 正常）。界面可以据此提示"历史可能不完整"。
    public private(set) var lastVersioningError: String?

    public func delete(id: UUID) throws {
        var all = try tasks()
        all.removeAll { $0.id == id }
        try write(all)
    }

    private func write(_ tasks: [DataTaskDefinition]) throws {
        do {
            try FileManager.default.createDirectory(
                at: tasksURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(tasks).write(to: tasksURL, options: [.atomic])
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    // MARK: 执行历史

    public func appendRun(_ record: TaskRunRecord) throws {
        do {
            try FileManager.default.createDirectory(
                at: runsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var line = try encoder.encode(record)
            line.append(0x0A)

            if FileManager.default.fileExists(atPath: runsURL.path) {
                let handle = try FileHandle(forWritingTo: runsURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: runsURL, options: [.atomic])
            }
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    /// 读取执行历史；`taskID` 为 `nil` 时返回全部（按写入顺序）。
    public func runs(for taskID: UUID? = nil) throws -> [TaskRunRecord] {
        guard FileManager.default.fileExists(atPath: runsURL.path) else { return [] }
        do {
            let text = try String(contentsOf: runsURL, encoding: .utf8)
            let all = text
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .compactMap { line -> TaskRunRecord? in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? decoder.decode(TaskRunRecord.self, from: data)
                }
            guard let taskID else { return all }
            return all.filter { $0.taskID == taskID }
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    /// 最近一次**成功**执行时刻（调度器判断「这个点跑过没有」用）。
    public func lastSuccessfulRun(for taskID: UUID) throws -> Date? {
        try runs(for: taskID)
            .filter { $0.status == .succeeded }
            .map(\.startedAt)
            .max()
    }

    public func removeAll() throws {
        let manager = FileManager.default
        for url in [tasksURL, runsURL] where manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: url)
        }
    }
}
