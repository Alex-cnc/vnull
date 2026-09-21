import Foundation

/// 界面语言。
public enum AppLanguage: String, CaseIterable, Codable, Hashable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    /// 语言在菜单中的显示名（用该语言自身的写法）。
    public var displayName: String {
        switch self {
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    /// 跟随系统：系统首选语言是中文则中文，否则英文。
    public static var systemDefault: AppLanguage {
        let preferred = (Locale.preferredLanguages.first ?? "en").lowercased()
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }
}

/// 界面文案的键。新增文案时同时在此追加 case，并在 `LocalizedStrings.table` 补两种语言。
public enum LKey: String, CaseIterable, Sendable {
    // 通用
    case commonCancel
    case commonSave
    case commonDelete
    case commonEdit
    case commonRetry
    case commonCopy
    case commonOk

    // 菜单 / 命令
    case menuNewQuery
    case menuLanguage

    // 连接列表 / 侧边栏
    case connectionListTitle
    case connectionListEmpty
    case connectionUntitled
    case connectionNew
    case objectTreeSectionTitle
    case objectTreeSelectPrompt

    // 连接表单
    case connectionFormNew
    case connectionFormEdit
    case connectionFormName
    case connectionFormDbType
    case connectionFormHost
    case connectionFormPort
    case connectionFormDatabase
    case connectionFormUsername
    case connectionFormPassword
    case connectionFormPasswordKeep
    case connectionFormSSLMode
    case connectionFormTimeout
    case connectionFormTest
    case connectionFormTesting
    case connectionFormConnecting
    case connectionFormConnected
    case connectionFormFailed

    // 查询工作区
    case workspaceNoTabsTitle
    case workspaceNoTabsDescription
    case workspaceNoConnectionTitle
    case workspaceNoConnectionDescription
    case workspaceTabTitle
    case workspaceDelimiter
    case workspaceMoreDiagnostics

    // 服务器 / 数据库上下文栏
    case contextServer
    case contextServerHelp
    case contextDatabase
    case contextDatabaseHelp

    // 查询工具栏
    case toolbarSaveQueryHelp
    case toolbarSavedQueriesEmpty
    case toolbarSavedQueriesHelp
    case toolbarExecuteHelp
    case toolbarStopHelp
    case toolbarStopIdleHelp
    case toolbarCheckHelp

    // 保存查询表单
    case saveQueryTitle
    case saveQueryName
    case saveQueryDuplicate
    case saveQueryOverwrite

    // 结果区
    case resultTitle
    case resultPickerItem
    case resultSize
    case resultNoResultSet
    case resultAffectedRows
    case resultExecuting
    case resultEmptyTitle
    case resultEmptyDescription

    // 对象树
    case treeLoading
    case treeLoadingObjects
    case treeLoadFailed
    case treeEmpty
    case treeRefreshHelp
    case treeEmptyServer
    case treeEmptyDatabase
    case treeEmptyDatabaseGBase
    case treeEmptySchema
    case treeEmptyTable
    case treeEmptyGeneric
    case treeGroupByType
    case treeGroupHierarchy
    case treeGroupTable
    case treeGroupView
    case treeGroupSequence
    case treeGroupFunction
    case treeGroupOther

    // 服务器 / 库级管理（T-52）
    case objectTreeMenuDatabaseProperties
    case objectTreeMenuDropDatabase
    case objectTreeMenuPrivileges
    case objectTreeMenuLocks
    case dbPropsTitle
    case dbPropsOwner
    case dbPropsConnectionLimit
    case dbPropsAllowConnections
    case dbPropsUnchanged
    case dbPropsAllow
    case dbPropsDeny
    case dbPropsParameter
    case dbPropsParameterName
    case dbPropsParameterValue
    case dbPropsPreview
    case dbPropsEmpty
    case dbPropsInvalid
    case dbPropsApply
    case dbPropsSucceeded
    case dbPropsFailed
    case dbPropsUnsupported
    case dropDbTitle
    case dropDbWarning
    case dropDbTypeToConfirm
    case dropDbConfirm
    case dropDbSucceeded
    case dropDbFailed
    case dropDbActiveConnections
    case dropDbCurrentDatabase
    case dropDbNotExist
    case dropDbNoPrivilege
    case privilegeTitle
    case privilegeRole
    case privilegeLoad
    case privilegeEmpty
    case privilegeUnsupported
    case privilegeInvalidRole
    case privilegeColumnObject
    case privilegeColumnGrantee
    case privilegeColumnPrivilege
    case privilegeColumnGrantOption
    case privilegeGrantSection
    case privilegeObjectKind
    case privilegeObjectName
    case privilegeSchema
    case privilegePrivileges
    case privilegeGrantee
    case privilegeWithGrantOption
    case privilegePreview
    case privilegeInvalid
    case privilegeGrant
    case privilegeRevoke
    case privilegeSucceeded
    case privilegeFailed
    case lockTitle
    case lockRefresh
    case lockEmpty
    case lockUnsupported
    case lockPermissionHint
    case lockColumnPid
    case lockColumnBlockedBy
    case lockColumnUser
    case lockColumnDatabase
    case lockColumnLock
    case lockColumnWaiting
    case lockGranted
    case lockWaitingState
    case lockShowBlocker
    case lockFailed
    case commonClose

    // 智能体设置（FR-AI-01）
    case menuAgent
    case menuAgentSettings
    case agentSettingsTitle
    case agentEnabled
    case agentEnabledHint
    case agentEndpoint
    case agentEndpointPlaceholder
    case agentModel
    case agentModelPlaceholder
    case agentTimeout
    case agentQuotaSection
    case agentMaxRequests
    case agentMaxOutputTokens
    case agentMaxTotalTokens
    case agentAPIKey
    case agentAPIKeyConfigured
    case agentAPIKeyMissing
    case agentAPIKeyClear
    case agentLocalEndpointHint
    case agentStatusSection
    case agentSave
    case agentSaved
    case agentSaveFailed
    case agentInvalidHint

    // 自然语言 → SQL（FR-AI-02）
    case menuAgentGenerateSQL
    case agentSQLTitle
    case agentSQLInstruction
    case agentSQLInstructionPlaceholder
    case agentSQLIncludeTables
    case agentSQLIncludeStatement
    case agentSQLPayload
    case agentSQLPayloadNote
    case agentSQLGenerate
    case agentSQLResult
    case agentSQLExplanation
    case agentSQLGuard
    case agentSQLNotExecuted
    case agentSQLInsertNewTab
    case agentSQLCopy
    case agentSQLCopied
    case agentSQLFailed
    case agentSQLNoInstruction
    case agentSQLNoTables

    // 执行状态
    case stateNotConnected
    case stateNotExecuted
    case stateSelectConnectionFirst
    case stateSQLEmpty
    case stateChecking
    case stateCheckPassed
    case stateCheckSkipped
    case stateCheckFailedItem
    case stateCheckMoreErrors
    case stateConnecting
    case stateExecuting
    case stateExecutingStatement
    case stateStatementNoResultSet
    case stateStatementResult
    case stateStatementAffectedRows
    case stateAffectedRows
    case stateFinishedNoResult
    case stateFinishedMulti
    case stateFinished
    case stateCancelled
    case stateExecutionFailed
    case stateFinishedEmpty
    case stateQueryNoResultSet
    case stateMissingPassword

    // 错误提示
    case errorInvalidConfiguration
    case errorNotConnected
    case errorNotImplemented
    case errorKeychain
    case errorPersistence
    case errorQueryFailed
    case alertErrorTitle

    // 语法检查诊断
    case lintLocation
    case lintBlockComment
    case lintString
    case lintQuotedIdentifier
    case lintDollarQuote
    case lintExtraCloseParen
    case lintMissingCloseParen
    case toolbarOpenFileHelp
    case toolbarSaveFileHelp
    case toolbarSaveAs
    case toolbarEditHelp
    case toolbarHelpHelp
    case editMenuFind
    case editMenuReplace
    case editMenuGoToLine
    case editMenuIndent
    case editMenuOutdent
    case editMenuClear
    case editMenuFormat
    case workspaceUnboundTab
    case workspaceUnboundHint
    case fileOpenFailed
    case fileSaveFailed
    case fileSaved
    case goToLineTitle
    case goToLineLine
    case goToLineColumn
    case goToLineInvalid
    case goToLineConfirm
    case helpPlaceholder

    // 删除确认 / 结果导出 / 查询历史 / 编辑器补全
    case connectionDeleteConfirmTitle
    case connectionDeleteConfirmMessage
    case resultExport
    case exportCSV
    case exportJSON
    case exportTSV
    case exportMarkdown
    case exportSQLInsert
    case exportSucceeded
    case exportFailed
    case exportNoData
    case historyTitle
    case historyEmpty
    case historyClear
    case historyHelp
    case historyLoadHelp
    case editorCompletionHelp

    // 对象树右键菜单 / 新建数据库（FR-META-11）
    case objectTreeMenuConnect
    case objectTreeMenuDisconnect
    case objectTreeMenuEditConnection
    case objectTreeMenuCreateDatabase
    case objectTreeStatusConnected
    case objectTreeStatusDisconnected
    case createDatabaseTitle
    case createDatabaseNamePlaceholder
    case createDatabaseHint
    case createDatabaseInvalid
    case createDatabaseConfirm
    case createDatabaseSucceeded
    case createDatabaseFailed
}

public enum LocalizedStrings {
    public static func text(_ key: LKey, language: AppLanguage) -> String {
        table[key]?[language] ?? key.rawValue
    }

    public static func format(_ key: LKey, language: AppLanguage, _ arguments: CVarArg...) -> String {
        let template = text(key, language: language)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: language.locale, arguments: arguments)
    }

    /// key → [语言: 文案]。`Tests/LocalizationTests.swift` 会校验每个 key 两种语言齐全。
    static let table: [LKey: [AppLanguage: String]] = [
        .commonCancel: [.simplifiedChinese: "取消", .english: "Cancel"],
        .commonSave: [.simplifiedChinese: "保存", .english: "Save"],
        .commonDelete: [.simplifiedChinese: "删除", .english: "Delete"],
        .commonEdit: [.simplifiedChinese: "编辑", .english: "Edit"],
        .commonRetry: [.simplifiedChinese: "重试", .english: "Retry"],
        .commonCopy: [.simplifiedChinese: "复制", .english: "Copy"],
        .commonOk: [.simplifiedChinese: "好", .english: "OK"],

        .menuNewQuery: [.simplifiedChinese: "新建查询", .english: "New Query"],
        .menuLanguage: [.simplifiedChinese: "语言", .english: "Language"],

        .connectionListTitle: [.simplifiedChinese: "连接列表", .english: "Connections"],
        .connectionListEmpty: [.simplifiedChinese: "还没有连接", .english: "No connections yet"],
        .connectionUntitled: [.simplifiedChinese: "未命名连接", .english: "Untitled Connection"],
        .connectionNew: [.simplifiedChinese: "新建连接", .english: "New Connection"],
        .objectTreeSectionTitle: [.simplifiedChinese: "数据库对象", .english: "Database Objects"],
        .objectTreeSelectPrompt: [.simplifiedChinese: "选择一个连接后加载对象", .english: "Select a connection to load objects"],

        .connectionFormNew: [.simplifiedChinese: "新建连接", .english: "New Connection"],
        .connectionFormEdit: [.simplifiedChinese: "编辑连接", .english: "Edit Connection"],
        .connectionFormName: [.simplifiedChinese: "连接名称", .english: "Name"],
        .connectionFormDbType: [.simplifiedChinese: "数据库类型", .english: "Database Type"],
        .connectionFormHost: [.simplifiedChinese: "主机地址", .english: "Host"],
        .connectionFormPort: [.simplifiedChinese: "端口", .english: "Port"],
        .connectionFormDatabase: [.simplifiedChinese: "数据库名", .english: "Database"],
        .connectionFormUsername: [.simplifiedChinese: "用户名", .english: "Username"],
        .connectionFormPassword: [.simplifiedChinese: "密码", .english: "Password"],
        .connectionFormPasswordKeep: [.simplifiedChinese: "留空则保持原密码", .english: "Leave blank to keep current password"],
        .connectionFormSSLMode: [.simplifiedChinese: "SSL 模式", .english: "SSL Mode"],
        .connectionFormTimeout: [.simplifiedChinese: "连接超时：%d 秒", .english: "Timeout: %d s"],
        .connectionFormTest: [.simplifiedChinese: "测试连接", .english: "Test Connection"],
        .connectionFormTesting: [.simplifiedChinese: "测试中...", .english: "Testing..."],
        .connectionFormConnecting: [.simplifiedChinese: "正在连接 %@ ...", .english: "Connecting to %@ ..."],
        .connectionFormConnected: [.simplifiedChinese: "连接成功：%@ · %@ · %@", .english: "Connected: %@ · %@ · %@"],
        .connectionFormFailed: [.simplifiedChinese: "连接失败：%@", .english: "Connection failed: %@"],

        .workspaceNoTabsTitle: [.simplifiedChinese: "没有查询页签", .english: "No Query Tab"],
        .workspaceNoTabsDescription: [.simplifiedChinese: "按 ⌘T 新建一个查询页签", .english: "Press ⌘T to create a query tab"],
        .workspaceNoConnectionTitle: [.simplifiedChinese: "请先选择一个连接", .english: "Select a Connection"],
        .workspaceNoConnectionDescription: [.simplifiedChinese: "在左侧连接列表中选择或新建一个数据库连接", .english: "Choose or create a database connection in the sidebar"],
        .workspaceTabTitle: [.simplifiedChinese: "查询 %d", .english: "Query %d"],
        .workspaceDelimiter: [.simplifiedChinese: "分隔符 %@", .english: "Delimiter %@"],
        .workspaceMoreDiagnostics: [.simplifiedChinese: "还有 %d 条提示…", .english: "%d more hint(s)…"],

        .contextServer: [.simplifiedChinese: "服务器", .english: "Server"],
        .contextServerHelp: [.simplifiedChinese: "当前查询所在的数据库服务器", .english: "Database server for the current query"],
        .contextDatabase: [.simplifiedChinese: "数据库", .english: "Database"],
        .contextDatabaseHelp: [.simplifiedChinese: "当前查询目标数据库（只显示当前用户有权限访问的库）", .english: "Target database (only databases the current user can access)"],

        .toolbarSaveQueryHelp: [.simplifiedChinese: "保存当前查询 SQL", .english: "Save the current SQL"],
        .toolbarSavedQueriesEmpty: [.simplifiedChinese: "暂无已保存查询", .english: "No saved queries"],
        .toolbarSavedQueriesHelp: [.simplifiedChinese: "已保存的查询（点击回填到当前页签）", .english: "Saved queries (click to load into the current tab)"],
        .toolbarExecuteHelp: [.simplifiedChinese: "执行 SQL（⌘↩）", .english: "Run SQL (⌘↩)"],
        .toolbarStopHelp: [.simplifiedChinese: "停止执行", .english: "Stop"],
        .toolbarStopIdleHelp: [.simplifiedChinese: "当前没有正在执行的查询", .english: "No query is running"],
        .toolbarCheckHelp: [.simplifiedChinese: "语法检查（EXPLAIN，不执行数据修改）", .english: "Syntax check via EXPLAIN (does not run DML)"],

        .saveQueryTitle: [.simplifiedChinese: "保存查询", .english: "Save Query"],
        .saveQueryName: [.simplifiedChinese: "查询名称", .english: "Query name"],
        .saveQueryDuplicate: [.simplifiedChinese: "已存在同名查询，保存将覆盖原内容", .english: "A query with this name already exists; saving will overwrite it"],
        .saveQueryOverwrite: [.simplifiedChinese: "覆盖保存", .english: "Overwrite"],

        .resultTitle: [.simplifiedChinese: "结果", .english: "Result"],
        .resultPickerItem: [.simplifiedChinese: "第 %d 个结果集", .english: "Result %d"],
        .resultSize: [.simplifiedChinese: "%d 行 · %d 列", .english: "%d rows · %d columns"],
        .resultNoResultSet: [.simplifiedChinese: "语句执行成功，没有返回结果集", .english: "Statement succeeded with no result set"],
        .resultAffectedRows: [.simplifiedChinese: "影响 %d 行", .english: "%d rows affected"],
        .resultExecuting: [.simplifiedChinese: "正在执行…", .english: "Executing…"],
        .resultEmptyTitle: [.simplifiedChinese: "暂无结果", .english: "No Results"],
        .resultEmptyDescription: [.simplifiedChinese: "执行 SQL 后，结果会显示在这里", .english: "Run a query to see results here"],

        .treeLoading: [.simplifiedChinese: "加载中…", .english: "Loading…"],
        .treeLoadingObjects: [.simplifiedChinese: "加载对象…", .english: "Loading objects…"],
        .treeLoadFailed: [.simplifiedChinese: "对象加载失败", .english: "Failed to Load Objects"],
        .treeEmpty: [.simplifiedChinese: "没有可显示的对象", .english: "No objects to display"],
        .treeRefreshHelp: [.simplifiedChinese: "刷新对象树", .english: "Refresh object tree"],
        .treeEmptyServer: [.simplifiedChinese: "当前用户没有可访问的数据库", .english: "No accessible databases for the current user"],
        .treeEmptyDatabase: [.simplifiedChinese: "该数据库下暂无 schema", .english: "No schemas in this database"],
        .treeEmptyDatabaseGBase: [.simplifiedChinese: "该数据库下暂无表 / 视图", .english: "No tables/views in this database"],
        .treeEmptySchema: [.simplifiedChinese: "该 schema 下暂无表 / 视图", .english: "No tables/views in this schema"],
        .treeEmptyTable: [.simplifiedChinese: "没有列信息", .english: "No column information"],
        .treeEmptyGeneric: [.simplifiedChinese: "暂无子对象", .english: "No child objects"],
        .treeGroupByType: [.simplifiedChinese: "按类型分组", .english: "Group by type"],
        .treeGroupHierarchy: [.simplifiedChinese: "层级视图", .english: "Hierarchy"],
        .treeGroupTable: [.simplifiedChinese: "表", .english: "Tables"],
        .treeGroupView: [.simplifiedChinese: "视图", .english: "Views"],
        .treeGroupSequence: [.simplifiedChinese: "序列", .english: "Sequences"],
        .treeGroupFunction: [.simplifiedChinese: "函数", .english: "Functions"],
        .treeGroupOther: [.simplifiedChinese: "其他", .english: "Other"],
        .objectTreeMenuDatabaseProperties: [.simplifiedChinese: "库属性…", .english: "Database properties…"],
        .objectTreeMenuDropDatabase: [.simplifiedChinese: "删除数据库…", .english: "Drop database…"],
        .objectTreeMenuPrivileges: [.simplifiedChinese: "权限…", .english: "Privileges…"],
        .objectTreeMenuLocks: [.simplifiedChinese: "锁与阻塞…", .english: "Locks & blocking…"],
        .dbPropsTitle: [.simplifiedChinese: "库属性", .english: "Database properties"],
        .dbPropsOwner: [.simplifiedChinese: "属主（留空不修改）", .english: "Owner (blank = unchanged)"],
        .dbPropsConnectionLimit: [.simplifiedChinese: "连接数上限（-1 不限，留空不修改）", .english: "Connection limit (-1 unlimited, blank = unchanged)"],
        .dbPropsAllowConnections: [.simplifiedChinese: "允许连接", .english: "Allow connections"],
        .dbPropsUnchanged: [.simplifiedChinese: "不修改", .english: "Unchanged"],
        .dbPropsAllow: [.simplifiedChinese: "允许", .english: "Allow"],
        .dbPropsDeny: [.simplifiedChinese: "禁止", .english: "Deny"],
        .dbPropsParameter: [.simplifiedChinese: "库级参数", .english: "Database parameter"],
        .dbPropsParameterName: [.simplifiedChinese: "参数名（如 search_path）", .english: "Name (e.g. search_path)"],
        .dbPropsParameterValue: [.simplifiedChinese: "参数值", .english: "Value"],
        .dbPropsPreview: [.simplifiedChinese: "将执行的语句", .english: "Statements to run"],
        .dbPropsEmpty: [.simplifiedChinese: "尚未填写任何改动。", .english: "No changes entered yet."],
        .dbPropsInvalid: [.simplifiedChinese: "填写内容不合法，已阻止生成语句。", .english: "Invalid input; no statement was generated."],
        .dbPropsApply: [.simplifiedChinese: "执行", .english: "Apply"],
        .dbPropsSucceeded: [.simplifiedChinese: "已更新数据库 %@ 的属性。", .english: "Updated properties of %@."],
        .dbPropsFailed: [.simplifiedChinese: "改库属性失败：%@", .english: "Altering database failed: %@"],
        .dbPropsUnsupported: [.simplifiedChinese: "当前方言不支持改库属性（仅 PostgreSQL）。", .english: "Altering database properties is not supported for this dialect (PostgreSQL only)."],
        .dropDbTitle: [.simplifiedChinese: "删除数据库", .english: "Drop database"],
        .dropDbWarning: [.simplifiedChinese: "删除不可回滚，库内全部对象都会丢失。", .english: "This cannot be undone; every object in the database will be lost."],
        .dropDbTypeToConfirm: [.simplifiedChinese: "请输入数据库名 %@ 以确认", .english: "Type %@ to confirm"],
        .dropDbConfirm: [.simplifiedChinese: "删除", .english: "Drop"],
        .dropDbSucceeded: [.simplifiedChinese: "已删除数据库 %@。", .english: "Dropped database %@."],
        .dropDbFailed: [.simplifiedChinese: "删除数据库失败：%@", .english: "Dropping database failed: %@"],
        .dropDbActiveConnections: [.simplifiedChinese: "该库仍有其他会话连接，服务端拒绝了删除。请先断开这些连接再试。", .english: "Other sessions are still connected; the server refused. Disconnect them first."],
        .dropDbCurrentDatabase: [.simplifiedChinese: "不能删除当前连接的数据库。请先切换到其他数据库。", .english: "You cannot drop the database you are connected to. Switch to another database first."],
        .dropDbNotExist: [.simplifiedChinese: "该数据库不存在（可能已被删除）。", .english: "That database does not exist (it may already be dropped)."],
        .dropDbNoPrivilege: [.simplifiedChinese: "当前账号权限不足：删除数据库需要属主或超级用户权限。", .english: "Insufficient privilege: dropping a database requires ownership or superuser."],
        .privilegeTitle: [.simplifiedChinese: "权限", .english: "Privileges"],
        .privilegeRole: [.simplifiedChinese: "角色", .english: "Role"],
        .privilegeLoad: [.simplifiedChinese: "查询", .english: "Load"],
        .privilegeEmpty: [.simplifiedChinese: "该角色在当前库上没有已授权限。", .english: "No privileges found for this role."],
        .privilegeUnsupported: [.simplifiedChinese: "当前方言不支持对象权限查询。", .english: "Object privilege query is not supported for this dialect."],
        .privilegeInvalidRole: [.simplifiedChinese: "角色名不合法。", .english: "Invalid role name."],
        .privilegeColumnObject: [.simplifiedChinese: "对象", .english: "Object"],
        .privilegeColumnGrantee: [.simplifiedChinese: "角色", .english: "Grantee"],
        .privilegeColumnPrivilege: [.simplifiedChinese: "权限", .english: "Privilege"],
        .privilegeColumnGrantOption: [.simplifiedChinese: "可转授", .english: "Grantable"],
        .privilegeGrantSection: [.simplifiedChinese: "授予 / 回收（执行前先预览）", .english: "Grant / revoke (preview before running)"],
        .privilegeObjectKind: [.simplifiedChinese: "对象类别", .english: "Object kind"],
        .privilegeObjectName: [.simplifiedChinese: "对象名", .english: "Object name"],
        .privilegeSchema: [.simplifiedChinese: "schema（可留空）", .english: "Schema (optional)"],
        .privilegePrivileges: [.simplifiedChinese: "权限（逗号分隔；ALL 不可与其他混用）", .english: "Privileges (comma separated; ALL cannot be mixed)"],
        .privilegeGrantee: [.simplifiedChinese: "被授权角色（PUBLIC 表示所有角色）", .english: "Grantee (PUBLIC means everyone)"],
        .privilegeWithGrantOption: [.simplifiedChinese: "含 WITH GRANT OPTION", .english: "With grant option"],
        .privilegePreview: [.simplifiedChinese: "将执行的语句", .english: "Statement to run"],
        .privilegeInvalid: [.simplifiedChinese: "输入不合法，无法生成语句。", .english: "Invalid input; no statement could be generated."],
        .privilegeGrant: [.simplifiedChinese: "授予", .english: "Grant"],
        .privilegeRevoke: [.simplifiedChinese: "回收", .english: "Revoke"],
        .privilegeSucceeded: [.simplifiedChinese: "已执行权限变更。", .english: "Privilege change applied."],
        .privilegeFailed: [.simplifiedChinese: "权限变更失败：%@", .english: "Privilege change failed: %@"],
        .lockTitle: [.simplifiedChinese: "锁与阻塞", .english: "Locks & blocking"],
        .lockRefresh: [.simplifiedChinese: "刷新", .english: "Refresh"],
        .lockEmpty: [.simplifiedChinese: "当前没有检测到锁等待。", .english: "No lock waits detected."],
        .lockUnsupported: [.simplifiedChinese: "当前方言不支持锁与阻塞链查询。", .english: "Lock/blocking query is not supported for this dialect."],
        .lockPermissionHint: [.simplifiedChinese: "非超级用户且不在 pg_monitor 角色时，其他会话的语句文本不可见。", .english: "Without superuser or pg_monitor, other sessions' query text is not visible."],
        .lockColumnPid: [.simplifiedChinese: "被阻塞 pid", .english: "Blocked pid"],
        .lockColumnBlockedBy: [.simplifiedChinese: "阻塞者 pid", .english: "Blocking pid"],
        .lockColumnUser: [.simplifiedChinese: "用户", .english: "User"],
        .lockColumnDatabase: [.simplifiedChinese: "数据库", .english: "Database"],
        .lockColumnLock: [.simplifiedChinese: "锁", .english: "Lock"],
        .lockColumnWaiting: [.simplifiedChinese: "已等待", .english: "Waiting"],
        .lockGranted: [.simplifiedChinese: "已授予", .english: "Granted"],
        .lockWaitingState: [.simplifiedChinese: "等待中", .english: "Waiting"],
        .lockShowBlocker: [.simplifiedChinese: "定位阻塞者", .english: "Locate blocker"],
        .lockFailed: [.simplifiedChinese: "锁查询失败：%@", .english: "Lock query failed: %@"],
        .commonClose: [.simplifiedChinese: "关闭", .english: "Close"],
        .menuAgent: [.simplifiedChinese: "智能体", .english: "Agent"],
        .menuAgentSettings: [.simplifiedChinese: "智能体设置…", .english: "Agent settings…"],
        .agentSettingsTitle: [.simplifiedChinese: "智能体设置", .english: "Agent settings"],
        .agentEnabled: [.simplifiedChinese: "启用智能体", .english: "Enable agent"],
        .agentEnabledHint: [.simplifiedChinese: "关闭时不会向任何模型服务发送数据。", .english: "When off, nothing is sent to any model service."],
        .agentEndpoint: [.simplifiedChinese: "模型服务端点（OpenAI 兼容）", .english: "Model endpoint (OpenAI-compatible)"],
        .agentEndpointPlaceholder: [.simplifiedChinese: "http://127.0.0.1:11434/v1", .english: "https://api.example.com/v1"],
        .agentModel: [.simplifiedChinese: "模型名", .english: "Model"],
        .agentModelPlaceholder: [.simplifiedChinese: "qwen2.5:7b", .english: "gpt-4o-mini"],
        .agentTimeout: [.simplifiedChinese: "超时（秒）", .english: "Timeout (seconds)"],
        .agentQuotaSection: [.simplifiedChinese: "配额（留空表示不限）", .english: "Quota (blank means unlimited)"],
        .agentMaxRequests: [.simplifiedChinese: "单次会话调用次数上限", .english: "Max requests per session"],
        .agentMaxOutputTokens: [.simplifiedChinese: "单次输出 token 上限", .english: "Max output tokens per request"],
        .agentMaxTotalTokens: [.simplifiedChinese: "累计 token 上限", .english: "Max total tokens"],
        .agentAPIKey: [.simplifiedChinese: "API Key", .english: "API Key"],
        .agentAPIKeyConfigured: [.simplifiedChinese: "已配置（存于系统钥匙串，不写入配置文件）", .english: "Configured (kept in Keychain, never in the config file)"],
        .agentAPIKeyMissing: [.simplifiedChinese: "未配置。远端端点需要 API Key；本地端点不需要。", .english: "Not configured. Remote endpoints need one; local endpoints do not."],
        .agentAPIKeyClear: [.simplifiedChinese: "清除已保存的 Key", .english: "Clear saved key"],
        .agentLocalEndpointHint: [.simplifiedChinese: "本地 / 局域网端点无需 API Key（本地模型优先）。", .english: "Local or LAN endpoints need no API key."],
        .agentStatusSection: [.simplifiedChinese: "当前状态", .english: "Status"],
        .agentSave: [.simplifiedChinese: "保存", .english: "Save"],
        .agentSaved: [.simplifiedChinese: "已保存智能体设置。", .english: "Agent settings saved."],
        .agentSaveFailed: [.simplifiedChinese: "保存智能体设置失败：%@", .english: "Saving agent settings failed: %@"],
        .agentInvalidHint: [.simplifiedChinese: "配置尚不完整，即使打开总开关也不会外发。", .english: "Configuration is incomplete; nothing will be sent even with the switch on."],
        .menuAgentGenerateSQL: [.simplifiedChinese: "用自然语言生成 SQL…", .english: "Generate SQL from plain language…"],
        .agentSQLTitle: [.simplifiedChinese: "自然语言 → SQL", .english: "Plain language → SQL"],
        .agentSQLInstruction: [.simplifiedChinese: "你想要什么？", .english: "What do you want?"],
        .agentSQLInstructionPlaceholder: [.simplifiedChinese: "例如：统计每个客户近 30 天的下单总额，按金额倒序", .english: "e.g. total order amount per customer over the last 30 days, highest first"],
        .agentSQLIncludeTables: [.simplifiedChinese: "把当前库的表清单发给模型", .english: "Send the current database's table list"],
        .agentSQLIncludeStatement: [.simplifiedChinese: "把编辑器里的当前语句发给模型", .english: "Send the statement currently in the editor"],
        .agentSQLPayload: [.simplifiedChinese: "将要外发的内容", .english: "What will be sent"],
        .agentSQLPayloadNote: [.simplifiedChinese: "只发下面这些内容；结果集行数据永不外发（NFR-AI-01）。数据库对象注释会被标记为不可信资料。", .english: "Only the content below is sent; result rows are never sent (NFR-AI-01). Object comments are marked as untrusted data."],
        .agentSQLGenerate: [.simplifiedChinese: "生成", .english: "Generate"],
        .agentSQLResult: [.simplifiedChinese: "生成结果（可编辑）", .english: "Result (editable)"],
        .agentSQLExplanation: [.simplifiedChinese: "模型说明", .english: "Model explanation"],
        .agentSQLGuard: [.simplifiedChinese: "护栏判定", .english: "Guardrail verdict"],
        .agentSQLNotExecuted: [.simplifiedChinese: "生成结果不会自动执行；请核对后再自行运行。", .english: "Generated SQL is never executed automatically — review it first."],
        .agentSQLInsertNewTab: [.simplifiedChinese: "在新页签中打开", .english: "Open in a new tab"],
        .agentSQLCopy: [.simplifiedChinese: "复制 SQL", .english: "Copy SQL"],
        .agentSQLCopied: [.simplifiedChinese: "已复制生成的 SQL。", .english: "Generated SQL copied."],
        .agentSQLFailed: [.simplifiedChinese: "生成失败：%@", .english: "Generation failed: %@"],
        .agentSQLNoInstruction: [.simplifiedChinese: "请先填写需求描述。", .english: "Please describe what you need first."],
        .agentSQLNoTables: [.simplifiedChinese: "未能取得表清单（可关闭该项后重试）。", .english: "Could not load the table list (turn that option off and retry)."],

        .stateNotConnected: [.simplifiedChinese: "未连接", .english: "Not connected"],
        .stateNotExecuted: [.simplifiedChinese: "未执行", .english: "Not run"],
        .stateSelectConnectionFirst: [.simplifiedChinese: "请先在左侧选择一个连接", .english: "Select a connection in the sidebar first"],
        .stateSQLEmpty: [.simplifiedChinese: "SQL 不能为空", .english: "SQL cannot be empty"],
        .stateChecking: [.simplifiedChinese: "正在检查…", .english: "Checking…"],
        .stateCheckPassed: [.simplifiedChinese: "语法检查通过：已检查 %d 条语句", .english: "Syntax check passed: %d statement(s) checked"],
        .stateCheckSkipped: [.simplifiedChinese: "，跳过 %d 条（DDL / 事务等）", .english: ", %d skipped (DDL/transactions, etc.)"],
        .stateCheckFailedItem: [.simplifiedChinese: "第 %d 条语句：%@", .english: "Statement %d: %@"],
        .stateCheckMoreErrors: [.simplifiedChinese: "\n还有 %d 条错误…", .english: "\n%d more error(s)…"],
        .stateConnecting: [.simplifiedChinese: "正在连接 %@ · %@ ...", .english: "Connecting %@ · %@ ..."],
        .stateExecuting: [.simplifiedChinese: "正在执行...", .english: "Executing..."],
        .stateExecutingStatement: [.simplifiedChinese: "正在执行第 %d 条语句...", .english: "Executing statement %d..."],
        .stateStatementNoResultSet: [.simplifiedChinese: "第 %d 条语句执行成功，没有返回结果集", .english: "Statement %d succeeded with no result set"],
        .stateStatementResult: [.simplifiedChinese: "第 %d 条语句返回 %d 行 × %d 列", .english: "Statement %d returned %d rows × %d columns"],
        .stateStatementAffectedRows: [.simplifiedChinese: "第 %d 条语句影响 %d 行", .english: "Statement %d affected %d rows"],
        .stateAffectedRows: [.simplifiedChinese: "影响 %d 行", .english: "%d rows affected"],
        .stateFinishedNoResult: [.simplifiedChinese: "执行完成，无结果集，耗时 %@ 秒", .english: "Finished with no result set in %@ s"],
        .stateFinishedMulti: [.simplifiedChinese: "执行完成：%d 条语句 / %d 个结果集，耗时 %@ 秒", .english: "Finished: %d statement(s), %d result(s) in %@ s"],
        .stateFinished: [.simplifiedChinese: "执行完成：%d 条语句，耗时 %@ 秒", .english: "Finished: %d statement(s) in %@ s"],
        .stateCancelled: [.simplifiedChinese: "已取消", .english: "Cancelled"],
        .stateExecutionFailed: [.simplifiedChinese: "执行失败", .english: "Execution failed"],
        .stateFinishedEmpty: [.simplifiedChinese: "执行完成，无结果集", .english: "Finished with no result set"],
        .stateQueryNoResultSet: [.simplifiedChinese: "查询没有返回结果集", .english: "The query returned no result set"],
        .stateMissingPassword: [.simplifiedChinese: "连接缺少密码，请重新编辑连接并保存密码", .english: "Password missing; edit the connection and save the password"],

        .errorInvalidConfiguration: [.simplifiedChinese: "连接配置无效：%@", .english: "Invalid connection configuration: %@"],
        .errorNotConnected: [.simplifiedChinese: "当前没有已建立的数据库连接", .english: "No database connection is established"],
        .errorNotImplemented: [.simplifiedChinese: "功能尚未实现：%@", .english: "Not implemented yet: %@"],
        .errorKeychain: [.simplifiedChinese: "Keychain 操作失败，OSStatus = %d", .english: "Keychain error, OSStatus = %d"],
        .errorPersistence: [.simplifiedChinese: "本地配置读写失败：%@", .english: "Local storage error: %@"],
        .errorQueryFailed: [.simplifiedChinese: "SQL 执行失败：%@", .english: "SQL execution failed: %@"],
        .alertErrorTitle: [.simplifiedChinese: "出错了", .english: "Something Went Wrong"],

        .lintLocation: [.simplifiedChinese: "第 %d 行第 %d 列", .english: "line %d, column %d"],
        .lintBlockComment: [.simplifiedChinese: "块注释没有闭合，缺少 */", .english: "Unterminated block comment; missing */"],
        .lintString: [.simplifiedChinese: "字符串没有闭合，缺少 '", .english: "Unterminated string; missing '"],
        .lintQuotedIdentifier: [.simplifiedChinese: "双引号标识符没有闭合，缺少 \"", .english: "Unterminated quoted identifier; missing \""],
        .lintDollarQuote: [.simplifiedChinese: "dollar-quoted 字符串没有闭合，缺少 %@", .english: "Unterminated dollar-quoted string; missing %@"],
        .lintExtraCloseParen: [.simplifiedChinese: "多余的右括号 )", .english: "Unmatched closing parenthesis )"],
        .lintMissingCloseParen: [.simplifiedChinese: "左括号 ( 没有对应的右括号 )", .english: "Unmatched opening parenthesis ("],
        .toolbarOpenFileHelp: [.simplifiedChinese: "打开 SQL / 文本文件", .english: "Open a SQL/text file"],
        .toolbarSaveFileHelp: [.simplifiedChinese: "保存到文件（⌘S）", .english: "Save to file (⌘S)"],
        .toolbarSaveAs: [.simplifiedChinese: "另存为…", .english: "Save As…"],
        .toolbarEditHelp: [.simplifiedChinese: "编辑", .english: "Edit"],
        .toolbarHelpHelp: [.simplifiedChinese: "帮助（内容待补充）", .english: "Help (coming soon)"],
        .editMenuFind: [.simplifiedChinese: "查找…", .english: "Find…"],
        .editMenuReplace: [.simplifiedChinese: "替换…", .english: "Replace…"],
        .editMenuGoToLine: [.simplifiedChinese: "跳到行 / 列…", .english: "Go to Line/Column…"],
        .editMenuIndent: [.simplifiedChinese: "缩进选中文本（4 空格）", .english: "Indent Selection (4 spaces)"],
        .editMenuOutdent: [.simplifiedChinese: "反缩进选中文本", .english: "Outdent Selection"],
        .editMenuClear: [.simplifiedChinese: "清除查询", .english: "Clear Query"],
        .editMenuFormat: [.simplifiedChinese: "格式化 SQL", .english: "Format SQL"],
        .workspaceUnboundTab: [.simplifiedChinese: "未绑定连接", .english: "No connection"],
        .workspaceUnboundHint: [.simplifiedChinese: "未绑定连接 · 选择服务器后即可执行", .english: "No connection · choose a server to run"],
        .fileOpenFailed: [.simplifiedChinese: "打开文件失败：%@", .english: "Failed to open file: %@"],
        .fileSaveFailed: [.simplifiedChinese: "保存文件失败：%@", .english: "Failed to save file: %@"],
        .fileSaved: [.simplifiedChinese: "已保存：%@", .english: "Saved: %@"],
        .goToLineTitle: [.simplifiedChinese: "跳到行 / 列", .english: "Go to Line/Column"],
        .goToLineLine: [.simplifiedChinese: "行号", .english: "Line"],
        .goToLineColumn: [.simplifiedChinese: "列号（可选）", .english: "Column (optional)"],
        .goToLineInvalid: [.simplifiedChinese: "行号无效", .english: "Invalid line number"],
        .goToLineConfirm: [.simplifiedChinese: "跳转", .english: "Go"],
        .helpPlaceholder: [.simplifiedChinese: "帮助内容待补充", .english: "Help content coming soon"],
        .connectionDeleteConfirmTitle: [.simplifiedChinese: "删除连接？", .english: "Delete connection?"],
        .connectionDeleteConfirmMessage: [.simplifiedChinese: "将删除连接「%@」以及保存在钥匙串中的密码，该操作不可撤销。", .english: "This permanently deletes “%@” and its Keychain password."],
        .resultExport: [.simplifiedChinese: "导出结果", .english: "Export Result"],
        .exportCSV: [.simplifiedChinese: "导出为 CSV…", .english: "Export as CSV…"],
        .exportJSON: [.simplifiedChinese: "导出为 JSON…", .english: "Export as JSON…"],
        .exportTSV: [.simplifiedChinese: "导出为 TSV…", .english: "Export as TSV…"],
        .exportMarkdown: [.simplifiedChinese: "导出为 Markdown 表格…", .english: "Export as Markdown Table…"],
        .exportSQLInsert: [.simplifiedChinese: "导出为 INSERT 语句…", .english: "Export as INSERT Statements…"],
        .exportSucceeded: [.simplifiedChinese: "已导出 %d 行到 %@", .english: "Exported %d rows to %@"],
        .exportFailed: [.simplifiedChinese: "导出失败：%@", .english: "Export failed: %@"],
        .exportNoData: [.simplifiedChinese: "当前结果没有可导出的数据", .english: "The current result has no data to export"],
        .historyTitle: [.simplifiedChinese: "查询历史", .english: "Query History"],
        .historyEmpty: [.simplifiedChinese: "本次运行还没有执行过查询", .english: "No queries executed in this session"],
        .historyClear: [.simplifiedChinese: "清空历史", .english: "Clear History"],
        .historyHelp: [.simplifiedChinese: "查询历史（仅保留在内存，退出即清空）", .english: "Query history (in memory only, cleared on quit)"],
        .historyLoadHelp: [.simplifiedChinese: "载入到当前页签", .english: "Load into current tab"],
        .editorCompletionHelp: [.simplifiedChinese: "补全（F5 或 Esc）", .english: "Complete (F5 or Esc)"],
        .objectTreeMenuConnect: [.simplifiedChinese: "连接", .english: "Connect"],
        .objectTreeMenuDisconnect: [.simplifiedChinese: "断开", .english: "Disconnect"],
        .objectTreeMenuEditConnection: [.simplifiedChinese: "编辑连接…", .english: "Edit Connection…"],
        .objectTreeMenuCreateDatabase: [.simplifiedChinese: "新建数据库…", .english: "New Database…"],
        .objectTreeStatusConnected: [.simplifiedChinese: "已连接：%@", .english: "Connected: %@"],
        .objectTreeStatusDisconnected: [.simplifiedChinese: "已断开：%@", .english: "Disconnected: %@"],
        .createDatabaseTitle: [.simplifiedChinese: "新建数据库", .english: "New Database"],
        .createDatabaseNamePlaceholder: [.simplifiedChinese: "数据库名", .english: "Database name"],
        .createDatabaseHint: [.simplifiedChinese: "字母或下划线开头，可含数字、下划线与 $，最多 63 个字符；名称中的特殊字符会被自动加引号。", .english: "Start with a letter or underscore; may contain digits, underscore and $; up to 63 characters. Special characters are quoted automatically."],
        .createDatabaseInvalid: [.simplifiedChinese: "数据库名不合法", .english: "Invalid database name"],
        .createDatabaseConfirm: [.simplifiedChinese: "创建", .english: "Create"],
        .createDatabaseSucceeded: [.simplifiedChinese: "已创建数据库 %@", .english: "Database %@ created"],
        .createDatabaseFailed: [.simplifiedChinese: "创建数据库失败：%@", .english: "Failed to create database: %@"],
    ]
}
