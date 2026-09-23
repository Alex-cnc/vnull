import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import DoyahCore
import DoyahPlatform

struct QueryTab: Identifiable {
    let id: UUID
    var title: String
    var sql: String
    /// 多语句执行时，每个返回结果集的语句对应一个 QueryResult。
    var results: [QueryResult]
    var selectedResultIndex: Int
    var isExecuting: Bool

    /// 是否有**可展示的表格结果** —— 决定结果区要不要出现。
    ///
    /// 只认「有列的」结果集：`CREATE TABLE` / `INSERT` 这类没有结果集，它们的交代在
    /// Output / Problem 页签里，硬在结果区摆一张空表只是噪音。
    var hasTabularResult: Bool {
        results.contains { $0.columnCount > 0 }
    }

    /// 每个结果集的「出处」标签，与 `results` 一一对应（例：`第 2 条语句返回 5 行 × 3 列`）。
    ///
    /// **刻意不写进 Output 日志**：行 × 列 结果表自己就展示了，写进日志会让 Result 与 Output
    /// 两个页签看起来重复。它作为结果集的出处，挂在 Result 页签的表头。
    /// 注意没有 `didSet` —— 这正是它不进日志的原因。
    var resultSummaries: [String] = []

    /// 执行输出日志（下方面板 Output 页签）。
    ///
    /// 用 `didSet` 在**模型层**拦截，而不是去改那 70 多处赋值点：
    /// 那些地方遍布 AppState（执行 / 导出 / 建库 / 权限 / 数据任务…），逐个改必漏。
    /// 追加规则本身在 `Core/TabLog.swift` 里，是可单测的纯函数。
    var outputLog: [TabLogEntry] = []

    /// 问题日志（下方面板 Problem 页签）：执行错误与语法检查失败、告警。
    var problemLog: [TabLogEntry] = []

    var statusMessage: String {
        didSet { outputLog = TabLog.appended(outputLog, message: statusMessage, severity: .info) }
    }

    var errorMessage: String? {
        didSet {
            guard let errorMessage else { return }
            problemLog = TabLog.appended(problemLog, message: errorMessage, severity: .error)
        }
    }

    /// 「检查」按钮的结果（服务器端 EXPLAIN 校验）。赋值顺序上 `syntaxCheckFailed` 先于本字段。
    var syntaxCheckMessage: String? {
        didSet {
            guard let syntaxCheckMessage else { return }
            problemLog = TabLog.appended(
                problemLog,
                message: syntaxCheckMessage,
                severity: syntaxCheckFailed ? .error : .info
            )
        }
    }

    var syntaxCheckFailed: Bool
    /// 最近一次执行使用的连接；切换左侧连接后仍可正确取消本页签的查询。
    var connectionID: ConnectionConfig.ID?
    /// 最近一次执行使用的数据库（同一连接可浏览 / 执行在不同库上）。
    var database: String?
    /// 关联的磁盘文件（由「打开文件」或「另存为」设置）。
    var fileURL: URL?
    /// 相对上次保存是否有改动（仅文件页签展示圆点）。
    var isDirty: Bool

    init(
        id: UUID = UUID(),
        title: String,
        sql: String = "",
        results: [QueryResult] = [],
        isExecuting: Bool = false,
        statusMessage: String = "",
        errorMessage: String? = nil,
        syntaxCheckMessage: String? = nil,
        syntaxCheckFailed: Bool = false,
        connectionID: ConnectionConfig.ID? = nil,
        database: String? = nil,
        fileURL: URL? = nil,
        isDirty: Bool = false
    ) {
        self.id = id
        self.title = title
        self.sql = sql
        self.results = results
        self.selectedResultIndex = 0
        self.isExecuting = isExecuting
        self.statusMessage = statusMessage
        self.errorMessage = errorMessage
        self.syntaxCheckMessage = syntaxCheckMessage
        self.syntaxCheckFailed = syntaxCheckFailed
        self.connectionID = connectionID
        self.database = database
        self.fileURL = fileURL
        self.isDirty = isDirty
    }

    var result: QueryResult? {
        guard results.indices.contains(selectedResultIndex) else { return nil }
        return results[selectedResultIndex]
    }
}

/// 高危语句保护相关的偏好键（FR-EXEC-16）。
///
/// 单独放在文件级：存储属性的初始化器里不能引用 `Self`，用具体类型名又会让
/// 「谁拥有这些键」变得含糊，这里直接显式命名。
private enum ExecutionSafetyDefaults {
    static let safeModeKey = "execution.safeMode"
    static let confirmAllWritesKey = "execution.confirmAllWrites"
}

/// 一条「被高危语句保护拦下、等待用户确认」的执行请求（FR-EXEC-16）。
struct PendingExecution: Identifiable {
    let id = UUID()
    let tabID: UUID
    let sql: String
    let decision: ExecutionSafety.Decision

    var reasons: [String] {
        if case .needsConfirmation(let reasons, _, _) = decision { return reasons }
        return []
    }
}

/// 一次「已提交审批、等待人工决定」的数据任务执行（FR-AI-06）。
///
/// 审批本身复用 `AgentActionGate` / `AgentApproval`（不另造第二套审批机制）；
/// 这里只记住「批准之后还要做什么」：导出产物、记一条执行历史。
struct PendingDataTaskRun {
    let task: DataTaskDefinition
    let plannedAt: Date?
    let startedAt: Date
    /// 提交审批的那段写语句（批准后原样执行）。
    let writeSQL: String
}

@MainActor
final class AppState: ObservableObject {
    @Published var connections: [ConnectionConfig] = []
    @Published var selectedConnectionID: ConnectionConfig.ID? {
        didSet {
            // 换连接 = 离开旧连接：旧连接上未提交的手工事务必须先结算（回滚并说明），
            // 否则它会一直挂在那个连接上（连接还活着，事务也还开着），用户却再也看不到它。
            if oldValue != selectedConnectionID {
                settleTransactions(leaving: selectedConnectionID)
            }
            rememberSelectedConnection()
            // 换连接后建库权限结论作废，等对象树加载时重新探测（FR-META-11）。
            setIfChanged(\.canCreateDatabase, nil)
        }
    }
    /// 本次运行的查询历史。按 DR-02 只放在内存里，退出应用即清空。
    @Published var queryHistory: [QueryHistory] = []

    /// 当前登录用户能否创建数据库（FR-META-11）。
    /// `nil` = 未知 / 该方言不支持探测 —— 此时不呈现「新建数据库」入口。
    @Published var canCreateDatabase: Bool?

    /// 对象树刷新令牌：新建数据库等操作后自增，驱动的视图重新加载根节点。
    @Published var metadataRevision = 0
    /// 当前查询目标数据库（上下文栏选择）。
    @Published var selectedDatabase: String?
    /// 当前服务器上当前用户可连接的数据库列表。
    @Published var availableDatabases: [String] = []
    @Published var isLoadingDatabases = false
    @Published var databaseError: String?
    @Published var tabs: [QueryTab] = []
    @Published var selectedTabID: UUID?
    @Published var savedQueries: [SavedQuery] = []

    /// 有未保存改动的页签数。重启前提示会用到（NFR-I18N-03）：
    /// 不能让人为了换个界面语言把正在写的查询丢掉。
    var dirtyTabCount: Int {
        tabs.filter(\.isDirty).count
    }
    // MARK: 智能体（FR-AI-01）

    /// 智能体接入配置；默认是「总开关关闭 + 端点为空」的安全默认（AC-AI-01）。
    @Published var agentConfiguration: AgentConfiguration = .default
    /// 已保存的 API Key（只存在于内存与系统钥匙串，**永不写入配置文件**）。
    @Published var agentAPIKey: String?
    /// 钥匙串里是否已有 Key（界面显示「已配置 / 未配置」）。
    @Published var hasAgentAPIKey = false
    /// 「智能体设置…」面板的呈现开关（菜单命令驱动）。
    @Published var isAgentSettingsPresented = false

    /// 「外观」面板（FR-EDIT-33：强调色可配置）。
    @Published var isAppearancePresented = false

    /// 活动栏当前选中的视图（FR-EDIT-32）。未知值回退到数据库视图，界面永远起得来。
    @Published var selectedActivityItem: ActivityBarItem = ActivityBarItem.resolve(
        id: UserDefaults.standard.string(forKey: ActivityBarItem.storageKey)
    ) {
        didSet {
            UserDefaults.standard.set(selectedActivityItem.rawValue, forKey: ActivityBarItem.storageKey)
        }
    }

    /// 「账户」占位说明（R-23：语义未定，只放占位不实现登录）。
    @Published var isAccountNoticePresented = false
    // MARK: 执行计划（FR-DIAG-01）

    /// 执行计划面板的呈现开关。
    @Published var isExecutionPlanPresented = false
    /// 最近一次解析出的计划树；`nil` = 还没跑过或解析失败。
    @Published var executionPlan: ExplainPlan?
    @Published var executionPlanError: String?
    @Published var executionPlanIsLoading = false
    /// `ANALYZE` 会**真正执行**语句，因此默认关闭；BUFFERS / JSON 只是多要些信息。
    @Published var planRunAnalyze = false
    @Published var planIncludeBuffers = false
    @Published var planUseJSON = true

    /// 「自然语言 → SQL」面板的呈现开关（菜单命令驱动）。
    @Published var isAgentSQLPresented = false

    // MARK: 执行审批与审计（FR-AI-09 / NFR-AI-03）

    /// 「审批与审计…」面板的呈现开关（菜单命令驱动）。
    @Published var isAgentAuditPresented = false

    // MARK: - 浏览器页签（FR-EDIT-34）
    //
    // 为什么**不**把浏览器塞进 `QueryTab`：那会把 SQL 专属字段（sql / results / isExecuting…）
    // 污染成一堆可选值，约百处引用都要跟着改成 `if let`，而且每加一个浏览器字段就再污染一次。
    // 这里让两套页签并行存在，只用一个"当前选中"把它们连起来 —— SQL 路径零改动。

    /// 打开着的浏览器页签（状态模型在 Core，视图只读它）。
    @Published var browserPages: [BrowserPage] = []
    /// 当前选中的浏览器页签；非 nil 时编辑区显示浏览器（SQL 页签的选择保持不变，切回来即可）。
    @Published var selectedBrowserID: UUID?

    /// 引擎（`WKWebView`）按页签缓存：视图重建时不重新加载页面。
    private var browserEngines: [UUID: WebKitBrowserEngine] = [:]
    /// 统一外发日志面板（NFR-SEC-08）。
    @Published var isEgressLogPresented = false
    @Published var egressEntries: [EgressEntry] = []
    @Published var egressMessage: String?
    @Published var egressError: String?
    /// 审计记录（读自本地 JSONL，顺序 = 写入顺序 = 时间顺序）。
    @Published var agentAuditRecords: [AgentActionRecord] = []
    @Published var isAgentAuditLoading = false
    /// 已提交、等待人工决策的智能体动作（FR-AI-09 逐次审批）。
    @Published var pendingAgentApprovals: [AgentApproval] = []
    /// 需要弹出审批单的那个动作；`nil` = 不弹。
    @Published var agentApprovalRequest: AgentApproval?
    /// 面板内的一行提示（导出成功 / 已清空 / 已批准…）。
    @Published var agentAuditMessage: String?
    /// 面板内的错误（读取 / 导出失败、执行失败…）。
    @Published var agentAuditError: String?

    // MARK: 数据任务（FR-AI-05 / FR-AI-06 / FR-AI-08）

    /// 「数据任务…」面板的呈现开关（菜单命令驱动）。
    @Published var isDataTaskPresented = false
    /// 已保存的数据任务定义（`data-tasks.json`）。
    @Published var dataTasks: [DataTaskDefinition] = []
    /// 执行历史（`task-runs.jsonl`，追加式；状态 / 行数 / 耗时 / 消息都在记录里）。
    @Published var dataTaskRuns: [TaskRunRecord] = []
    /// 每个任务当前的调度判定（App 侧 tick 更新，界面直接展示）。
    @Published var dataTaskDecisions: [UUID: ScheduleDecision] = [:]
    /// 已授权目录（`directory-bookmarks.json`），可在多个任务间复用（FR-AI-08）。
    @Published var storedDirectoryBookmarks: [DirectoryBookmark] = []
    /// 面板内的一行提示（保存成功 / 已提交审批 / 产物已导出…）。
    @Published var dataTaskMessage: String?
    /// 面板内的错误（读取 / 保存 / 导出 / 执行失败）。
    @Published var dataTaskError: String?

    private let dataTaskStore = DataTaskStore.shared
    private let directoryBookmarkStore = DirectoryBookmarkStore.shared
    /// 目录选择器：Core 只定义 `DirectoryPicker` 协议，真实实现用 `NSOpenPanel`（FR-AI-08）。
    private let dataTaskDirectoryPicker: any DirectoryPicker = OpenPanelDirectoryPicker()

    // MARK: - 查询自动归档（FR-EDIT-31）

    /// 是否把执行过的 SQL 自动归档成当天的 `.sql` 文件（默认关闭，需先选目录）。
    @Published var isSQLArchiveEnabled: Bool =
        UserDefaults.standard.object(forKey: "sqlArchive.enabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(isSQLArchiveEnabled, forKey: "sqlArchive.enabled") }
    }

    /// 归档面板是否呈现。
    @Published var isSQLArchivePresented = false

    /// 归档目录的当前状态（界面直接显示整句）。
    @Published private(set) var sqlArchiveStatus: DirectoryAccessStatus?

    /// 归档根目录的来源：单独指定 / 跟随工作区 / 没有（FR-EDIT-32 衔接）。
    @Published private(set) var sqlArchiveSource: ArchiveLocation.Source = .none

    /// 工作区路径的提供者（由 App 层注入；AppState 不该直接依赖工作区存储）。
    var workspacePathProvider: (() -> String?)?

    /// 归档目录的书签**单独存一个文件**，免得出现在数据任务面板的「使用已授权目录」列表里。
    private let sqlArchiveBookmarks = DirectoryBookmarkStore(fileName: "sql-archive-bookmark.json")

    /// 写入串行化：两次执行几乎同时结束时不至于互相覆盖。
    private let sqlArchiveWriter = SQLArchiveWriter()
    /// App 侧调度 tick（Core 的 `TaskScheduler` 不启定时器、只做纯时间计算）。
    private var dataTaskTicker: Task<Void, Never>?
    /// 已提交审批、等待人工决定的任务执行（审批单 id → 待办）。
    private var pendingDataTaskRuns: [UUID: PendingDataTaskRun] = [:]
    /// 已尝试过的计划时刻：**同一个时间点不会被反复补跑**（错过窗口默认不自动补跑的落地）。
    private var dataTaskLastAttempts: [UUID: Date] = [:]
    /// 上次成功执行时刻（调度器判重依据；从执行历史重建，不额外落盘）。
    private var dataTaskLastSuccessfulRuns: [UUID: Date] = [:]

    /// 调度宽限：计划时间过去不超过 5 分钟算「到点」按计划执行；
    /// 超过 5 分钟的算「错过」——**只提示、不自动补跑**（客户端可能整天没打开，
    /// 一开就补跑十几个写库任务的风险远大于收益，见 Core 的 `TaskScheduler` 注释）。
    static let dataTaskGrace: TimeInterval = 300
    /// 调度 tick 间隔。
    static let dataTaskTickInterval: Duration = .seconds(30)

    // MARK: 高危语句保护（FR-EXEC-16）

