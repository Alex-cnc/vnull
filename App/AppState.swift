import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import PostgresClientCore

struct QueryTab: Identifiable {
    let id: UUID
    var title: String
    var sql: String
    /// 多语句执行时，每个返回结果集的语句对应一个 QueryResult。
    var results: [QueryResult]
    var selectedResultIndex: Int
    var isExecuting: Bool
    var statusMessage: String
    var errorMessage: String?
    /// 「检查」按钮的结果（服务器端 EXPLAIN 校验）。
    var syntaxCheckMessage: String?
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

@MainActor
final class AppState: ObservableObject {
    @Published var connections: [ConnectionConfig] = []
    @Published var selectedConnectionID: ConnectionConfig.ID? {
        didSet {
            rememberSelectedConnection()
            // 换连接后建库权限结论作废，等对象树加载时重新探测（FR-META-11）。
            canCreateDatabase = nil
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
    // MARK: 智能体（FR-AI-01）

    /// 智能体接入配置；默认是「总开关关闭 + 端点为空」的安全默认（AC-AI-01）。
    @Published var agentConfiguration: AgentConfiguration = .default
    /// 已保存的 API Key（只存在于内存与系统钥匙串，**永不写入配置文件**）。
    @Published var agentAPIKey: String?
    /// 钥匙串里是否已有 Key（界面显示「已配置 / 未配置」）。
    @Published var hasAgentAPIKey = false
    /// 「智能体设置…」面板的呈现开关（菜单命令驱动）。
    @Published var isAgentSettingsPresented = false
    /// 「自然语言 → SQL」面板的呈现开关（菜单命令驱动）。
    @Published var isAgentSQLPresented = false

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
    private let secretStore: SecretStore = KeychainSecretStore()
    private let savedQueryStore = SavedQueryStore.shared
    private let agentConfigurationStore = AgentConfigurationStore.shared
    private let agentKeyStore: AgentKeyStore = KeychainAgentKeyStore()


    /// 连接缓存键：同一个「已保存连接」可以在多个数据库上各持有一条连接。
    private struct ServiceKey: Hashable {
        let connectionID: UUID
        let database: String
    }

    private var services: [ServiceKey: any DatabaseService] = [:]
    private var serverInfos: [UUID: ServerInfo] = [:]
    private var connectTasks: [ServiceKey: Task<(any DatabaseService, ServerInfo), Error>] = [:]
    private var executionTasks: [UUID: Task<Void, Never>] = [:]

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
            connections = try await store.load()
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
            connections.append(configuration)
            try await store.save(connections)
            selectedConnectionID = configuration.id
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
            try await store.save(connections)
            selectedConnectionID = configuration.id
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
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

    private func recordHistory(
        sql: String,
        connectionID: UUID,
        duration: TimeInterval,
        succeeded: Bool
    ) {
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
            connections.removeAll { $0.id == configuration.id }
            try await store.save(connections)
            if selectedConnectionID == configuration.id {
                selectedConnectionID = connections.first?.id
            }
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }

    func password(for configuration: ConnectionConfig) -> String? {
        do {
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

        guard let nameIndex else {
            return AgentSQLGenerator.SchemaSummary(database: database, tables: [])
        }

        let tables = result.rows.prefix(Self.agentTableListLimit).compactMap { row -> AgentSQLGenerator.SchemaSummary.Table? in
            guard nameIndex < row.count,
                  let raw = row[nameIndex],
                  case let name = raw.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            return AgentSQLGenerator.SchemaSummary.Table(name: name)
        }

        return AgentSQLGenerator.SchemaSummary(database: database, tables: tables)
    }

    /// 表清单外发上限（防止把上千张表发出去）。
    static let agentTableListLimit = 60

    /// 走完整条「自然语言 → SQL」通道；产物是文本，**不会被自动执行**（FR-AI-02）。
    func generateAgentSQL(
        instruction: String,
        schema: AgentSQLGenerator.SchemaSummary,
        currentStatement: String?
    ) async throws -> AgentSQLGenerator.Result {
        try await AgentSQLGenerator.generate(
            request: AgentSQLGenerator.Request(
                instruction: instruction,
                schema: schema,
                currentStatement: currentStatement
            ),
            configuration: agentConfiguration,
            apiKey: agentAPIKey,
            policy: .readOnlyDefault,
            ledger: .empty,
            client: OpenAICompatibleClient()
        )
    }

    /// 把生成结果放进**新页签**的编辑器里（不覆盖用户正在写的内容，也不执行）。
    func openGeneratedSQLInNewTab(_ sql: String) {
        openSQLInNewTab(sql, status: L(.agentSQLNotExecuted))
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
            availableDatabases = []
            selectedDatabase = nil
            databaseError = nil
            return
        }

        isLoadingDatabases = true
        databaseError = nil
        defer { isLoadingDatabases = false }

        do {
            let service = try await ensureService(for: configuration)
            let dialect = SQLDialectFactory.make(for: configuration.dbType)
            let result = try await runSingleQuery(dialect.listDatabasesQuery(), on: service)

            let names = result.rows.compactMap { row -> String? in
                guard let value = row.first ?? nil, !value.isEmpty else { return nil }
                return value
            }
            availableDatabases = names

            let preferred = selectedDatabase
                ?? serverInfos[configuration.id]?.database
                ?? configuration.database

            if names.isEmpty {
                selectedDatabase = configuration.database
            } else if names.contains(preferred) {
                selectedDatabase = preferred
            } else {
                selectedDatabase = serverInfos[configuration.id]?.database ?? names.first
            }
        } catch {
            availableDatabases = []
            databaseError = ErrorPresenter.message(for: error)
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

        let task = Task { @MainActor in
            await executeQuery(for: tabID)
            executionTasks[tabID] = nil
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
            $0.selectedResultIndex = 0
            $0.connectionID = configuration.id
            $0.database = targetDatabase
        }

        let executionStart = Date()

        do {
            let service = try await ensureService(for: configuration, database: targetDatabase)
            updateTab(tabID) { $0.statusMessage = L(.stateExecuting) }

            var currentStatementIndex = 0
            var resultCount = 0

            for try await event in service.execute(sql, options: .default) {
                // 页签可能在执行过程中被关闭；此时停止更新，避免下标越界。
                guard tabs.contains(where: { $0.id == tabID }) else { break }

                switch event {
                case .started(let index):
                    currentStatementIndex = index
                    updateTab(tabID) { $0.statusMessage = L(.stateExecutingStatement, index + 1) }

                case .resultSet(let result):
                    resultCount += 1
                    let statementNumber = currentStatementIndex + 1
                    let summary: String
                    if let affected = result.affectedRows {
                        summary = L(.stateStatementAffectedRows, statementNumber, affected)
                    } else if result.columnCount == 0 {
                        summary = L(.stateStatementNoResultSet, statementNumber)
                    } else {
                        summary = L(.stateStatementResult, statementNumber, result.rowCount, result.columnCount)
                    }
                    updateTab(tabID) {
                        $0.results.append(result)
                        $0.selectedResultIndex = $0.results.count - 1
                        $0.statusMessage = summary
                    }

                case .affectedRows(let count):
                    updateTab(tabID) { $0.statusMessage = L(.stateAffectedRows, count) }

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

            recordHistory(
                sql: sql,
                connectionID: configuration.id,
                duration: Date().timeIntervalSince(executionStart),
                succeeded: true
            )
        } catch {
            if Task.isCancelled {
                updateTab(tabID) { $0.statusMessage = L(.stateCancelled) }
            } else {
                let message = ErrorPresenter.message(for: error)
                updateTab(tabID) {
                    $0.errorMessage = message
                    $0.statusMessage = L(.stateExecutionFailed)
                }
                recordHistory(
                    sql: sql,
                    connectionID: configuration.id,
                    duration: Date().timeIntervalSince(executionStart),
                    succeeded: false
                )
            }
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
        executionTasks[tabID]?.cancel()

        guard let tab = tabs.first(where: { $0.id == tabID }),
              let connectionID = tab.connectionID,
              let configuration = connections.first(where: { $0.id == connectionID }) else {
            return
        }

        let database = tab.database ?? currentDatabaseName(for: configuration)
        let key = ServiceKey(connectionID: connectionID, database: database)
        if let service = services[key] {
            await service.cancel()
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