    /// Safe Mode 开关；默认开启（安全默认）。用 `UserDefaults` 记住，与语言偏好同一套做法。
    @Published var isSafeModeEnabled: Bool =
        UserDefaults.standard.object(forKey: ExecutionSafetyDefaults.safeModeKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isSafeModeEnabled, forKey: ExecutionSafetyDefaults.safeModeKey) }
    }
    /// 是否连普通写操作也要确认（默认关：凡事弹窗会让人闭眼点继续）。
    @Published var isConfirmAllWritesEnabled: Bool =
        UserDefaults.standard.object(forKey: ExecutionSafetyDefaults.confirmAllWritesKey) as? Bool ?? false {
        didSet { UserDefaults.standard.set(isConfirmAllWritesEnabled, forKey: ExecutionSafetyDefaults.confirmAllWritesKey) }
    }
    /// 被拦下、等待确认的执行请求；`nil` 表示没有待确认项。
    @Published var pendingExecution: PendingExecution?

    /// 运行范围（FR-EXEC-14）：整篇 / 光标所在语句 / 选中片段。用 `UserDefaults` 记住。
    @Published var executionScope: ExecutionScope.Mode =
        ExecutionScope.Mode(rawValue: UserDefaults.standard.string(forKey: "execution.scope") ?? "") ?? .all {
        didSet { UserDefaults.standard.set(executionScope.rawValue, forKey: "execution.scope") }
    }

    // MARK: 下方面板（结果 / 问题 / 输出 / 终端 / 调试控制台）

    /// 下方面板是否显示。用 `UserDefaults` 记住，与 Safe Mode / 运行范围同一套做法。
    @Published var isLowerPaneVisible: Bool =
        UserDefaults.standard.object(forKey: "ui.lowerPaneVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isLowerPaneVisible, forKey: "ui.lowerPaneVisible") }
    }

    /// 下方面板是否最大化（占满编辑区，编辑器让位）。同样用 `UserDefaults` 记住。
    @Published var isLowerPaneMaximized: Bool =
        UserDefaults.standard.object(forKey: "ui.lowerPaneMaximized") as? Bool ?? false {
        didSet { UserDefaults.standard.set(isLowerPaneMaximized, forKey: "ui.lowerPaneMaximized") }
    }

    /// 当前选中的下方面板页签。
    @Published var lowerPaneTab: LowerPaneTab =
        LowerPaneTab(rawValue: UserDefaults.standard.string(forKey: "ui.lowerPaneTab") ?? "") ?? .problem {
        didSet { UserDefaults.standard.set(lowerPaneTab.rawValue, forKey: "ui.lowerPaneTab") }
    }

    /// 某个页签当前生效的连接：优先用它自己最近一次执行用的连接，否则退回左侧选中的连接。
    ///
    /// 编辑器与下方面板的问题页签都要用它算诊断，所以收成一处。
    func connection(for tab: QueryTab) -> ConnectionConfig? {
        if let connectionID = tab.connectionID,
           let connection = connections.first(where: { $0.id == connectionID }) {
            return connection
        }
        return selectedConnection
    }

    /// 读取一张表的结构（列 / 类型 / 可空 / 默认值 / 主键），供表结构编辑器算差异。
    func tableStructure(of object: DatabaseObject) async throws -> [TableColumnDefinition] {
        guard let configuration = selectedConnection else {
            throw AppError.notConnected
        }
        let database = object.database ?? currentDatabaseName(for: configuration)
        let metadata = try await makeMetadataService(configuration: configuration, database: database)
        return try await metadata.tableStructure(of: object)
    }

    /// 把编辑后的列定义与原始结构比对，生成并**逐条**执行 `ALTER TABLE`（FR-DDL-03）。
    ///
    /// 逐条执行而不是拼成一整段：失败时能指出是第几条，使用者知道"改到哪儿断了"。
    /// 已经执行的语句**不回滚**（DDL 在多数方言里本就不可回滚），这一点在界面提示里讲清楚。
    func alterTable(
        _ object: DatabaseObject,
        from original: [TableColumnDefinition],
        to edited: [TableColumnDefinition]
    ) async -> Bool {
        guard let configuration = selectedConnection else {
            errorMessage = L(.stateSelectConnectionFirst)
            return false
        }

        let changes = TableDesign.columnChanges(original: original, edited: edited)
        let statements = SQLGenerator.alterTableStatements(
            table: object.name,
            schema: object.schema,
            changes: changes,
            dialect: SQLDialectFactory.make(for: configuration.dbType)
        )
        guard !statements.isEmpty else { return true }

        do {
            let database = object.database ?? currentDatabaseName(for: configuration)
            let service = try await ensureService(for: configuration, database: database)
            for (index, statement) in statements.enumerated() {
                do {
                    _ = try await runSingleQuery(statement, on: service)
                } catch {
                    errorMessage = L(.tableDesignAlterFailed, index + 1, ErrorPresenter.message(for: error))
                    metadataRevision += 1 // 前面几条可能已经生效，让对象树刷新
                    return false
                }
            }

            statusMessage = L(.tableDesignAltered, object.name, "\(changes.count)")
            metadataRevision += 1
            return true
        } catch {
            errorMessage = L(.tableDesignAlterFailed, 1, ErrorPresenter.message(for: error))
            return false
        }
    }

    // MARK: - 新建表（FR-DDL-03）

    /// 按表设计生成并执行 `CREATE TABLE`。
    ///
    /// 与建库 / 删库同一套路：本地先校验 → 生成语句 → 执行 → 成功后 `metadataRevision += 1`
    /// 让对象树把新表刷出来。**界面会先把 DDL 摊开给使用者看**，所以这里不再二次确认。
    func createTable(
        named rawName: String,
        schema: String?,
        columns: [TableColumnDefinition]
    ) async -> Bool {
        guard let configuration = selectedConnection else {
            errorMessage = L(.stateSelectConnectionFirst)
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TableDesign.validate(tableName: name, columns: columns).isEmpty else {
            errorMessage = L(.tableDesignInvalid)
            return false
        }

        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        let trimmedSchema = schema?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql = SQLGenerator.createTable(
            table: name,
            columns: columns,
            schema: (trimmedSchema?.isEmpty ?? true) ? nil : trimmedSchema,
            dialect: dialect
        )

        do {
            let service = try await ensureService(
                for: configuration,
                database: currentDatabaseName(for: configuration)
            )
            _ = try await runSingleQuery(sql, on: service)

            statusMessage = L(.tableDesignCreated, name)
            metadataRevision += 1
            return true
        } catch {
            errorMessage = L(.tableDesignFailed, ErrorPresenter.message(for: error))
            return false
        }
    }

    /// 清空当前下方面板页签对应的日志（Problem / Output 页签上的「清空」）。
    func clearLowerPaneLog(for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        switch lowerPaneTab {
        case .problem: tabs[index].problemLog = TabLog.cleared()
        case .output: tabs[index].outputLog = TabLog.cleared()
        case .terminal, .debugConsole: break
        }
    }

    /// 当前生效的执行安全策略。
    var executionSafetyPolicy: ExecutionSafetyPolicy {
        ExecutionSafetyPolicy(
            isEnabled: isSafeModeEnabled,
            confirmAllWrites: isConfirmAllWritesEnabled
        )
    }

    /// 用户点了「仍然执行」。
    func confirmPendingExecution() async {
        guard let pending = pendingExecution else { return }
        pendingExecution = nil
        await executeQuery(for: pending.tabID, bypassingSafetyCheck: true)
    }

    /// 用户点了「取消」。
    func cancelPendingExecution() {
        pendingExecution = nil
    }

    /// 运行范围无法满足时的可读提示（不静默改成跑整篇）。
    private func message(forRunScopeIssue issue: ExecutionScope.Resolution.Issue) -> String {
        switch issue {
        case .emptySelection: return L(.runScopeEmptySelection)
        case .noStatementAtCursor: return L(.runScopeNoStatement)
        case .emptyText: return L(.runScopeEmptyText)
        }
    }

    @Published var errorMessage: String?
    @Published var statusMessage: String = L(.stateNotConnected)

    private let store = ConnectionStore.shared
    // 口令存**项目内的混淆文件**（`.secrets/credentials.json`），不用系统钥匙串：
    // 钥匙串每次访问都要人工授权系统密码，远程 / IM 遥控开发时等于把自动化堵死。
    // 安全边界见 `Core/LocalSecretStore.swift`：MD5 派生密钥做 XOR 混淆 —— **是混淆不是加密**，
    // 只用于开发 / 验收形态；发布形态切回系统凭据存储只需把这里换成 `KeychainSecretStore()`
    // （实现仍在 `Platform/macOS/KeychainSecretStore.swift`）。
    private let secretStore: SecretStore = FileSecretStore()
    private let savedQueryStore = SavedQueryStore.shared
    private let agentConfigurationStore = AgentConfigurationStore.shared
    private let agentKeyStore: AgentKeyStore = FileAgentKeyStore()
    /// 审计日志（追加式 JSONL）；导出前脱敏在 Core 里完成（NFR-AI-03）。
    private let agentAuditLog = AgentAuditLog.shared
    private let egressLog = EgressLog.shared
    /// 浏览器页签的会话持久化（恢复**不自动请求**，见 `BrowserTabStore` 的说明）。
    private let browserTabStore = BrowserTabStore.shared
    /// 引擎是否已经为某个页签发过请求 —— 用来区分「恢复出来还没加载」与「已在浏览」。
    @Published var browserEngineLoadedPageIDs: Set<UUID> = []


    /// 连接缓存键：同一个「已保存连接」可以在多个数据库上各持有一条连接。
    struct ServiceKey: Hashable {
        let connectionID: UUID
        let database: String
    }

    /// 事务上下文：**按「连接 + 数据库」归属**（FR-EXEC-15）。
    ///
    /// 事务属于连接会话而不是页签：同一连接下的多个页签共用一条连接，因此也共用同一个事务。
    /// 这也是界面必须把它显示出来的原因 —— 在别的页签里提交 / 回滚，会影响你手上这条语句。
    @Published private(set) var transactionSessions: [ServiceKey: TransactionSession] = [:]

    private var services: [ServiceKey: any DatabaseService] = [:]
    private var serverInfos: [UUID: ServerInfo] = [:]
    private var connectTasks: [ServiceKey: Task<(any DatabaseService, ServerInfo), Error>] = [:]
    private var executionTasks: [UUID: Task<Void, Never>] = [:]
    /// 每个页签当前这次执行的句柄：停止按钮据此**定向取消**，
    /// 而不是把同库另一个页签正在跑的语句一起干掉（R-30）。
    private var executionHandles: [UUID: ExecutionHandle] = [:]

    /// 新建查询页签的编号：应用生命周期内只增不减（关闭 / 重命名不影响）。
    private var tabNumbers = TabNumberGenerator()

    /// 「上次选中的连接」持久化键（FR-CONN-11）。
    private static let selectedConnectionDefaultsKey = "settings.selectedConnectionID"

    /// 历史条数上限，避免长时间运行后无限增长。
    private static let historyLimit = 50

    init() {
        let firstTab = QueryTab(title: L(.workspaceTabTitle, tabNumbers.next()))
        tabs = [firstTab]
        selectedTabID = firstTab.id
        Task {
            await loadConnections()
            await loadSavedQueries()
            await restoreBrowserTabs()
        }
    }

    /// 恢复上次的浏览器页签：**只恢复地址与历史，不发起任何请求**。
    ///
    /// 恢复完不自动选中它们 —— 用户上次在写 SQL，就该回到 SQL（选中态不持久化是刻意的：
    /// 把"上次在看某个网页"当成默认状态，反而会在启动时把一个空白浏览器推到眼前）。
    private func restoreBrowserTabs() async {
        do {
            browserPages = try await browserTabStore.load()
        } catch {
            // 文件损坏之类：如实说出来，但不要打断启动。
            statusMessage = ErrorPresenter.message(for: error)
        }
    }

    /// 任何页签变化都落盘（失败只提示，不影响使用）。
    private func persistBrowserTabs() {
        let pages = browserPages
        Task {
            do {
                try await browserTabStore.save(pages)
            } catch {
                statusMessage = ErrorPresenter.message(for: error)
            }
        }
    }

    var selectedConnection: ConnectionConfig? {
        connections.first { $0.id == selectedConnectionID }
    }

    var selectedTab: QueryTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func serverInfo(for connectionID: UUID) -> ServerInfo? {
        serverInfos[connectionID]
    }

    func loadConnections() async {
        do {
            // 迁移与提示一起处理（FR-CONN-10）：老格式静默升级，来自更新版本的配置
            // 必须**说出来** —— 否则用户只会看到"我的连接怎么少字段了"（见 R-40）。
            let (loaded, migration) = try await store.loadWithReport()
            connections = loaded
            if migration.didMigrate {
                statusMessage = L(.connectionMigrated, migration.migrated.count)
            }
            if migration.didSkipNewer {
                let versions = migration.skippedNewerVersions.keys.sorted().map(String.init).joined(separator: "、")
                errorMessage = L(.connectionNewerVersionKept, versions)
            }
            canCreateDatabase = nil
            if selectedConnectionID == nil {
                // 上次选中的连接仍然存在时优先恢复（FR-CONN-11），否则退回第一条。
                selectedConnectionID = restoredConnectionID(in: connections) ?? connections.first?.id
            }
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    func addConnection(_ configuration: ConnectionConfig, password: String) async {
        do {
            try secretStore.setPassword(password, for: configuration.id)
            // 与 deleteConnection 同理：内存变更一次做完再落盘，
            // 否则 await 会把它拆成两轮渲染（列表先更新、选中项再跳）。
            connections.append(configuration)
            selectedConnectionID = configuration.id
            try await store.save(connections)
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    func updateConnection(_ configuration: ConnectionConfig, password: String?) async {
        do {
            if let password, !password.isEmpty {
                try secretStore.setPassword(password, for: configuration.id)
            }

            invalidateService(for: configuration.id)

            if let index = connections.firstIndex(where: { $0.id == configuration.id }) {
                connections[index] = configuration
            } else {
                connections.append(configuration)
            }
            selectedConnectionID = configuration.id
            try await store.save(connections)
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    /// 只在值真的变了才写 `@Published`。
    ///
    /// 给 `@Published` 赋一个**相同的值**同样会触发一次重绘；删除连接时这类白刷会叠加成
    /// 肉眼可见的抖动，所以状态重置类赋值统一走这里。
    private func setIfChanged<T: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AppState, T>,
        _ value: T
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    // MARK: - 上次选中的连接

    private func restoredConnectionID(in connections: [ConnectionConfig]) -> ConnectionConfig.ID? {
        guard let raw = UserDefaults.standard.string(forKey: Self.selectedConnectionDefaultsKey),
              let id = UUID(uuidString: raw),
              connections.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    private func rememberSelectedConnection() {
        guard let selectedConnectionID else {
            UserDefaults.standard.removeObject(forKey: Self.selectedConnectionDefaultsKey)
            return
        }
        UserDefaults.standard.set(
            selectedConnectionID.uuidString,
            forKey: Self.selectedConnectionDefaultsKey
        )
    }

    // MARK: - 查询历史（内存态）

    func clearQueryHistory() {
        queryHistory.removeAll()
    }

    /// 把历史 SQL 载入指定页签。
    func loadHistory(_ entry: QueryHistory, into tabID: UUID) {
        updateTab(tabID) {
            $0.sql = entry.sql
            $0.fileURL = nil
            $0.isDirty = true
        }
    }

    /// 读取归档目录书签并刷新状态（界面打开归档面板时调用）。
    func refreshSQLArchiveStatus() async {
        do {
            let bookmark = try await sqlArchiveBookmarks.all().first
            let chosenStatus = bookmark.map { MacDirectoryAccess.status(for: $0) }
            // **优先级：单独指定 > 工作区 > 没有**（判定收在 Core 的 ArchiveLocation，可单测）
            guard let resolved = ArchiveLocation.queriesDirectory(
                chosenPath: chosenStatus?.path,
                workspacePath: workspacePathProvider?()
            ) else {
                sqlArchiveSource = .none
                sqlArchiveStatus = .notAuthorized
                return
            }
            sqlArchiveSource = resolved.source
            switch resolved.source {
            case .chosen:
                sqlArchiveStatus = chosenStatus
            case .workspace:
                // 跟随工作区时**没有归档自己的书签**，但工作区的书签已经授权了这块位置。
                sqlArchiveStatus = .granted(path: resolved.url.path, isStale: false)
            case .none:
                sqlArchiveStatus = .notAuthorized
            }
        } catch {
            sqlArchiveSource = .none
            sqlArchiveStatus = .resolutionFailed(reason: ErrorPresenter.message(for: error))
        }
    }

    /// 让用户选归档目录（**取消不是错误**，只是什么都不做）。
    func chooseSQLArchiveDirectory() async {
        do {
            guard let url = try dataTaskDirectoryPicker.pickDirectory(prompt: L(.archiveChooseDirectory))
            else { return }
            let bookmark = try MacDirectoryAccess.makeBookmark(for: url, displayName: L(.archiveTitle))
            _ = try await sqlArchiveBookmarks.save(bookmark)
            await refreshSQLArchiveStatus()
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    /// 归档目录路径（展示用；没授权时为 nil）。
    var sqlArchiveDirectoryPath: String? {
        sqlArchiveStatus?.path
    }

    /// 把一次执行写进当天归档。
    ///
    /// **归档失败绝不影响执行结果** —— 只把可读原因写进状态栏：
    /// 一个"顺手存文件"的功能不该让查询看起来失败了。
    private func archiveExecutedSQL(
        sql: String,
        configuration: ConnectionConfig,
        database: String?,
        duration: TimeInterval,
        affectedRows: Int?,
        succeeded: Bool,
        note: String?
    ) {
        guard isSQLArchiveEnabled else { return }

        let entry = SQLArchiveEntry(
            sql: sql,
            firstExecutedAt: Date(),
            lastExecutedAt: Date(),
            connection: configuration.displayTitle(untitled: L(.connectionUntitled)),
            database: database ?? "",
            durationSeconds: duration,
            affectedRows: affectedRows,
            succeeded: succeeded,
            note: note
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                // 单独指定过归档目录就用它；否则跟随工作区（判定见 ArchiveLocation）。
                var grant: DirectoryGrant?
                defer { grant?.stopAccessing() }
                var chosenPath: String?
                if let bookmark = try await self.sqlArchiveBookmarks.all().first {
                    let opened = try MacDirectoryAccess.open(bookmark)
                    grant = opened
                    chosenPath = opened.url.path
                }
                guard let resolved = ArchiveLocation.queriesDirectory(
                    chosenPath: chosenPath,
                    workspacePath: self.workspacePathProvider?()
                ) else { return }

                // 归档落在 queries/ 子目录，避免和数据任务产物、以及工作区里的代码混在一起。
                let count = try await self.sqlArchiveWriter.append(entry, in: resolved.url)
                self.statusMessage = L(.archiveSaved, resolved.url.deletingLastPathComponent().lastPathComponent, count)
            } catch {
                self.statusMessage = L(.archiveFailed, ErrorPresenter.message(for: error))
            }
        }
    }

    private func recordHistory(
        sql: String,
        connectionID: UUID,
        duration: TimeInterval,
        succeeded: Bool,
        affectedRows: Int? = nil,
        note: String? = nil
    ) {
        // 归档放在这个**单一收口点**：成功与失败两条路径都会经过这里，
        // 不必在别处再补一遍（补必漏）。
        if let configuration = connections.first(where: { $0.id == connectionID }) {
            archiveExecutedSQL(
                sql: sql,
                configuration: configuration,
                database: selectedDatabase,
                duration: duration,
                affectedRows: affectedRows,
                succeeded: succeeded,
                note: note
            )
        }

        // 连续重复执行同一条 SQL 时只刷新最新一条，避免刷屏。
        if let first = queryHistory.first,
           first.sql == sql,
           first.connectionID == connectionID {
            queryHistory[0].executedAt = Date()
            queryHistory[0].duration = duration
            queryHistory[0].succeeded = succeeded
            return
        }

        let entry = QueryHistory(
            connectionID: connectionID,
            sql: sql,
            duration: duration,
            succeeded: succeeded
        )
        queryHistory.insert(entry, at: 0)

        if queryHistory.count > Self.historyLimit {
            queryHistory.removeLast(queryHistory.count - Self.historyLimit)
        }
    }

    // MARK: - 结果导出（FR-RES-06）

    /// 导出当前页签的当前结果集。没有可导出内容时返回 false，由调用方提示。
    @discardableResult
    func exportResult(
        for tabID: UUID,
        format: ResultExportFormat
    ) async -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let result = tab.result else {
            errorMessage = L(.exportNoData)
            return false
        }

        guard ResultExporter.hasExportableContent(result) else {
            errorMessage = L(.exportNoData)
            return false
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let baseName = tab.fileURL?.deletingPathExtension().lastPathComponent
            ?? ResultExportFormat.csv.defaultBaseName
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        // INSERT 语句需要表名与方言：表名取页签标题（文件名为准，导出后由用户确认），
        // 方言按该页签绑定的连接决定（未绑定连接时退回 SQL 标准双引号）。
        let text = ResultExporter.text(
            for: result,
            format: format,
            tableName: tab.fileURL == nil ? "table_name" : baseName,
            dialect: connections
                .first { $0.id == tab.connectionID }
                .map { SQLDialectFactory.make(for: $0.dbType) }
        )
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = L(.exportSucceeded, result.rowCount, url.lastPathComponent)
            return true
        } catch {
            errorMessage = L(.exportFailed, ErrorPresenter.message(for: error))
            return false
        }
    }

    func deleteConnection(_ configuration: ConnectionConfig) async {
        do {
            try secretStore.deletePassword(for: configuration.id)
            invalidateService(for: configuration.id)

            // 内存里的两处变更**必须在同一次同步执行里做完**，落盘推到它们之后。
            // 原先的顺序是「先删列表 → await 落盘 → 再改选中项」：那个 await 会把
            // 「列表里已经没有它、选中项还指着它」的中间状态交给界面渲染一次，
            // 于是侧栏选中行瞬间指向一个不存在的行再跳到别的行 —— 就是删除连接时
            // 界面连闪的来源（实测一次删除会出现 4 次这种中间状态）。
            let wasSelected = selectedConnectionID == configuration.id
            connections.removeAll { $0.id == configuration.id }
            if wasSelected {
                selectedConnectionID = connections.first?.id
            }

            try await store.save(connections)
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    func password(for configuration: ConnectionConfig) -> String? {
        do {
            if let fileStore = secretStore as? FileSecretStore {
                // 多候选之后，"口令读不到"必须能自己说清是在哪儿找的 ——
                // 否则沙箱构建读不到项目内那份时，只能靠人猜（本轮就踩过这个坑）。
                if let password = try fileStore.password(for: configuration.id) {
                    return password
                }
                let searched = fileStore.searchedLocations().map(\.path).joined(separator: "、")
                errorMessage = L(.stateMissingPassword) + "\n" + L(.statePasswordSearched, searched)
                return nil
            }
            return try secretStore.password(for: configuration.id)
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
            return nil
        }
    }

    // MARK: - 元数据（对象树）

    // MARK: - 对象树：连接 / 断开 / 建库权限（FR-META-11）

    /// 当前连接是否已建立（对象树根部以此决定菜单里「连接 / 断开」的可用性）。
    var isObjectTreeConnected: Bool {
        guard let configuration = selectedConnection else { return false }
        return services.keys.contains { $0.connectionID == configuration.id }
    }

    /// 右键菜单「连接」：按当前连接/数据库建立连接，并顺带刷新建库权限。
    func connectObjectTree() async {
        guard let configuration = selectedConnection else {
            errorMessage = L(.stateSelectConnectionFirst)
            return
        }

        do {
            let database = currentDatabaseName(for: configuration)
            _ = try await ensureService(for: configuration, database: database)
            statusMessage = L(
                .objectTreeStatusConnected,
                configuration.displayTitle(untitled: L(.connectionUntitled))
            )
            await refreshDatabaseCreationPermission()
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    /// 右键菜单「断开」：释放该连接的所有服务实例（含对象树按需建立的其它库连接）。
    func disconnectObjectTree() async {
        guard let configuration = selectedConnection else { return }

        invalidateService(for: configuration.id)
        serverInfos[configuration.id] = nil
        canCreateDatabase = nil
        statusMessage = L(
            .objectTreeStatusDisconnected,
            configuration.displayTitle(untitled: L(.connectionUntitled))
        )
    }

    /// 探测「当前用户能否创建数据库」，结果写入 `canCreateDatabase`（FR-META-11）。
    ///
    /// 探测失败或方言不支持时置为 nil：按「未知 = 不呈现」处理，避免给出会失败的入口。
    func refreshDatabaseCreationPermission() async {
        guard let configuration = selectedConnection else {
            canCreateDatabase = nil
            return
        }

        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        guard let query = dialect.databaseCreationPrivilegeQuery() else {
            canCreateDatabase = nil
            return
        }

        do {
            let service = try await ensureService(
                for: configuration,
                database: currentDatabaseName(for: configuration)
            )
            let result = try await runSingleQuery(query, on: service)
            canCreateDatabase = PrivilegeProbe.databaseCreationAllowed(
                from: result.rows.first?.first ?? nil
            )
        } catch {
            canCreateDatabase = nil
        }
    }

    /// 右键菜单「新建数据库」：执行 `CREATE DATABASE`，成功后刷新数据库列表与对象树。
    @discardableResult
    func createDatabase(named rawName: String) async -> Bool {
        guard let configuration = selectedConnection else {
            errorMessage = L(.stateSelectConnectionFirst)
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PrivilegeProbe.isValidDatabaseName(name) else {
            errorMessage = L(.createDatabaseInvalid)
            return false
        }

        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        let sql = "CREATE DATABASE \(dialect.quoteIdentifier(name))"

        do {
            let service = try await ensureService(
                for: configuration,
                database: currentDatabaseName(for: configuration)
            )
            _ = try await runSingleQuery(sql, on: service)

            statusMessage = L(.createDatabaseSucceeded, name)
            await loadDatabases()
            metadataRevision += 1
            return true
        } catch {
            errorMessage = L(.createDatabaseFailed, ErrorPresenter.message(for: error))
            return false
        }
    }

    /// 「库属性…」/「删除数据库…」的目标库：优先上下文栏选择，其次连接配置里的库。
    ///
    /// 服务器节点本身不带数据库，因此入口必须以「当前正在用的库」为目标，
    /// 而不是猜一个名字。
    var adminTargetDatabase: String? {
        guard let configuration = selectedConnection else { return nil }
        let selected = selectedDatabase?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selected, !selected.isEmpty { return selected }
        let configured = currentDatabaseName(for: configuration)
        return configured.isEmpty ? nil : configured
    }

    // MARK: - 库属性 / 删除数据库（FR-SESS-05）

    /// 生成 `ALTER DATABASE` 语句，供界面**执行前预览**（不执行）。
    func alterDatabaseStatements(
        name: String,
        alterations: SQLGenerator.DatabaseAlterations
    ) -> String? {
        guard let configuration = selectedConnection else { return nil }
        return SQLGenerator.alterDatabase(
            name: name,
            alterations: alterations,
            dialect: SQLDialectFactory.make(for: configuration.dbType)
        )
    }

    /// 执行 `ALTER DATABASE`（FR-SESS-05）；成功后刷新数据库列表与对象树。
    @discardableResult
    func alterDatabase(
        name: String,
        alterations: SQLGenerator.DatabaseAlterations
    ) async -> Bool {
        guard let configuration = selectedConnection else {
            errorMessage = L(.stateSelectConnectionFirst)
            return false
        }
        guard let sql = alterDatabaseStatements(name: name, alterations: alterations) else {
            errorMessage = L(.dbPropsInvalid)
            return false
        }

        do {
            let service = try await ensureService(
                for: configuration,
                database: currentDatabaseName(for: configuration)
            )
            try await runStatements(sql, databaseType: configuration.dbType, on: service)

            statusMessage = L(.dbPropsSucceeded, name)
            await loadDatabases()
            metadataRevision += 1
            return true
        } catch {
            errorMessage = L(.dbPropsFailed, ErrorPresenter.message(for: error))
            return false
        }
    }

    /// 生成 `DROP DATABASE` 语句，供界面**执行前预览**（不执行）。
    func dropDatabaseStatement(name: String, ifExists: Bool = true) -> String? {
        guard let configuration = selectedConnection else { return nil }
        return SQLGenerator.dropDatabase(
            name: name,
            ifExists: ifExists,
            dialect: SQLDialectFactory.make(for: configuration.dbType)
        )
    }

    /// 执行 `DROP DATABASE`（FR-SESS-05）。
    ///
    /// 调用方必须先完成「手输库名」二次确认；这里只负责执行与**可读的错误归类**
    /// （「还有其他会话连接」等由 `DatabaseAdminHint` 翻成整句提示）。
    @discardableResult
    func dropDatabase(name: String) async -> Bool {
        guard let configuration = selectedConnection else {
            errorMessage = L(.stateSelectConnectionFirst)
            return false
        }
        guard let sql = dropDatabaseStatement(name: name) else {
            errorMessage = L(.createDatabaseInvalid)
            return false
        }

        do {
            let service = try await ensureService(
                for: configuration,
                database: currentDatabaseName(for: configuration)
            )
            try await runStatements(sql, databaseType: configuration.dbType, on: service)

            statusMessage = L(.dropDbSucceeded, name)
            await loadDatabases()
            metadataRevision += 1
            return true
        } catch {
            errorMessage = L(.dropDbFailed, dropDatabaseFailureReason(error))
            return false
        }
    }

    /// 把删库失败归类成可读原因；无法归类时回退为原始错误文本。
    private func dropDatabaseFailureReason(_ error: Error) -> String {
        let raw = ErrorPresenter.message(for: error)
        switch DatabaseAdminHint.classify(serverMessage: raw) {
        case .activeConnections:
            return L(.dropDbActiveConnections)
        case .currentDatabase:
            return L(.dropDbCurrentDatabase)
        case .databaseDoesNotExist:
            return L(.dropDbNotExist)
        case .insufficientPrivilege:
            return L(.dropDbNoPrivilege)
        case nil:
            return raw
        }
    }

    // MARK: - 对象权限（FR-SESS-04）

    /// 查询指定角色在当前库上的已授权限；方言不支持时抛可读错误。
    func loadObjectPrivileges(role rawRole: String) async throws -> [ObjectPrivilege] {
        guard let configuration = selectedConnection else {
            throw AppError.notConnected
        }

        let role = rawRole.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PrivilegeProbe.isValidRoleName(role) else {
            throw AppError.queryFailed(L(.privilegeInvalidRole))
        }

        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        guard let query = dialect.objectPrivilegeQuery(role: role) else {
            throw AppError.notImplemented(L(.privilegeUnsupported))
        }

        let service = try await ensureService(
            for: configuration,
            database: currentDatabaseName(for: configuration)
        )
        let result = try await runSingleQuery(query, on: service)
        return ObjectPrivilegeParser.privileges(from: result)
    }

    /// 生成 `GRANT` / `REVOKE` 语句，供界面**执行前预览**（不执行）。
    func privilegeStatement(
        _ change: SQLGenerator.PrivilegeChange,
        revoke: Bool
    ) -> String? {
        guard let configuration = selectedConnection else { return nil }
        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        return revoke
            ? SQLGenerator.revoke(change, dialect: dialect)
            : SQLGenerator.grant(change, dialect: dialect)
    }

    /// 执行 `GRANT` / `REVOKE`（FR-SESS-04；界面已先展示预览 SQL）。
    @discardableResult
    func applyPrivilegeChange(
        _ change: SQLGenerator.PrivilegeChange,
        revoke: Bool
    ) async -> Bool {
        guard let configuration = selectedConnection else {
            errorMessage = L(.stateSelectConnectionFirst)
            return false
        }
        guard let sql = privilegeStatement(change, revoke: revoke) else {
            errorMessage = L(.privilegeInvalid)
            return false
        }

        do {
            let service = try await ensureService(
                for: configuration,
                database: currentDatabaseName(for: configuration)
            )
            try await runStatements(sql, databaseType: configuration.dbType, on: service)
            statusMessage = L(.privilegeSucceeded)
            return true
        } catch {
            errorMessage = L(.privilegeFailed, ErrorPresenter.message(for: error))
            return false
        }
    }

    // MARK: - 智能体接入配置（FR-AI-01）

    /// 读取智能体配置与 Key 状态（进入面板 / 启动时调用）。
    ///
    /// 配置读失败不弹错误框：退回安全默认即可（关掉开关不会外发任何东西），
    /// 把原因留在状态栏，避免一个坏文件把整个界面卡在错误弹窗里。
    func loadAgentConfiguration() async {
        do {
            agentConfiguration = try await agentConfigurationStore.load()
        } catch {
            agentConfiguration = .default
            statusMessage = L(.agentSaveFailed, ErrorPresenter.message(for: error))
        }

        // 钥匙串不可用时（未签名 / 无授权）按「没有 Key」处理，不阻断界面。
        let key = (try? agentKeyStore.apiKey()) ?? nil
        agentAPIKey = key
        hasAgentAPIKey = !(key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// 保存智能体配置；`apiKey` 传 `nil` 表示不改动已保存的 Key，传空串表示清除。
    @discardableResult
    func saveAgentConfiguration(_ configuration: AgentConfiguration, apiKey: String?) async -> Bool {
        do {
            try await agentConfigurationStore.save(configuration)
            agentConfiguration = configuration
        } catch {
            errorMessage = L(.agentSaveFailed, ErrorPresenter.message(for: error))
            return false
        }

        if let apiKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                if trimmed.isEmpty {
                    try agentKeyStore.deleteAPIKey()
                    agentAPIKey = nil
                    hasAgentAPIKey = false
                } else {
                    try agentKeyStore.setAPIKey(trimmed)
                    agentAPIKey = trimmed
                    hasAgentAPIKey = true
                }
            } catch {
                // 配置已存下、Key 没存下：如实告知，不要把失败吞掉。
                errorMessage = L(.agentSaveFailed, ErrorPresenter.message(for: error))
                return false
            }
        }

        statusMessage = L(.agentSaved)
        return true
    }

    // MARK: - 审批与审计（FR-AI-09 / NFR-AI-03）

    /// 当前生效的护栏 / 审批策略：只读模式与白名单来自配置（FR-AI-09）。
    var agentGuardPolicy: AgentGuardPolicy { agentConfiguration.effectiveGuardPolicy }

    /// 保存只读模式与白名单（复用配置持久化，不另开一份存储）。
    @discardableResult
    func saveAgentGuardPolicy(_ policy: AgentGuardPolicy) async -> Bool {
        var configuration = agentConfiguration
        configuration.guardPolicy = policy.sanitized
        let succeeded = await saveAgentConfiguration(configuration, apiKey: nil)
        if succeeded {
            agentAuditMessage = L(.agentGuardSaved)
        }
        return succeeded
    }

    /// 读取本地审计日志（打开面板 / 刷新 / 清空后调用）。
    ///
    /// 顺带用日志重建待审批队列：审计是追加式的，重启后内存队列会空，
    /// 但日志里「待批准」那条还挂着 —— 按「同一动作取最后一条」恢复，
    /// 界面上才不会出现「日志说待批准、列表却说没有」。
    func refreshAgentAudit() async {
        isAgentAuditLoading = true
        defer { isAgentAuditLoading = false }
        do {
            agentAuditRecords = try await agentAuditLog.entries()
            pendingAgentApprovals = AgentApproval.pending(from: agentAuditRecords)
            agentAuditError = nil
        } catch {
            agentAuditError = L(.agentAuditLoadFailed, ErrorPresenter.message(for: error))
        }
    }

    /// 清空本地审计记录（界面必须二次确认后才会调用）。
    func clearAgentAudit() async {
        do {
            try await agentAuditLog.removeAll()
            agentAuditRecords = []
            agentAuditError = nil
            agentAuditMessage = L(.agentAuditCleared)
        } catch {
            agentAuditError = L(.agentAuditLoadFailed, ErrorPresenter.message(for: error))
        }
    }

    /// 导出审计记录（JSON / CSV）。
    ///
    /// **导出内容完全由 Core 生成**（`AgentAuditLog.export(_:)` → 已过
    /// `AgentAudit.redacted`），界面只负责选路径与写文件 —— 不在这里另拼一份导出，
    /// 否则「导出前脱敏」就成了看遵守不遵守的君子协定。
    @discardableResult
    // MARK: - 统一外发日志（NFR-SEC-08）

    /// 读取外发日志（新的在前）。
    func refreshEgressLog() async {
        do {
            egressEntries = try await egressLog.entries()
            egressError = nil
        } catch {
            egressError = ErrorPresenter.message(for: error)
        }
    }

    /// 清空外发日志（二次确认在界面上做）。
    func clearEgressLog() async {
        do {
            try await egressLog.clear()
            egressEntries = []
            egressMessage = L(.egressCleared)
            egressError = nil
        } catch {
            egressError = ErrorPresenter.message(for: error)
        }
    }

    /// 导出外发日志（JSON / CSV）。
    func exportEgressLog(asCSV: Bool) async -> Bool {
        guard !egressEntries.isEmpty else {
            egressError = L(.egressExportEmpty)
            return false
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let baseName = asCSV ? "egress-log" : "egress-log"
        let ext = asCSV ? "csv" : "json"
        panel.nameFieldStringValue = "\(baseName).\(ext)"
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            let data: Data = asCSV
                ? Data(try await egressLog.exportCSV().utf8)
                : try await egressLog.exportJSON()
            try data.write(to: url, options: [.atomic])
            egressError = nil
            egressMessage = L(.egressExported, egressEntries.count, url.lastPathComponent)
            return true
        } catch {
            egressError = L(.egressExportFailed, ErrorPresenter.message(for: error))
            return false
        }
    }

    func exportAgentAudit(format: AgentAuditExportFormat) async -> Bool {
        guard !agentAuditRecords.isEmpty else {
            agentAuditError = L(.agentAuditExportEmpty)
            return false
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(format.defaultBaseName).\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            let data = try await agentAuditLog.export(format)
            try data.write(to: url, options: [.atomic])
            agentAuditError = nil
            agentAuditMessage = L(.agentAuditExported, agentAuditRecords.count, url.lastPathComponent)
            return true
        } catch {
            agentAuditError = L(.agentAuditExportFailed, ErrorPresenter.message(for: error))
            return false
        }
    }

    /// 智能体发起一次动作：过护栏 → 建审批单 / 直接拒绝 → **留痕**（FR-AI-09）。
    ///
    /// 行为边界值得写清楚：本方法**只判定与留痕，不执行**。
    /// - 只读模式下被拒的写操作 / DDL：连审批单都建不出来（`AgentActionGate` 返回 `.denied`），
    ///   只留一条 `denied` 记录并给出可读原因（AC-AI-02）；
    /// - 需要审批的：进待审批队列并弹出审批单，**批准之前不会执行**；
    /// - 无需审批的（只读查询 / 白名单类别）：返回 `.approved`，由调用方决定怎么处理，
    ///   `AgentSQLPanel` 仍走「放进新页签」——不自动执行（FR-AI-02）。
    @discardableResult
    func submitAgentAction(_ sql: String) async -> AgentActionSubmission {
        let submission = AgentActionGate.submit(
            sql: sql,
            databaseType: selectedConnection?.dbType ?? .postgresql,
            policy: agentGuardPolicy,
            context: agentActionContext
        )

        await appendAgentAudit(submission.record)

        switch submission {
        case .denied:
            agentAuditError = submission.message
        case .approved:
            agentAuditError = nil
        case .awaitingApproval(let approval):
            agentAuditError = nil
            pendingAgentApprovals.append(approval)
            agentApprovalRequest = approval
        }
        return submission
    }

    /// 批准并执行一条待审批动作（审批单上的「批准并执行」）。
    func approveAgentAction(id: UUID, note: String? = nil) async {
        await decideAgentAction(id: id, approve: true, note: note)
    }

    /// 拒绝一条待审批动作：**不执行**，留痕。
    func rejectAgentAction(id: UUID, note: String? = nil) async {
        await decideAgentAction(id: id, approve: false, note: note)
    }

    /// 重新弹出某条待审批动作的审批单（面板里点「查看…」）。
    func presentAgentApproval(_ approval: AgentApproval) {
        guard approval.awaitsHumanDecision else { return }
        agentApprovalRequest = approval
    }

    /// 关掉审批单但不做决定：动作**留在待审批队列里**，关窗不等于批准。
    func dismissAgentApprovalSheet() {
        agentApprovalRequest = nil
    }

    /// 审计记录的上下文：连接名 / 库 / 模型（**不含口令，也不含完整连接串**）。
    private var agentActionContext: AgentActionRecord.Context {
        AgentActionRecord.Context(
            connectionName: selectedConnection?.name,
            database: selectedConnection.map { queryDatabase(for: $0) },
            model: agentConfiguration.normalizedModel
        )
    }

    // MARK: - 浏览器页签动作

    var selectedBrowserPage: BrowserPage? {
        browserPages.first { $0.id == selectedBrowserID }
    }

    /// 新建浏览器页签。**默认打开空白页** —— 不加载任何远程内容（契约）。
    @discardableResult
    func openBrowserTab() -> UUID {
        let page = BrowserPage()
        browserPages.append(page)
        selectedBrowserID = page.id
        persistBrowserTabs()
        return page.id
    }

    func selectBrowserTab(_ id: UUID) {
        guard browserPages.contains(where: { $0.id == id }) else { return }
        selectedBrowserID = id
    }

    func closeBrowserTab(_ id: UUID) {
        browserPages.removeAll { $0.id == id }
        browserEngines[id] = nil
        browserEngineLoadedPageIDs.remove(id)
        persistBrowserTabs()
        if selectedBrowserID == id {
            selectedBrowserID = browserPages.last?.id
        }
    }

    /// 取（或建）该页签的引擎。视图每次重绘都会调用它，所以必须是幂等的。
    func browserEngine(for page: BrowserPage) -> WebKitBrowserEngine {
        if let existing = browserEngines[page.id] {
            return existing
        }
        let engine = WebKitBrowserEngine(pageID: page.id, origin: "浏览器 · 页签")
        // 引擎回报的状态（加载中 / 标题 / 地址 / 失败原因）写回模型 —— 否则切页签或重绘后
        // 界面就停在旧状态；`setUpdateHandler` 在主线程回调，直接转发即可。
        engine.setUpdateHandler { [weak self] updated in
            self?.applyBrowserUpdate(updated)
            if !updated.isLoading, updated.url != nil {
                self?.browserEngineLoadedPageIDs.insert(updated.id)
            }
        }
        browserEngines[page.id] = engine
        return engine
    }

    /// 把引擎回报的状态写回模型（引擎在主线程回调，这里只做转发）。
    func applyBrowserUpdate(_ page: BrowserPage) {
        guard let index = browserPages.firstIndex(where: { $0.id == page.id }) else { return }
        browserPages[index] = page
        // 标题 / 地址变化也落盘：否则下次恢复出来的是上次启动时的旧地址。
        persistBrowserTabs()
    }

    /// 这个页签是否已经加载过（false = 从会话里恢复出来、还没发过请求）。
    func isBrowserPagePristine(_ id: UUID) -> Bool {
        !browserEngineLoadedPageIDs.contains(id)
    }

    /// 地址栏提交：解析 → 交给引擎（引擎内部先过 Core 策略、再写外发日志）。
    func navigateBrowserTab(_ id: UUID, input: String) {
        guard let page = browserPages.first(where: { $0.id == id }) else { return }
        switch BrowserSession.parseAddress(input) {
        case .success(let url):
            let engine = browserEngine(for: page)
            Task { await engine.load(url) }
        case .failure(let error):
            var rejected = page
            rejected.rejectNavigation(reason: error.reason)
            applyBrowserUpdate(rejected)
        }
    }

    /// 在浏览器里打开某个地址（供「用浏览器打开」这类入口复用）。
    func openInBrowser(_ text: String) {
        let id = browserPages.contains(where: { $0.id == selectedBrowserID })
            ? selectedBrowserID!
            : openBrowserTab()
        navigateBrowserTab(id, input: text)
    }

    /// 追加一条审计记录：先落到内存（面板立刻看得见），再追加到 JSONL。
    /// 写盘失败必须说出来 —— 审计写不进去是安全问题，不能静默吞掉。
    private func appendAgentAudit(_ record: AgentActionRecord) async {
        agentAuditRecords.append(record)
        do {
            try await agentAuditLog.append(record)
        } catch {
            agentAuditError = L(.agentAuditLoadFailed, ErrorPresenter.message(for: error))
        }
    }

    /// 审批决策：状态机流转 → （批准时）执行 → 追加终态记录。
    private func decideAgentAction(id: UUID, approve: Bool, note: String?) async {
        guard let index = pendingAgentApprovals.firstIndex(where: { $0.id == id }) else { return }
        var approval = pendingAgentApprovals[index]

        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteValue = (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote

        do {
            if approve {
                try approval.approve(by: NSUserName(), note: noteValue)
            } else {
                try approval.reject(by: NSUserName(), note: noteValue)
            }
        } catch {
            // 非法流转（例如已被处理过）不猜、不硬改，照实报错。
            agentAuditError = ErrorPresenter.message(for: error)
            return
        }

        pendingAgentApprovals.remove(at: index)
        if agentApprovalRequest?.id == id { agentApprovalRequest = nil }

        if approve {
            // R-27（2026-09-23 评审）：**先落审计，再执行**。
            //
            // 执行是不可逆的；原来是先执行、后追加终态记录 —— 进程若在两者之间死掉，
            // 日志里就什么都没有：一次真打到库上的写操作，审计上等于没发生过。
            // 现在先写一条「已批准」（这本身就是必须留痕的事实），写不进去就**不执行**。
            do {
                try await agentAuditLog.append(approval.record)
                agentAuditRecords.append(approval.record)
            } catch {
                let message = L(.agentAuditLoadFailed, ErrorPresenter.message(for: error))
                try? approval.markFailed(detail: message)
                agentAuditError = message
                if let pending = pendingDataTaskRuns.removeValue(forKey: id) {
                    await failDataTaskRun(pending, message: message)
                }
                await appendAgentAudit(approval.record)
                return
            }

            // R-26（同日评审）：**执行必须绑在审批时的那条连接上**。
            //
            // 审批单上写的是哪台库，执行时就该打哪台库；原来用的是"当前选中连接" ——
            // 批准之后切一下连接，同一条语句就落到生产上了。这是最不该有的错配。
            let current = agentActionContext
            let connectionMismatch = approval.record.connectionName != nil
                && approval.record.connectionName != current.connectionName
            let databaseMismatch = approval.record.database != nil
                && current.database != nil
                && approval.record.database != current.database
            if connectionMismatch || databaseMismatch {
                let message = L(
                    .agentApprovalConnectionMismatch,
                    approval.record.connectionName ?? "—",
                    current.connectionName ?? "—"
                )
                try? approval.markFailed(detail: message)
                agentAuditError = message
                if let pending = pendingDataTaskRuns.removeValue(forKey: id) {
                    await failDataTaskRun(pending, message: message)
                }
                await appendAgentAudit(approval.record)
                return
            }

            do {
                let rowsWritten = try await executeApprovedAgentAction(approval.record.sql)
                try approval.markExecuted()
                agentAuditError = nil
                agentAuditMessage = L(.agentApprovalApproved)
                // 数据任务的执行要接着收尾（导出产物 + 记执行历史）。
                if let pending = pendingDataTaskRuns.removeValue(forKey: id) {
                    await finishApprovedDataTaskRun(pending, rowsWritten: rowsWritten)
                }
            } catch {
                // 批准了但执行失败：记为 `failed`，失败原因进审计（不是静默失败）。
                let message = ErrorPresenter.message(for: error)
                try? approval.markFailed(detail: message)
                agentAuditError = L(.errorQueryFailed, message)
                if let pending = pendingDataTaskRuns.removeValue(forKey: id) {
                    await failDataTaskRun(pending, message: message)
                }
            }
        } else {
            agentAuditError = nil
            agentAuditMessage = L(.agentApprovalRejected)
            if let pending = pendingDataTaskRuns.removeValue(forKey: id) {
                await skipDataTaskRun(pending, message: L(.dataTaskRunRejected))
            }
        }

        await appendAgentAudit(approval.record)
    }

    /// 已获批准的数据任务执行收尾：导出产物 → 记一条执行历史。
    private func finishApprovedDataTaskRun(_ pending: PendingDataTaskRun, rowsWritten: Int?) async {
        var artifactName: String?
        var artifactFailure: String?
        if pending.task.output != nil {
            do {
                artifactName = try await exportDataTaskArtifact(pending.task)
            } catch {
                artifactFailure = ErrorPresenter.message(for: error)
            }
        }

        let message = artifactName.map { L(.dataTaskRunSucceeded, rowsWritten ?? 0, $0) }
            ?? L(.dataTaskRunSucceededNoArtifact, rowsWritten ?? 0)

        await recordDataTaskRun(
            task: pending.task,
            plannedAt: pending.plannedAt,
            startedAt: pending.startedAt,
            status: .succeeded,
            rowsWritten: rowsWritten,
            message: message
        )

        if let artifactFailure {
            dataTaskError = L(.dataTaskRunArtifactFailed, artifactFailure)
            dataTaskMessage = message
        } else {
            dataTaskError = nil
            dataTaskMessage = message
        }
    }

    /// 执行一条**已获批准**的智能体语句，复用既有的连接与逐条下发路径；
    /// 返回影响行数合计（没有该事件时为 `nil`），供执行历史记录「写入行数」。
    private func executeApprovedAgentAction(_ sql: String) async throws -> Int? {
        guard let configuration = selectedConnection else { throw AppError.notConnected }
        let service = try await ensureService(
            for: configuration,
            database: queryDatabase(for: configuration)
        )
        return try await runStatementsCountingAffected(
            sql,
            databaseType: configuration.dbType,
            on: service
        )
    }

    /// 与 `runStatements` 同一条下发路径，额外把影响行数累加起来。
    private func runStatementsCountingAffected(
        _ sql: String,
        databaseType: DatabaseType,
        on service: any DatabaseService
    ) async throws -> Int? {
        let statements = StatementSplitter(databaseType: databaseType).split(sql)
        var tally = AffectedRowsTally()
        for statement in statements {
            for try await event in service.execute(statement.sql, options: .default) {
                tally.absorb(event)      // 计数只有这一处（R-32）
            }
        }
        return tally.value
    }

    /// 供模型参考的 schema 摘要（NFR-AI-01：只有结构，没有行数据）。
    ///
    /// 取表清单走**一条**查询（方言的 `listTablesQuery`），并把数量封顶 ——
    /// 「最小外发」不只是不发结果集，也包括别把上千张表一股脑倒出去。
    func agentSchemaSummary(includeTableList: Bool) async throws -> AgentSQLGenerator.SchemaSummary {
        guard let configuration = selectedConnection else {
            throw AppError.notConnected
        }
        let database = currentDatabaseName(for: configuration)
        guard includeTableList else {
            return AgentSQLGenerator.SchemaSummary(database: database, tables: [])
        }

        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        let service = try await ensureService(for: configuration, database: database)
        let result = try await runSingleQuery(dialect.listTablesQuery(database: database, schema: nil), on: service)
        // 列名兼容两套命名（PG 的 information_schema 用 table_name，GBase 的 SHOW TABLES 用第一列）；
        // 这里只认表名这一列，避免把整行原样外发。
        let nameIndex = result.columns.firstIndex { column in
            ["table_name", "name", "tables_in_" + database.lowercased()].contains(
                column.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        } ?? (result.columns.isEmpty ? nil : 0)
        // 有 table_schema 就用它（不同方言 / 版本给不给这一列不一样，缺了就退回方言默认）。
        let schemaIndex = result.columns.firstIndex {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "table_schema"
        }

        guard let nameIndex else {
            return AgentSQLGenerator.SchemaSummary(database: database, tables: [])
        }

        let listed = result.rows.prefix(Self.agentTableListLimit).compactMap { row -> (name: String, schema: String?)? in
            guard nameIndex < row.count,
                  let raw = row[nameIndex],
                  case let name = raw.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            var schema: String?
            if let schemaIndex, schemaIndex < row.count, let rawSchema = row[schemaIndex] {
                let trimmed = rawSchema.trimmingCharacters(in: .whitespacesAndNewlines)
                schema = trimmed.isEmpty ? nil : trimmed
            }
            return (name, schema)
        }

        // 补列：**模型看不到列名就写不准查询**，所以列才是 schema 摘要里最有用的部分。
        // 同时封两道口子——表数与总列数都设上限，避免一次外发把整库结构倒出去（NFR-AI-01）。
        var tables: [AgentSQLGenerator.SchemaSummary.Table] = []
        var columnBudget = Self.agentColumnBudget

        for entry in listed {
            guard columnBudget > 0 else {
                tables.append(AgentSQLGenerator.SchemaSummary.Table(schema: entry.schema, name: entry.name))
                continue
            }
            let specs = (try? await agentColumnSpecs(
                table: entry.name,
                schema: entry.schema,
                database: database,
                configuration: configuration,
                dialect: dialect
            )) ?? []
            let columns = specs.prefix(columnBudget).map {
                AgentSQLGenerator.SchemaSummary.Column(name: $0.name, type: $0.typeName)
            }
            columnBudget -= columns.count
            tables.append(
                AgentSQLGenerator.SchemaSummary.Table(
                    schema: entry.schema,
                    name: entry.name,
                    columns: Array(columns)
                )
            )
        }

        return AgentSQLGenerator.SchemaSummary(database: database, tables: tables)
    }

    /// 取某张表的列（供 schema 摘要外发使用）；失败返回空数组，不让整次生成失败。
    private func agentColumnSpecs(
        table: String,
        schema: String?,
        database: String,
        configuration: ConnectionConfig,
        dialect: any SQLDialect
    ) async throws -> [ColumnMeta] {
        let service = try await ensureService(for: configuration, database: database)
        let result = try await runSingleQuery(
            dialect.listColumnsQuery(table: table, schema: schema),
            on: service
        )
        return ColumnSpecParser.columns(from: result)
    }

    /// 表清单外发上限（防止把上千张表发出去）。
    static let agentTableListLimit = 60
    /// 列信息外发总量上限（按列累计，超出后的表只发表名）。
    static let agentColumnBudget = 400

    /// 走完整条「自然语言 → SQL」通道；产物是文本，**不会被自动执行**（FR-AI-02）。
    func generateAgentSQL(
        instruction: String,
        schema: AgentSQLGenerator.SchemaSummary,
        currentStatement: String?
    ) async throws -> AgentSQLGenerator.Result {
        let started = Date()
        do {
            let result = try await AgentSQLGenerator.generate(
                request: AgentSQLGenerator.Request(
                    instruction: instruction,
                    schema: schema,
                    currentStatement: currentStatement
                ),
                configuration: agentConfiguration,
                apiKey: agentAPIKey,
                // 只读模式 / 白名单来自配置（FR-AI-09），不再写死默认策略。
                policy: agentGuardPolicy,
                ledger: .empty,
                client: OpenAICompatibleClient(
                    transport: EgressRecordingTransport(
                        origin: "智能体 · 用自然语言生成 SQL",
                        wrapped: URLSessionTransport()
                    )
                )
            )
            await recordAgentModelCall(summary: instruction, outcome: .generated, since: started)
            return result
        } catch {
            // 失败的调用同样留痕：审计要能回答「哪次调用失败了、花了多久」（NFR-AI-03）。
            await recordAgentModelCall(
                summary: instruction,
                outcome: .failed,
                since: started,
                detail: ErrorPresenter.message(for: error)
            )
            throw error
        }
    }

    /// 模型调用留痕（NFR-AI-03：模型 / 请求摘要 / 耗时 / 结果状态）。
    ///
    /// 用的是与动作提交同一份审计日志与同一个上下文（连接 / 库 / 模型，**不含口令**），
    /// 所以导出、筛选、清空、脱敏全都自动生效，不需要为「模型调用」另开一条存储。
    private func recordAgentModelCall(
        summary: String,
        outcome: AgentActionRecord.Outcome,
        since start: Date,
        detail: String? = nil
    ) async {
        let record = AgentActionRecord.makeModelCall(
            requestSummary: summary,
            model: nil,                      // 上下文里已经带了模型名
            context: agentActionContext,
            durationMilliseconds: Int(Date().timeIntervalSince(start) * 1000),
            outcome: outcome,
            detail: detail
        )
        await appendAgentAudit(record)
    }

    /// 把生成结果放进**新页签**的编辑器里（不覆盖用户正在写的内容，也不执行）。
    func openGeneratedSQLInNewTab(_ sql: String) {
        openSQLInNewTab(sql, status: L(.agentSQLNotExecuted))
    }

    /// 走完整条「规格说明 → 数据任务定义」通道（FR-AI-05）；产物是**定义草案**，
    /// 既不保存也不执行 —— 保存要过试运行 + 校验，执行要走审批（FR-AI-09）。
    func generateDataTaskSpec(
        specs: String,
        schema: AgentSQLGenerator.SchemaSummary,
        hints: String?
    ) async throws -> DataTaskSpecGenerator.Result {
        let started = Date()
        do {
            let result = try await DataTaskSpecGenerator.generate(
                request: DataTaskSpecGenerator.Request(specs: specs, schema: schema, hints: hints),
                configuration: agentConfiguration,
                apiKey: agentAPIKey,
                // 只读模式 / 白名单来自配置（FR-AI-09），与其它智能体路径同一份策略。
                policy: agentGuardPolicy,
                ledger: .empty,
                client: OpenAICompatibleClient(
                    transport: EgressRecordingTransport(
                        origin: "智能体 · 数据任务规格",
                        wrapped: URLSessionTransport()
                    )
                )
            )
            await recordAgentModelCall(summary: specs, outcome: .generated, since: started)
            return result
        } catch {
            await recordAgentModelCall(
                summary: specs,
                outcome: .failed,
                since: started,
                detail: ErrorPresenter.message(for: error)
            )
            throw error
        }
    }

    /// 把生成的 SQL 放进**新页签**的编辑器：不覆盖用户正在写的内容，也不执行（FR-META-14）。
    func openSQLInNewTab(_ sql: String, status: String? = nil) {
        newQueryTab()
        guard let tabID = selectedTabID else { return }
        updateSQL(sql, for: tabID)
        statusMessage = status ?? L(.objectTreeOpenedInNewTab)
    }

    /// 当前是否允许外发，以及原因（界面与后续 AI 功能共用这一处判定）。
    var agentOutboundDecision: AgentOutboundDecision {
        AgentGate.decide(configuration: agentConfiguration, apiKey: agentAPIKey)
    }

    // MARK: - 数据任务（FR-AI-05 / FR-AI-06 / FR-AI-08）

    /// 当前连接对应的方言（数据任务的 SQL 编译与护栏判定都用它）。
    var dataTaskDialect: any SQLDialect {
        SQLDialectFactory.make(for: selectedConnection?.dbType ?? .postgresql)
    }

    // MARK: 读取与保存

    /// 读取任务定义、执行历史与已授权目录（启动 / 打开面板 / 刷新时调用）。
    func loadDataTasks() async {
        do {
            dataTasks = try await dataTaskStore.tasks()
        } catch {
            dataTasks = []
            dataTaskError = L(.dataTaskLoadFailed, ErrorPresenter.message(for: error))
        }
        await reloadDataTaskRuns()
        storedDirectoryBookmarks = (try? await directoryBookmarkStore.all()) ?? []
    }

    /// 只刷新执行历史（顺带重建「上次成功执行时刻」）。
    func reloadDataTaskRuns() async {
        do {
            dataTaskRuns = try await dataTaskStore.runs()
        } catch {
            dataTaskRuns = []
            dataTaskError = L(.dataTaskLoadFailed, ErrorPresenter.message(for: error))
        }

        var lastSuccess: [UUID: Date] = [:]
        for record in dataTaskRuns where record.status == .succeeded {
            if let previous = lastSuccess[record.taskID], previous >= record.startedAt { continue }
            lastSuccess[record.taskID] = record.startedAt
        }
        dataTaskLastSuccessfulRuns = lastSuccess
    }

    /// 保存任务定义；**定义不合法就不写盘**（界面同时会禁用保存按钮）。
    @discardableResult
    func saveDataTask(_ task: DataTaskDefinition) async -> Bool {
        guard task.isValid else {
            dataTaskError = L(.dataTaskSaveBlocked)
            return false
        }
        return await persistDataTask(task, successMessage: L(.dataTaskSaved, task.name))
    }

    /// 删除任务定义（不动执行历史 —— 历史是审计材料，删了就无法追溯）。
    @discardableResult
    func deleteDataTask(id: UUID) async -> Bool {
        let name = dataTasks.first { $0.id == id }?.name ?? ""
        do {
            try await dataTaskStore.delete(id: id)
            dataTasks.removeAll { $0.id == id }
            dataTaskDecisions[id] = nil
            dataTaskError = nil
            dataTaskMessage = L(.dataTaskDeleted, name)
            return true
        } catch {
            dataTaskError = L(.dataTaskDeleteFailed, ErrorPresenter.message(for: error))
            return false
        }
    }

    /// 停用 / 恢复任务（FR-AI-06 的「可暂停 / 停用」）。
    func setDataTaskEnabled(_ isEnabled: Bool, id: UUID) async {
        guard var task = dataTasks.first(where: { $0.id == id }) else { return }
        task.isEnabled = isEnabled
        _ = await persistDataTask(task, successMessage: nil)
    }

    /// 上次成功执行时刻（面板用它算「下次执行」）。
    func dataTaskLastSuccessfulRun(for taskID: UUID) -> Date? {
        dataTaskLastSuccessfulRuns[taskID]
    }

    /// 某个任务当前的调度判定；没 tick 过时给一个即时判定（不写状态）。
    func dataTaskDecision(for task: DataTaskDefinition, now: Date = Date()) -> ScheduleDecision {
        dataTaskDecisions[task.id]
            ?? TaskScheduler.decision(
                for: task,
                now: now,
                lastRun: dataTaskLastSuccessfulRuns[task.id],
                grace: Self.dataTaskGrace
            )
    }

    /// 写盘并把内存里的那份同步成「落盘后的版本」（`updatedAt` 会变）。
    @discardableResult
    private func persistDataTask(_ task: DataTaskDefinition, successMessage: String?) async -> Bool {
        do {
            let stored = try await dataTaskStore.save(task)
            if let index = dataTasks.firstIndex(where: { $0.id == stored.id }) {
                dataTasks[index] = stored
            } else {
                dataTasks.append(stored)
            }
            dataTaskError = nil
            if let successMessage { dataTaskMessage = successMessage }
            return true
        } catch {
            dataTaskError = L(.dataTaskSaveFailed, ErrorPresenter.message(for: error))
            return false
        }
    }

    // MARK: 目录授权（FR-AI-08）

    /// 让用户选一个目录并授权（`NSOpenPanel` → security-scoped bookmark）。
    ///
    /// **用户取消不是错误**：返回 `nil`，面板什么都不做。
    func chooseDataTaskExportDirectory(
        displayName: String,
        format: DataTaskDefinition.ExportSettings.Format,
        fileNameTemplate: String?
    ) async -> DataTaskDefinition.ExportSettings? {
        dataTaskError = nil
        do {
            guard let settings = try MacDirectoryAccess.requestExportSettings(
                prompt: L(.dataTaskChooseDirectory),
                format: format,
                fileNameTemplate: fileNameTemplate,
                picker: dataTaskDirectoryPicker
            ) else { return nil }

            await rememberDirectoryBookmark(from: settings, displayName: displayName)
            return settings
        } catch {
            // 未授权 / 创建书签失败：给可读原因与补救建议，绝不静默。
            dataTaskError = ErrorPresenter.message(for: error)
            return nil
        }
    }

    /// 用已经授权过的目录作为任务的导出目录（不重新弹面板）。
    func dataTaskExportSettings(
        using bookmark: DirectoryBookmark,
        format: DataTaskDefinition.ExportSettings.Format,
        fileNameTemplate: String?
    ) -> DataTaskDefinition.ExportSettings {
        DataTaskDefinition.ExportSettings(
            format: format,
            directoryBookmark: bookmark.bookmarkData,
            fileNameTemplate: fileNameTemplate
        )
    }

    /// 当前授权状态；`nil` = 任务还没设导出目录。
    func dataTaskDirectoryStatus(
        _ settings: DataTaskDefinition.ExportSettings?
    ) -> DirectoryAccessStatus? {
        guard let settings, let bookmark = MacDirectoryAccess.bookmark(from: settings) else {
            return nil
        }
        return MacDirectoryAccess.status(for: bookmark)
    }

    /// 验证授权目录真的可写：把「任务定义 + 试运行预览」写成一份说明文件。
    ///
    /// 刻意**不碰数据库**：这条路径只验证「书签 → 解析 → 写文件」，因此在没有可达实例时
    /// 也能证明 FR-AI-08 的接线是通的。
    @discardableResult
    func verifyDataTaskExportDirectory(_ task: DataTaskDefinition) async -> Bool {
        guard let settings = task.output,
              let bookmark = MacDirectoryAccess.bookmark(from: settings)
        else {
            dataTaskError = DataTaskRunError.missingExportSettings.errorDescription
            return false
        }

        do {
            let grant = try MacDirectoryAccess.open(bookmark)
            defer { grant.stopAccessing() }
            let url = try DataTaskRunner.exportPreviewReport(
                for: task,
                preview: task.dryRun(dialect: dataTaskDialect),
                grant: grant
            )
            dataTaskError = nil
            dataTaskMessage = L(.dataTaskExportVerifySucceeded, url.lastPathComponent)
            return true
        } catch {
            dataTaskError = ErrorPresenter.message(for: error)
            return false
        }
    }

    /// 把新授权的书签记进 `directory-bookmarks.json`（同一目录就地更新，不重复堆积）。
    private func rememberDirectoryBookmark(
        from settings: DataTaskDefinition.ExportSettings,
        displayName: String
    ) async {
        guard var bookmark = MacDirectoryAccess.bookmark(from: settings, displayName: displayName) else {
            return
        }
        if case .granted(let path, _) = MacDirectoryAccess.status(for: bookmark) {
            bookmark.lastKnownPath = path
        }
        if let existing = storedDirectoryBookmarks.first(where: {
            $0.lastKnownPath != nil && $0.lastKnownPath == bookmark.lastKnownPath
        }) {
            bookmark.id = existing.id
        }
        try? await directoryBookmarkStore.save(bookmark)
        storedDirectoryBookmarks = (try? await directoryBookmarkStore.all()) ?? storedDirectoryBookmarks
    }

    // MARK: 调度 tick 与执行（FR-AI-06）

    /// 启动 App 侧调度 tick（幂等；在窗口出现时调用一次）。
    ///
    /// `TaskScheduler` 只做纯时间计算，这里负责「隔一会儿问一次」并把到点的任务送进审批流程。
    func startDataTaskTicker() {
        guard dataTaskTicker == nil else { return }
        dataTaskTicker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tickDataTasks()
                try? await Task.sleep(for: AppState.dataTaskTickInterval)
            }
        }
    }

    func stopDataTaskTicker() {
        dataTaskTicker?.cancel()
        dataTaskTicker = nil
    }

    /// 走一次调度判定：刷新界面状态，并把**到点**的任务按计划执行。
    ///
    /// 错过窗口（超过宽限）**不自动补跑**，只把 `.missed` 摆到界面上等用户确认。
    func tickDataTasks() async {
        guard !dataTasks.isEmpty else { return }
        let now = Date()

        for task in dataTasks {
            let lastRun = dataTaskLastSuccessfulRuns[task.id]
            let decision = TaskScheduler.decision(
                for: task,
                now: now,
                lastRun: lastRun,
                grace: Self.dataTaskGrace
            )
            dataTaskDecisions[task.id] = decision

            guard case .due(let plannedAt) = decision else { continue }
            // 同一个计划时刻只跑一次：审批被拒 / 执行失败都不会让它每 30 秒重试一遍。
            if let attempted = dataTaskLastAttempts[task.id], attempted >= plannedAt { continue }
            guard selectedConnection != nil else { continue }

            // 到点的写语句要人工批准，而审批单需要宿主视图：面板没开时先把它带到前台，
            // 下一个 tick（30 秒后，宽限 5 分钟足够）再提交，让审批单在面板里弹出来。
            // 否则「提交了但用户看不到任何窗口」，等于把审批悬在半空。
            guard isDataTaskPresented else {
                isDataTaskPresented = true
                statusMessage = L(.dataTaskDueNotice)
                continue
            }
            // 已经有一张审批单摆在界面上时先不叠加：同一个时刻只会提交一次（`dataTaskLastAttempts`），
            // 等用户处理完这张，下一个 tick 再推进其他到点任务。
            guard agentApprovalRequest == nil else { continue }

            dataTaskLastAttempts[task.id] = plannedAt
            await requestDataTaskRun(task, plannedAt: plannedAt, startedAt: now)
        }
    }

    /// 手动执行（「现在执行…」，包括错过窗口后用户确认执行）。
    func runDataTaskNow(_ task: DataTaskDefinition, plannedAt: Date? = nil) async {
        dataTaskMessage = nil
        await requestDataTaskRun(task, plannedAt: plannedAt, startedAt: Date())
    }

    /// 提交一次任务执行：**写语句先进 `AgentActionGate`**（FR-AI-09 的同一套审批与审计），
    /// 批准之前不会碰数据库。
    private func requestDataTaskRun(
        _ task: DataTaskDefinition,
        plannedAt: Date?,
        startedAt: Date
    ) async {
        guard selectedConnection != nil else {
            dataTaskError = L(.dataTaskRunNotConnected)
            return
        }
        guard task.isValid else {
            dataTaskError = L(.dataTaskRunFailed, ErrorPresenter.message(for: DataTaskRunError.invalidDefinition(task.issues)))
            return
        }

        let sql: String
        do {
            sql = try DataTaskRunner.writeStatementText(for: task, dialect: dataTaskDialect)
        } catch {
            dataTaskError = ErrorPresenter.message(for: error)
            return
        }

        let submission = await submitAgentAction(sql)
        let pending = PendingDataTaskRun(
            task: task,
            plannedAt: plannedAt,
            startedAt: startedAt,
            writeSQL: sql
        )

        switch submission {
        case .denied:
            // 只读模式 / 策略拒绝：**没有审批单**，但仍留一条失败记录（不静默）。
            let reason = submission.message
            dataTaskError = L(.dataTaskRunDenied, reason)
            await recordDataTaskRun(
                task: task,
                plannedAt: plannedAt,
                startedAt: startedAt,
                status: .failed,
                rowsWritten: nil,
                message: reason
            )

        case .awaitingApproval(let approval):
            // 审批单由 `submitAgentAction` 弹出（面板上挂着 `AgentApprovalSheet`）。
            pendingDataTaskRuns[approval.id] = pending
            dataTaskError = nil
            dataTaskMessage = L(.dataTaskRunPending)

        case .approved:
            // 白名单等免审批出口：直接执行。
            await executeApprovedDataTask(pending)
        }
    }

    /// 执行一条已获批的任务写入，随后（若配了导出目录）把产物写进授权目录并记执行历史。
    private func executeApprovedDataTask(_ pending: PendingDataTaskRun) async {
        do {
            let rowsWritten = try await executeApprovedAgentAction(pending.writeSQL)
            await finishApprovedDataTaskRun(pending, rowsWritten: rowsWritten)
        } catch {
            await failDataTaskRun(pending, message: ErrorPresenter.message(for: error))
        }
    }

    /// 读源表 → 按任务导出设置写进**授权目录**（目录来自书签解析，不硬编码）。
    private func exportDataTaskArtifact(_ task: DataTaskDefinition) async throws -> String {
        guard let settings = task.output,
              let bookmark = MacDirectoryAccess.bookmark(from: settings)
        else { throw DataTaskRunError.missingExportSettings }
        guard let configuration = selectedConnection else { throw AppError.notConnected }

        let grant = try MacDirectoryAccess.open(bookmark)
        defer { grant.stopAccessing() }

        let service = try await ensureService(
            for: configuration,
            database: queryDatabase(for: configuration)
        )
        let result = try await DataTaskRunner.read(
            task,
            on: service,
            dialect: dataTaskDialect
        )
        let url = try DataTaskRunner.exportArtifact(result, for: task, grant: grant)
        return url.lastPathComponent
    }

    private func failDataTaskRun(_ pending: PendingDataTaskRun, message: String) async {
        dataTaskError = L(.dataTaskRunFailed, message)
        await recordDataTaskRun(
            task: pending.task,
            plannedAt: pending.plannedAt,
            startedAt: pending.startedAt,
            status: .failed,
            rowsWritten: nil,
            message: message
        )
    }

    private func skipDataTaskRun(_ pending: PendingDataTaskRun, message: String) async {
        await recordDataTaskRun(
            task: pending.task,
            plannedAt: pending.plannedAt,
            startedAt: pending.startedAt,
            status: .skipped,
            rowsWritten: nil,
            message: message
        )
    }

    /// 追加一条执行历史（先落内存让面板立刻看得见，再写 `task-runs.jsonl`）。
    ///
    /// 写盘失败必须说出来：执行历史是「有执行记录与失败记录」的依据，静默丢掉等于没做。
    private func recordDataTaskRun(
        task: DataTaskDefinition,
        plannedAt: Date?,
        startedAt: Date,
        status: TaskRunRecord.Status,
        rowsWritten: Int?,
        message: String?
    ) async {
        let record = TaskRunRecord(
            taskID: task.id,
            plannedAt: plannedAt,
            startedAt: startedAt,
            finishedAt: Date(),
            status: status,
            rowsWritten: rowsWritten,
            message: message
        )
        dataTaskRuns.append(record)
        if status == .succeeded {
            dataTaskLastSuccessfulRuns[task.id] = startedAt
        }
        do {
            try await dataTaskStore.appendRun(record)
        } catch {
            dataTaskError = L(.dataTaskSaveFailed, ErrorPresenter.message(for: error))
        }
    }

    // MARK: - 执行计划（FR-DIAG-01）

    /// 对当前页签的语句跑 `EXPLAIN` 并解析成计划树。
    ///
    /// 只分析**第一条**语句（多条时给出提示）；`ANALYZE` 打开时会真正执行该语句 ——
    /// 界面必须显著提示，这里不做额外确认，因为用户是显式打开的开关。
    func runExecutionPlan(for tabID: UUID) async {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        guard let configuration = selectedConnection else {
            executionPlan = nil
            executionPlanError = L(.stateSelectConnectionFirst)
            return
        }

        let sql = tabs[tabIndex].sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else {
            executionPlan = nil
            executionPlanError = L(.stateSQLEmpty)
            return
        }

        let statements = StatementSplitter(databaseType: configuration.dbType)
            .split(sql)
            .map { $0.sql.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = statements.first else {
            executionPlan = nil
            executionPlanError = L(.stateSQLEmpty)
            return
        }

        let firstKeyword = firstKeyword(in: first)
        let explainable = ["SELECT", "INSERT", "UPDATE", "DELETE", "WITH", "VALUES", "TABLE"]
        guard explainable.contains(firstKeyword) else {
            executionPlan = nil
            executionPlanError = L(.planUnsupported)
            return
        }

        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        let explainSQL = SQLGenerator.explain(
            sql: first,
            analyze: planRunAnalyze,
            buffers: planIncludeBuffers,
            formatJSON: planUseJSON,
            dialect: dialect
        )

        executionPlanIsLoading = true
        executionPlanError = statements.count > 1 ? L(.planMultipleStatements, statements.count) : nil
        defer { executionPlanIsLoading = false }

        do {
            let service = try await ensureService(
                for: configuration,
                database: queryDatabase(for: configuration)
            )
            let result = try await runSingleQuery(explainSQL, on: service)
            // 文本格式是多行、每行一列；JSON 格式是一行一列，两种都按「逐行首列拼接」处理。
            let raw = result.rows.compactMap { $0.first ?? nil }.joined(separator: "\n")
            executionPlan = ExplainPlanParser.parse(raw)
        } catch {
            executionPlan = nil
            executionPlanError = L(.planFailed, ErrorPresenter.message(for: error))
        }
    }

    // MARK: - 对象树节点动作（FR-META-14 / FR-DATA-01 / FR-META-13）

    /// 取表 / 视图的列定义（含可空性）；供生成 DDL 与模板使用。
    ///
    /// 单独查一次而不是复用节点树里的列节点：树里的列信息只有类型名，
    /// 拿不到 `is_nullable` —— 少了它，导出的建表语句会悄悄丢掉 NOT NULL。
    func columnSpecs(for object: DatabaseObject) async throws -> [ColumnMeta] {
        guard let configuration = selectedConnection else {
            throw AppError.notConnected
        }
        let database = object.database ?? currentDatabaseName(for: configuration)
        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        let schema = object.schema ?? (configuration.dbType == .postgresql ? "public" : nil)

        let service = try await ensureService(for: configuration, database: database)
        let result = try await runSingleQuery(
            dialect.listColumnsQuery(table: object.name, schema: schema),
            on: service
        )
        return ColumnSpecParser.columns(from: result)
    }

    /// 执行一个对象树动作：生成 SQL 进新页签，或把文本复制到剪贴板。
    ///
    /// **一律不自动执行**；破坏性动作（清空 / 删除）也只是把语句写进编辑器，
    /// 真正运行时还会被 Safe Mode（FR-EXEC-16）再拦一次。
    func performTreeAction(_ action: ObjectTreeAction, on object: DatabaseObject) async {
        guard let configuration = selectedConnection else {
            errorMessage = L(.stateSelectConnectionFirst)
            return
        }
        let dialect = SQLDialectFactory.make(for: configuration.dbType)

        // 需要列的动作：按需加载；加载失败就退回「无列」由 Core 判定（生成 SELECT 仍可用，
        // 生成 INSERT / DDL 会明确失败并提示，而不是猜列）。
        var columns: [ColumnMeta] = []
        if action == .selectTemplate || action == .insertTemplate || action == .viewDDL {
            columns = (try? await columnSpecs(for: object)) ?? []
        }
        let target = ObjectTreeTarget(object: object, columns: columns)

        if let text = ObjectTreeActions.copiedText(for: action, target: target, dialect: dialect) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            statusMessage = L(.objectTreeCopied, text)
            return
        }

        guard let sql = ObjectTreeActions.sql(for: action, target: target, dialect: dialect) else {
            errorMessage = L(.treeActionUnavailable)
            return
        }
        openSQLInNewTab(sql)
    }

    // MARK: - 锁与阻塞链（FR-DIAG-05）

    /// 查询锁等待关系；方言不支持时抛可读错误。
    func loadLockWaits() async throws -> [LockWait] {
        guard let configuration = selectedConnection else {
            throw AppError.notConnected
        }

        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        guard let query = dialect.lockWaitingQuery() else {
            throw AppError.notImplemented(L(.lockUnsupported))
        }

        let service = try await ensureService(
            for: configuration,
            database: currentDatabaseName(for: configuration)
        )
        let result = try await runSingleQuery(query, on: service)
        return LockMonitor.waits(from: result)
    }

    // MARK: - 管理语句执行

    /// 逐条执行管理类语句。
    ///
    /// `ALTER DATABASE` 会被生成器拆成多条，因此走 `StatementSplitter` 逐条下发；
    /// 这类语句没有结果集，事件丢弃即可，服务端报错会从流里抛出。
    private func runStatements(
        _ sql: String,
        databaseType: DatabaseType,
        on service: any DatabaseService
    ) async throws {
        let statements = StatementSplitter(databaseType: databaseType).split(sql)
        for statement in statements {
            for try await _ in service.execute(statement.sql, options: .default) {}
        }
    }

    func loadMetadataRoot() async throws -> [DatabaseObject] {
        guard let configuration = selectedConnection else {
            throw AppError.notConnected
        }
        // 建库权限决定右键菜单是否呈现「新建数据库」；探测失败不影响对象树加载。
        await refreshDatabaseCreationPermission()

        let database = currentDatabaseName(for: configuration)
        let metadata = try await makeMetadataService(
            configuration: configuration,
            database: database
        )
        return try await metadata.loadRoot()
    }

    func loadMetadataChildren(of object: DatabaseObject) async throws -> [DatabaseObject] {
        guard let configuration = selectedConnection else {
            throw AppError.notConnected
        }
        // 表 / 列 / schema 节点自带所属数据库；服务器或数据库节点用当前库。
        let database = object.database ?? currentDatabaseName(for: configuration)
        let metadata = try await makeMetadataService(
            configuration: configuration,
            database: database
        )
        return try await metadata.loadChildren(of: object)
    }

    private func makeMetadataService(
        configuration: ConnectionConfig,
        database: String
    ) async throws -> MetadataService {
        let service = try await ensureService(for: configuration, database: database)
        return MetadataService(
            service: service,
            dialect: SQLDialectFactory.make(for: configuration.dbType),
            databaseName: database,
            serverLabel: serverLabel(for: configuration)
        )
    }

    private func currentDatabaseName(for configuration: ConnectionConfig) -> String {
        serverInfos[configuration.id]?.database ?? configuration.database
    }

    private func serverLabel(for configuration: ConnectionConfig) -> String {
        let name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? configuration.endpointDescription : "\(name) · \(configuration.endpointDescription)"
    }

    // MARK: - 服务器 / 数据库选择栏

    /// 枚举当前服务器上当前登录用户可连接的数据库（方言层按权限过滤）。
    func loadDatabases() async {
        guard let configuration = selectedConnection else {
            setIfChanged(\.availableDatabases, [])
            setIfChanged(\.selectedDatabase, nil)
            setIfChanged(\.databaseError, nil)
            return
        }

        setIfChanged(\.isLoadingDatabases, true)
        setIfChanged(\.databaseError, nil)
        defer { setIfChanged(\.isLoadingDatabases, false) }

        do {
            let service = try await ensureService(for: configuration)
            let dialect = SQLDialectFactory.make(for: configuration.dbType)
            let result = try await runSingleQuery(dialect.listDatabasesQuery(), on: service)

            let names = result.rows.compactMap { row -> String? in
                guard let value = row.first ?? nil, !value.isEmpty else { return nil }
                return value
            }
            setIfChanged(\.availableDatabases, names)

            let preferred = selectedDatabase
                ?? serverInfos[configuration.id]?.database
                ?? configuration.database

            if names.isEmpty {
                setIfChanged(\.selectedDatabase, configuration.database)
            } else if names.contains(preferred) {
                setIfChanged(\.selectedDatabase, preferred)
            } else {
                setIfChanged(\.selectedDatabase, serverInfos[configuration.id]?.database ?? names.first)
            }
        } catch {
            setIfChanged(\.availableDatabases, [])
            setIfChanged(\.databaseError, ErrorPresenter.message(for: error))
        }
    }

    /// 当前查询目标数据库：优先用户在上下文栏选择的库。
    private func queryDatabase(for configuration: ConnectionConfig) -> String {
        if let selectedDatabase, !selectedDatabase.isEmpty {
            return selectedDatabase
        }
        return currentDatabaseName(for: configuration)
    }

    private func runSingleQuery(_ sql: String, on service: any DatabaseService) async throws -> QueryResult {
        var lastResult: QueryResult?
        for try await event in service.execute(sql, options: .default) {
            if case .resultSet(let result) = event {
                lastResult = result
            }
        }
        guard let lastResult else {
            throw AppError.queryFailed(L(.stateQueryNoResultSet))
        }
        return lastResult
    }

    // MARK: - 保存的查询

    func loadSavedQueries() async {
        do {
            savedQueries = try await savedQueryStore.load().sorted { $0.savedAt > $1.savedAt }
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    /// 用 SQL 首行生成一个默认名称，方便直接保存。
    func suggestedQueryName(for tab: QueryTab) -> String {
        let firstLine = tab.sql
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let cleaned = firstLine
            .replacingOccurrences(of: "--", with: "")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty {
            return L(.workspaceTabTitle, savedQueries.count + 1)
        }
        return String(cleaned.prefix(30))
    }

    func saveCurrentQuery(for tabID: UUID, name: String) async {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }

        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalName.isEmpty else { return }

        let connectionID = tab.connectionID ?? selectedConnectionID
        let database = tab.database ?? selectedDatabase

        if let index = savedQueries.firstIndex(where: { $0.name == finalName }) {
            savedQueries[index].sql = tab.sql
            savedQueries[index].connectionID = connectionID
            savedQueries[index].database = database
            savedQueries[index].savedAt = Date()
        } else {
            savedQueries.append(
                SavedQuery(
                    name: finalName,
                    connectionID: connectionID,
                    database: database,
                    sql: tab.sql
                )
            )
        }

        savedQueries.sort { $0.savedAt > $1.savedAt }

        do {
            try await savedQueryStore.save(savedQueries)
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    func loadSavedQuery(_ query: SavedQuery, into tabID: UUID) {
        updateTab(tabID) {
            $0.sql = query.sql
            $0.syntaxCheckMessage = nil
            $0.syntaxCheckFailed = false
        }
    }

    func deleteSavedQuery(_ query: SavedQuery) async {
        savedQueries.removeAll { $0.id == query.id }
        do {
            try await savedQueryStore.save(savedQueries)
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    // MARK: - 查询文件（打开 / 保存）

    private static let noConnectionID = UUID()

    private static var textContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .sourceCode]
        if let sql = UTType(filenameExtension: "sql") {
            types.insert(sql, at: 0)
        }
        return types
    }

    /// 打开系统面板选择 SQL / 文本文件，内容载入新页签（默认不绑定连接）。
    func openFileFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.textContentTypes
        panel.message = L(.toolbarOpenFileHelp)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(at: url)
    }

    func openFile(at url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let tab = QueryTab(
                title: url.lastPathComponent,
                sql: text,
                fileURL: url
            )
            tabs.append(tab)
            selectedTabID = tab.id
            statusMessage = url.lastPathComponent
        } catch {
            errorMessage = L(.fileOpenFailed, error.localizedDescription)
        }
    }

    /// 保存当前页签：`forceSaveAs` 为 false 时优先写回原文件，否则弹「另存为」。
    func saveCurrentFile(for tabID: UUID, forceSaveAs: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        if !forceSaveAs, let url = tabs[index].fileURL {
            writeFile(tabAt: index, to: url)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.textContentTypes
        panel.nameFieldStringValue = tabs[index].fileURL?.lastPathComponent
            ?? "\(tabs[index].title).sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeFile(tabAt: index, to: url)
    }

    private func writeFile(tabAt index: Int, to url: URL) {
        do {
            try tabs[index].sql.write(to: url, atomically: true, encoding: .utf8)
            tabs[index].fileURL = url
            tabs[index].title = url.lastPathComponent
            tabs[index].isDirty = false
            statusMessage = L(.fileSaved, url.lastPathComponent)
        } catch {
            errorMessage = L(.fileSaveFailed, error.localizedDescription)
        }
    }

    /// 「未绑定连接」在服务器下拉里的占位 id。
    static var unboundConnectionID: UUID { noConnectionID }

    func newQueryTab() {
        let tab = QueryTab(title: L(.workspaceTabTitle, tabNumbers.next()))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func closeTab(_ tabID: UUID) {
        guard tabs.count > 1 else { return }
        guard !(tabs.first(where: { $0.id == tabID })?.isExecuting ?? false) else { return }
        EditorCommandCenter.shared.forgetSelection(tabID: tabID)
        tabs.removeAll { $0.id == tabID }
        if selectedTabID == tabID {
            selectedTabID = tabs.last?.id
        }
    }

    /// R-21：把结果区筛出的条件变成 `WHERE` **注入编辑器**（只改文本，**绝不自动执行**）。
    ///
    /// 拿不准就明说而不是硬插：已有 `WHERE`、多条语句、含 UNION 时都不动原语句，
    /// 只给一条提示 —— 悄悄改掉用户的查询比不做更糟。
    func applyClientFilterWhere(_ whereClause: String, for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        switch SQLFilterInjector.inject(whereClause: whereClause, into: tabs[index].sql) {
        case .injected(let newSQL):
            updateSQL(newSQL, for: tabID)
            statusMessage = L(.resultFilterWhereInjected)
        case .alreadyHasWhere:
            statusMessage = L(.resultFilterWhereAlreadyPresent)
        case .unsupported(let reason):
            statusMessage = L(.resultFilterWhereFailed, reason)
        }
    }

    // MARK: - 事务模式（FR-EXEC-15）

    /// 当前选中的查询页签（浏览器页签没有 SQL，不参与事务界面）。
    var activeQueryTab: QueryTab? {
        if let selectedTabID, let tab = tabs.first(where: { $0.id == selectedTabID }) {
            return tab
        }
        return tabs.last
    }

    /// 当前页签所在连接上的事务状态；连接未知时为 nil（界面据此隐藏事务控件）。
    var activeTransactionSession: TransactionSession? {
        guard let tab = activeQueryTab, let key = transactionKey(for: tab) else { return nil }
        return transactionSessions[key] ?? TransactionSession()
    }

    /// 当前页签的事务模式（默认自动提交）。
    var activeTransactionMode: TransactionMode { activeTransactionSession?.mode ?? .autoCommit }

    /// 当前页签的事务阶段。
    var activeTransactionPhase: TransactionPhase { activeTransactionSession?.phase ?? .idle }

    private func transactionKey(for tab: QueryTab) -> ServiceKey? {
        guard let connectionID = tab.connectionID,
              let configuration = connections.first(where: { $0.id == connectionID }) else { return nil }
        let database = tab.database?.isEmpty == false ? tab.database! : queryDatabase(for: configuration)
        return ServiceKey(connectionID: connectionID, database: database)
    }

    /// 切换自动提交 / 手工事务。有进行中的事务时**拒绝切回自动提交**（静默提交与静默丢弃都是事故）。
    func setTransactionMode(_ mode: TransactionMode, for tabID: UUID) async {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let key = transactionKey(for: tab) else { return }

        var session = transactionSessions[key] ?? TransactionSession()
        switch session.setMode(mode) {
        case .refuse(let refusal):
            statusMessage = transactionRefusalMessage(refusal)
        case .nothing, .begin, .commit, .rollback:
            transactionSessions[key] = session
            statusMessage = session.mode.isManual ? L(.transactionModeManual) : L(.transactionModeAuto)
        }
    }

    /// 提交手工事务。
    func commitTransaction(for tabID: UUID) async {
        await performTransactionCommand(for: tabID) { $0.commit() }
    }

    /// 回滚手工事务。
    func rollbackTransaction(for tabID: UUID) async {
        await performTransactionCommand(for: tabID) { $0.rollback() }
    }

    /// 事务命令的统一执行路径：**先由状态机判定能不能做**，再发命令，再按结果更新界面。
    private func performTransactionCommand(
        for tabID: UUID,
        _ decide: (inout TransactionSession) -> TransactionAction
    ) async {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let key = transactionKey(for: tab),
              let configuration = connections.first(where: { $0.id == key.connectionID }) else { return }

        var session = transactionSessions[key] ?? TransactionSession()
        let action = decide(&session)
        switch action {
        case .refuse(let refusal):
            statusMessage = transactionRefusalMessage(refusal)
            return
        case .commit, .rollback:
            // 先把状态落到内存，再发命令：命令失败时会改写回去。
            transactionSessions[key] = session
            do {
                let service = try await ensureService(for: configuration, database: key.database)
                if case .commit = action {
                    try await service.commit()
                    statusMessage = L(.transactionCommitted)
                } else {
                    try await service.rollback()
                    statusMessage = L(.transactionRolledBack)
                }
            } catch {
                // 命令没成功：状态退回「事务已结束」，别让界面显示「已提交」而库里其实没有。
                session.serverCommandFailed()
                transactionSessions[key] = session
                errorMessage = ErrorPresenter.message(for: error)
            }
        case .begin, .nothing:
            transactionSessions[key] = session
        }
    }

    private func transactionRefusalMessage(_ refusal: TransactionRefusal) -> String {
        switch refusal {
        case .notInManualMode: return L(.transactionRefusedNotManual)
        case .nothingToDo: return L(.transactionRefusedNothing)
        case .aborted: return L(.transactionRefusedAborted)
        case .hasOpenTransaction: return L(.transactionRefusedOpen)
        }
    }

    /// 切换连接 / 数据库前，把**别处**未提交的事务回滚掉并说明。
    ///
    /// 为什么不是自动提交：未提交的事务在新连接上根本不存在，替用户提交是数据事故；
    /// 回滚 + 明说是唯一可预期的处置。**绝不静默丢弃**。
    private func settleTransactions(leaving connectionID: UUID?) {
        for key in Array(transactionSessions.keys) {
            guard var session = transactionSessions[key], session.phase.isOpen else { continue }
            if let connectionID, key.connectionID == connectionID { continue }
            guard session.connectionDidChange() == .rollback else { continue }
            transactionSessions[key] = session
            let service = services[key]
            Task { try? await service?.rollback() }
            statusMessage = L(.transactionRolledBackOnLeave)
        }
    }

    func updateSQL(_ sql: String, for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].sql = sql
        // 改动 SQL 后，上一次的检查结果不再有效。
        tabs[index].syntaxCheckMessage = nil
        tabs[index].syntaxCheckFailed = false
        // 仅文件页签展示「未保存」标记。
        if tabs[index].fileURL != nil {
            tabs[index].isDirty = true
        }
    }

    /// 服务器端语法检查：对可 EXPLAIN 的语句执行 `EXPLAIN <sql>`。
    /// EXPLAIN 只做解析/规划，不会真正执行 INSERT / UPDATE / DELETE。
    func checkSyntax(for tabID: UUID) async {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        guard let configuration = selectedConnection else {
            updateTab(tabID) {
                $0.syntaxCheckFailed = true
                $0.syntaxCheckMessage = L(.stateSelectConnectionFirst)
            }
            return
        }

        let sql = tabs[tabIndex].sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else {
            updateTab(tabID) {
                $0.syntaxCheckFailed = true
                $0.syntaxCheckMessage = L(.stateSQLEmpty)
            }
            return
        }

        updateTab(tabID) {
            $0.syntaxCheckFailed = false
            $0.syntaxCheckMessage = L(.stateChecking)
        }

        do {
            let targetDatabase = queryDatabase(for: configuration)
            let service = try await ensureService(for: configuration, database: targetDatabase)
            let statements = StatementSplitter(databaseType: configuration.dbType).split(sql)

            var checked = 0
            var skipped = 0
            var failures: [String] = []

            for statement in statements {
                let text = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let firstWord = firstKeyword(in: text)

                guard ["SELECT", "INSERT", "UPDATE", "DELETE", "WITH", "VALUES", "TABLE"].contains(firstWord) else {
                    skipped += 1
                    continue
                }

                do {
                    for try await _ in service.execute("EXPLAIN \(text)", options: .default) {}
                    checked += 1
                } catch {
                    failures.append(L(.stateCheckFailedItem, statement.index + 1, ErrorPresenter.message(for: error)))
                }
            }

            if failures.isEmpty {
                var message = L(.stateCheckPassed, checked)
                if skipped > 0 {
                    message += L(.stateCheckSkipped, skipped)
                }
                updateTab(tabID) {
                    $0.syntaxCheckFailed = false
                    $0.syntaxCheckMessage = message
                }
            } else {
                var message = failures.prefix(3).joined(separator: "\n")
                if failures.count > 3 {
                    message += L(.stateCheckMoreErrors, failures.count - 3)
                }
                updateTab(tabID) {
                    $0.syntaxCheckFailed = true
                    $0.syntaxCheckMessage = message
                }
            }
        } catch {
            let message = ErrorPresenter.message(for: error)
            updateTab(tabID) {
                $0.syntaxCheckFailed = true
                $0.syntaxCheckMessage = message
            }
        }
    }

    /// 从 UI 触发执行：把执行放到可跟踪的 Task 里，「停止」按钮才能取消它。
    func startQuery(for tabID: UUID) {
        guard executionTasks[tabID] == nil else { return }

        // 句柄先于任务建立：**用户可能在连接/排队阶段就按停止**，
        // 那时也必须能记住"这次执行已被取消，别跑了"。
        executionHandles[tabID] = ExecutionHandle()

        let task = Task { @MainActor in
            await executeQuery(for: tabID)
            executionTasks[tabID] = nil
            executionHandles[tabID] = nil
        }
        executionTasks[tabID] = task
    }

    func executeQuery(for tabID: UUID, bypassingSafetyCheck: Bool = false) async {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard !tabs[tabIndex].isExecuting else { return }

        guard let configuration = selectedConnection else {
            updateTab(tabID) {
                $0.errorMessage = L(.stateSelectConnectionFirst)
                $0.statusMessage = L(.stateNotExecuted)
            }
            return
        }

        // 运行范围控制（FR-EXEC-14）：先按当前模式抠出**真正要跑的那一段**，
        // 后续的连接、Safe Mode 判定、执行全都基于这一段。
        let resolution = ExecutionScope.resolve(
            text: tabs[tabIndex].sql,
            mode: executionScope,
            selection: EditorCommandCenter.shared.selection(for: tabID),
            databaseType: configuration.dbType
        )
        if let issue = resolution.issue {
            updateTab(tabID) {
                $0.errorMessage = message(forRunScopeIssue: issue)
                $0.statusMessage = L(.stateNotExecuted)
            }
            return
        }

        let sql = resolution.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else {
            updateTab(tabID) {
                $0.errorMessage = L(.stateSQLEmpty)
                $0.statusMessage = L(.stateNotExecuted)
            }
            return
        }

        // 高危语句保护（FR-EXEC-16）：纯客户端静态判定，拦下后不发起任何连接。
        // 用户确认后走 `bypassingSafetyCheck: true` 再回来，避免重复弹窗。
        if !bypassingSafetyCheck {
            let decision = ExecutionSafety.check(
                sql: sql,
                databaseType: configuration.dbType,
                policy: executionSafetyPolicy
            )
            if case .needsConfirmation = decision {
                pendingExecution = PendingExecution(tabID: tabID, sql: sql, decision: decision)
                return
            }
        }

        let targetDatabase = queryDatabase(for: configuration)

        updateTab(tabID) {
            $0.isExecuting = true
            $0.errorMessage = nil
            $0.statusMessage = L(.stateConnecting, configuration.endpointDescription, targetDatabase)
            $0.results = []
            $0.resultSummaries = []
            $0.selectedResultIndex = 0
            $0.connectionID = configuration.id
            $0.database = targetDatabase
        }

        let executionStart = Date()

        // 归档要写「影响行数」，在执行过程中累计一次（原先只在事件里即时展示）。
        // 声明在 `do` 之外：**失败分支也要用到它**（出错前可能已经写过几行）。
        //
        // 计数收进 AffectedRowsTally：**全工程唯一的计数入口**。R-32 的教训是
        // 「DML 同时发两个事件、上层两条分支都累加」⇒ 落盘行数翻倍，而现在
        // 通道只剩 `.resultSet(affectedRows:)` 一条，且只有 absorb 一处会加。
        var affectedTally = AffectedRowsTally()

        // 事务上下文按「连接 + 数据库」归属（FR-EXEC-15）。
        // 声明在 `do` 之外：失败分支也要用它把事务标记成失败态。
        let transactionKey = ServiceKey(connectionID: configuration.id, database: targetDatabase)

        do {
            let service = try await ensureService(for: configuration, database: targetDatabase)
            updateTab(tabID) { $0.statusMessage = L(.stateExecuting) }

            var currentStatementIndex = 0
            var resultCount = 0

            let handle = executionHandles[tabID] ?? ExecutionHandle()
            executionHandles[tabID] = handle

            // 事务时序（FR-EXEC-15）：手工模式下**第一条语句前**才发 BEGIN（懒开启），
            // 失败的事务里直接拒绝继续执行 —— 否则用户会看到一条难懂的
            // 「current transaction is aborted」服务端错误。
            var transactionSession = transactionSessions[transactionKey] ?? TransactionSession()
            let transactionAction = transactionSession.prepareStatement()
            if case .refuse(let refusal) = transactionAction {
                transactionSessions[transactionKey] = transactionSession
                updateTab(tabID) {
                    $0.isExecuting = false
                    $0.errorMessage = transactionRefusalMessage(refusal)
                    $0.statusMessage = L(.stateNotExecuted)
                }
                return
            }
            transactionSessions[transactionKey] = transactionSession
            if case .begin = transactionAction {
                do {
                    try await service.beginTransaction()
                } catch {
                    // BEGIN 没成功 = 没有事务：状态退回 idle，别让界面显示「事务进行中」。
                    transactionSession.serverCommandFailed()
                    transactionSessions[transactionKey] = transactionSession
                    updateTab(tabID) {
                        $0.isExecuting = false
                        $0.errorMessage = L(.transactionBeginFailed, ErrorPresenter.message(for: error))
                        $0.statusMessage = L(.stateNotExecuted)
                    }
                    return
                }
            }

            for try await event in service.execute(sql, options: .default, handle: handle) {
                // 页签可能在执行过程中被关闭；此时停止更新，避免下标越界。
                guard tabs.contains(where: { $0.id == tabID }) else { break }

                switch event {
                case .started(let index):
                    currentStatementIndex = index
                    updateTab(tabID) { $0.statusMessage = L(.stateExecutingStatement, index + 1) }

                case .resultSet(let result):
                    resultCount += 1
                    let statementNumber = currentStatementIndex + 1
                    // 有表格的结果集：行 × 列 交给 Result 页签的表头，**不进 Output 日志**，
                    // 否则两个页签会重复同一件事。没有表格的（影响行数 / 无结果集）才进日志，
                    // 因为结果表里根本不会出现它们。
                    affectedTally.absorb(event)
                    let isTabular = result.affectedRows == nil && result.columnCount > 0
                    let logLine: String?
                    if let affected = result.affectedRows {
                        logLine = L(.stateStatementAffectedRows, statementNumber, affected)
                    } else if result.columnCount == 0 {
                        logLine = L(.stateStatementNoResultSet, statementNumber)
                    } else {
                        logLine = nil
                    }
                    var provenance = L(.stateStatementResult, statementNumber, result.rowCount, result.columnCount)
                    if result.isTruncated {
                        // 摘要与状态栏都写明「被截断」：归档、日志、界面三处口径一致（R-33）。
                        provenance += " · \(L(.resultTruncatedTag))"
                    }
                    updateTab(tabID) {
                        $0.results.append(result)
                        $0.resultSummaries.append(isTabular ? provenance : "")
                        $0.selectedResultIndex = $0.results.count - 1
                        if result.isTruncated {
                            $0.statusMessage = L(.resultTruncated, result.truncationLimit ?? result.rowCount)
                        } else if let logLine {
                            $0.statusMessage = logLine
                        }
                    }

                case .notice(let message):
                    updateTab(tabID) { $0.statusMessage = message }

                case .finished(let summary):
                    let duration = String(format: "%.3f", summary.duration)
                    let finishedMessage: String
                    if summary.statementCount == 0 {
                        finishedMessage = L(.stateFinishedNoResult, duration)
                    } else if resultCount > 1 {
                        finishedMessage = L(.stateFinishedMulti, summary.statementCount, resultCount, duration)
                    } else {
                        finishedMessage = L(.stateFinished, summary.statementCount, duration)
                    }
                    updateTab(tabID) { $0.statusMessage = finishedMessage }
                }
            }

            if resultCount == 0 {
                updateTab(tabID) { $0.statusMessage = L(.stateFinishedEmpty) }
            }

            // 取消必须在历史里留痕，且**不得记成成功**（R-31）。
            // 原先这里无条件写 `succeeded: true`：取消若发生在流正常结束的瞬间
            // （或驱动没把取消变成抛错），归档里就留下一条"成功执行"的假记录 ——
            // 归档是审计依据，假成功比失败更糟。
            let cancelled = Task.isCancelled
            recordHistory(
                sql: sql,
                connectionID: configuration.id,
                duration: Date().timeIntervalSince(executionStart),
                succeeded: !cancelled,
                affectedRows: affectedTally.value,
                note: cancelled ? L(.stateCancelled) : nil
            )
        } catch {
            // 取消同样留痕（`succeeded: false` + 可读原因），不再"什么都不记"。
            let cancelled = Task.isCancelled || error is CancellationError
            let message = cancelled ? L(.stateCancelled) : ErrorPresenter.message(for: error)
            updateTab(tabID) {
                if cancelled {
                    $0.statusMessage = message
                } else {
                    $0.errorMessage = message
                    $0.statusMessage = L(.stateExecutionFailed)
                }
            }
            recordHistory(
                sql: sql,
                connectionID: configuration.id,
                duration: Date().timeIntervalSince(executionStart),
                succeeded: false,
                affectedRows: affectedTally.value,
                note: message
            )

            // 手工事务里的失败（含取消）会让事务进入失败态：之后只接受回滚。
            var session = transactionSessions[transactionKey] ?? TransactionSession()
            session.statementFailed(reason: message)
            transactionSessions[transactionKey] = session
        }

        if Task.isCancelled {
            updateTab(tabID) { $0.statusMessage = L(.stateCancelled) }
        }

        updateTab(tabID) { $0.isExecuting = false }
    }

    func selectResult(_ index: Int, for tabID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs[tabIndex].results.indices.contains(index) else { return }
        tabs[tabIndex].selectedResultIndex = index
    }

    func cancelQuery(for tabID: UUID) async {
        // ① 先停本地的消费与生产（R-29：生产端会随消费者终止，剩余语句不再下发）。
        executionTasks[tabID]?.cancel()

        guard let tab = tabs.first(where: { $0.id == tabID }),
              let connectionID = tab.connectionID,
              let configuration = connections.first(where: { $0.id == connectionID }) else {
            return
        }

        let database = tab.database ?? currentDatabaseName(for: configuration)
        let key = ServiceKey(connectionID: connectionID, database: database)
        guard let service = services[key] else { return }

        // ② 再定向地把取消下发到服务端，并**如实显示结果** ——
        // 拿不到后端 PID 时以前是静默返回，用户看到"已取消"而查询还在跑（R-30）。
        let handle = executionHandles[tabID] ?? ExecutionHandle()
        switch await service.cancel(handle) {
        case .cancelled, .cancelledBeforeStart:
            updateTab(tabID) { $0.statusMessage = L(.stateCancelled) }
        case .notActive:
            updateTab(tabID) { $0.statusMessage = L(.stateCancelAlreadyDone) }
        case .failed(let reason):
            updateTab(tabID) {
                $0.statusMessage = L(.stateCancelNotDelivered, reason)
                $0.errorMessage = L(.stateCancelNotDelivered, reason)
            }
        }
    }

    @discardableResult
    private func updateTab(_ tabID: UUID, _ body: (inout QueryTab) -> Void) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        body(&tabs[index])
        return true
    }

    /// 取语句的第一个关键字，跳过前导空白与注释。
    private func firstKeyword(in text: String) -> String {
        var remainder = Substring(text)

        while true {
            remainder = remainder.drop(while: { $0.isWhitespace })

            if remainder.hasPrefix("--") {
                guard let newline = remainder.firstIndex(of: "\n") else { return "" }
                remainder = remainder[remainder.index(after: newline)...]
                continue
            }

            if remainder.hasPrefix("/*") {
                guard let end = remainder.range(of: "*/") else { return "" }
                remainder = remainder[end.upperBound...]
                continue
            }

            break
        }

        let word = remainder.prefix(while: { !$0.isWhitespace && $0 != "(" && $0 != ";" })
        return word.uppercased()
    }

    /// 取得（必要时建立）指向指定数据库的连接。
    /// `database` 为空时使用连接配置里的数据库。
    private func ensureService(
        for configuration: ConnectionConfig,
        database: String? = nil
    ) async throws -> any DatabaseService {
        let requested = database?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDatabase = (requested?.isEmpty == false) ? requested! : configuration.database
        let key = ServiceKey(connectionID: configuration.id, database: targetDatabase)

        if let service = services[key] {
            return service
        }

        // 多个页签 / 多个树节点可能几乎同时触发；复用同一个连接 Task，避免重复建立连接。
        let task: Task<(any DatabaseService, ServerInfo), Error>
        if let existing = connectTasks[key] {
            task = existing
        } else {
            guard let password = try secretStore.password(for: configuration.id) else {
                throw AppError.invalidConfiguration(L(.stateMissingPassword))
            }

            var derived = configuration
            derived.database = targetDatabase

            let newTask = Task<(any DatabaseService, ServerInfo), Error> {
                let service = DatabaseServiceFactory.make(for: derived, password: password)
                let serverInfo = try await service.connect()
                return (service, serverInfo)
            }
            connectTasks[key] = newTask
            task = newTask
        }

        do {
            let (service, serverInfo) = try await task.value
            services[key] = service
            connectTasks[key] = nil
            // 只有主库（连接配置里的库）刷新 serverInfo，避免浏览其他库时覆盖工具栏显示。
            if serverInfos[configuration.id] == nil || targetDatabase == configuration.database {
                serverInfos[configuration.id] = serverInfo
            }
            return service
        } catch {
            connectTasks[key] = nil
            throw error
        }
    }

    private func invalidateService(for connectionID: UUID) {
        for key in Array(connectTasks.keys) where key.connectionID == connectionID {
            connectTasks[key]?.cancel()
            connectTasks[key] = nil
        }

        for key in Array(services.keys) where key.connectionID == connectionID {
            // 断开连接会连带丢弃未提交事务（服务端在连接关闭时回滚）——
            // 这是**隐式**回滚，必须显式说出来，不能让用户以为它提交了。
            if var session = transactionSessions[key], session.phase.isOpen {
                session.serverCommandFailed()
                transactionSessions[key] = nil
                let service = services[key]
                Task { try? await service?.rollback() }
                statusMessage = L(.transactionRolledBackOnLeave)
            }
            if let service = services[key] {
                Task {
                    await service.disconnect()
                }
            }
            services[key] = nil
        }

        serverInfos[connectionID] = nil
    }
}
