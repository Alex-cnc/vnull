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

    // 活动栏与工作区（FR-EDIT-32）
    case menuViewDatabase
    case menuViewWorkspace
    case activityDatabase
    case activityWorkspace
    case activityAccount
    case activitySettings
    case workspaceChoose
    case workspaceSwitch
    case workspaceEmptyTitle
    case workspaceEmptyHint
    case workspaceRefresh
    case workspaceReveal
    case workspaceTreeEmpty
    case workspaceLoading
    case workspaceSearchPlaceholder
    case workspaceSearchResultCount
    case workspaceSearchTruncated
    case workspaceSearchEmpty
    case archiveUsingWorkspace
    case directoryStatusGranted
    case directoryStatusStale
    case directoryStatusNotAuthorized
    case directoryStatusMissing
    case directoryStatusDenied
    case directoryStatusFailed
    case accountUndecidedTitle
    case accountUndecidedMessage

    // 外观（FR-EDIT-33）
    case menuAppearance
    case appearanceTitle
    case appearanceAccentSection
    case appearanceAccentHint
    case appearanceThemeNote
    case accentWhaleBlue
    case accentDeepTeal
    case accentWhaleMagenta

    // 表设计（FR-DDL-03）
    case tableDesignTitle
    case tableDesignName
    case tableDesignSchema
    case tableDesignSchemaHint
    case tableDesignColumns
    case tableDesignAddColumn
    case tableDesignColumnName
    case tableDesignColumnType
    case tableDesignColumnNullable
    case tableDesignColumnPrimaryKey
    case tableDesignColumnDefault
    case tableDesignPreview
    case tableDesignCreate
    case tableDesignHint
    case tableDesignCreated
    case tableDesignFailed
    case tableDesignInvalid
    case tableDesignRemoveColumn
    case tableDesignAlterTitle
    case tableDesignApply
    case tableDesignNoChanges
    case tableDesignDestructive
    case tableDesignPrimaryKeyLocked
    case tableDesignLoading
    case tableDesignLoadFailed
    case tableDesignAltered
    case tableDesignAlterFailed
    case tableIssueNameEmpty
    case tableIssueNameInvalid
    case tableIssueNoColumns
    case tableIssueColumnNameEmpty
    case tableIssueColumnNameInvalid
    case tableIssueColumnNameDuplicate
    case tableIssueColumnTypeEmpty

    // 查询自动归档（FR-EDIT-31）
    case archiveTitle
    case archiveEnable
    case archiveEnableHint
    case archiveChooseDirectory
    case archiveDirectoryGranted
    case archiveDirectoryNotAuthorized
    case archiveDirectoryHint
    case archiveSaved
    case archiveFailed
    case archiveOpenFolder
    case archiveDirectoryStale

    // 下方面板（结果 / 问题 / 输出 / 终端 / 调试控制台）
    case lowerPaneProblem
    case lowerPaneOutput
    case lowerPaneTerminal
    case lowerPaneDebugConsole
    case lowerPaneToggle
    case lowerPaneHide
    case lowerPaneMaximize
    case lowerPaneRestore
    case lowerPaneProblemEmpty
    case lowerPaneOutputEmpty
    case lowerPaneDebugPlaceholder
    case lowerPaneClear
    case terminalRestart
    case terminalStopped

    // 系统级菜单的语言需要重启才跟随（macOS 在进程启动时固定 AppKit 的本地化）
    case relaunchTitle
    case relaunchMessage
    case relaunchMessageUnsaved
    case relaunchNow
    case relaunchLater

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
    case resultTruncated
    case resultTruncatedTag
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
    case agentSQLSubmit
    case agentSQLSubmittedPending
    case agentSQLSubmittedAuto
    case agentSQLDenied

    // 执行审批与审计（FR-AI-09 / NFR-AI-03）
    case menuAgentAudit
    case agentApprovalConnectionMismatch
    case menuNewBrowserTab
    case browserTitle
    case browserRestoredTitle
    case browserRestoredHint
    case browserAddressPlaceholder
    case browserBack
    case browserForward
    case browserReload
    case browserStop
    case browserEmptyHint
    case menuEgressLog
    case egressColumnTime
    case egressColumnKind
    case egressColumnTarget
    case egressColumnOrigin
    case egressColumnOutcome
    case egressTitle
    case egressSubtitle
    case egressEmpty
    case egressClear
    case egressClearConfirmTitle
    case egressClearConfirmMessage
    case egressCleared
    case egressExportCSV
    case egressExportJSON
    case egressExported
    case egressExportEmpty
    case egressExportFailed
    case egressKindAgentModel
    case egressKindBrowser
    case egressKindExternalProgram
    case egressKindUpdateCheck
    case egressOutcomeAllowed
    case egressOutcomeDenied
    case egressOutcomeFailed
    case egressCount
    case agentAuditTitle
    case agentAuditRefresh
    case agentAuditClear
    case agentAuditClearConfirmTitle
    case agentAuditClearConfirmMessage
    case agentAuditCleared
    case agentAuditExportJSON
    case agentAuditExportCSV
    case agentAuditExport
    case agentAuditExported
    case agentAuditExportFailed
    case agentAuditExportEmpty
    case agentAuditEmpty
    case agentAuditFilteredEmpty
    case agentAuditFilterOutcome
    case agentAuditFilterAll
    case agentAuditFilterConnection
    case agentAuditFilterSearch
    case agentAuditRecords
    case agentAuditRecordsCount
    case agentAuditColumnTime
    case agentAuditColumnConnection
    case agentAuditColumnStatement
    case agentAuditColumnModel
    case agentAuditColumnOutcome
    case agentAuditOriginModelCall
    case agentAuditColumnDuration
    case agentAuditColumnGuard
    case agentAuditSelectHint
    case agentAuditGuardNone
    case agentAuditRedactedHint
    case agentAuditLoadFailed

    // 逐次审批（FR-AI-09）
    case agentApprovalSection
    case agentApprovalEmpty
    case agentApprovalTitle
    case agentApprovalMessage
    case agentApprovalApprove
    case agentApprovalReject
    case agentApprovalNote
    case agentApprovalReview
    case agentApprovalPendingCount
    case agentApprovalApproved
    case agentApprovalRejected
    case agentApprovalDismissHint

    // 只读模式与白名单（FR-AI-09）
    case agentGuardSection
    case agentReadOnlyMode
    case agentReadOnlyHint
    case agentAllowlist
    case agentAllowlistHint
    case agentGuardSave
    case agentGuardSaved
    case agentGuardWritesWarning

    // 智能体语句类别 / 结果状态 / 风险等级（界面展示用）
    case agentKindReadQuery
    case agentKindDataChange
    case agentKindSchemaChange
    case agentKindPrivilegeChange
    case agentKindSessionControl
    case agentKindUnknown
    case agentOutcomeGenerated
    case agentOutcomeDenied
    case agentOutcomePendingApproval
    case agentOutcomeApproved
    case agentOutcomeRejected
    case agentOutcomeExpired
    case agentOutcomeExecuted
    case agentOutcomeFailed
    case agentRiskLow
    case agentRiskElevated
    case agentRiskDestructive

    // 数据任务（FR-AI-05 / FR-AI-06 / FR-AI-08）
    case menuDataTask
    case dataTaskTitle
    case dataTaskName
    case dataTaskNotExecutedHint
    case dataTaskRefresh
    case dataTaskNew
    case dataTaskRevert
    case dataTaskSave
    case dataTaskDelete
    case dataTaskDeleteConfirmTitle
    case dataTaskDeleteConfirmMessage
    case dataTaskDeleted
    case dataTaskDeleteFailed
    case dataTaskSaved
    case dataTaskSaveFailed
    case dataTaskLoadFailed
    case dataTaskSearchPlaceholder
    case dataTaskOnlyEnabled
    case dataTaskListEmpty
    case dataTaskNoSelection
    case dataTaskSelectHint
    case dataTaskEnabled
    case dataTaskEnable
    case dataTaskDisable
    case dataTaskDisabledHint
    case dataTaskSectionSpecs
    case dataTaskSpecsHint
    case dataTaskSectionSource
    case dataTaskSchema
    case dataTaskTable
    case dataTaskSourceColumns
    case dataTaskSourceColumnsHint
    case dataTaskFilter
    case dataTaskFilterHint
    case dataTaskSectionTransformations
    case dataTaskAddTransformation
    case dataTaskRemoveTransformation
    case dataTaskTransformationColumn
    case dataTaskTransformationTargetColumn
    case dataTaskTransformationExpression
    case dataTaskTransformEmpty
    case dataTaskSectionTarget
    case dataTaskTargetTable
    case dataTaskWriteMode
    case dataTaskKeyColumns
    case dataTaskKeyColumnsHint
    case dataTaskSectionSchedule
    case dataTaskScheduleKind
    case dataTaskRunAt
    case dataTaskIntervalSeconds
    case dataTaskStartAt
    case dataTaskDateHint
    case dataTaskSectionExport
    case dataTaskExportFormat
    case dataTaskFileNameTemplate
    case dataTaskFileNameHint
    case dataTaskChooseDirectory
    case dataTaskUseStoredDirectory
    case dataTaskNoStoredDirectory
    case dataTaskDirectoryGranted
    case dataTaskDirectoryGrantedStale
    case dataTaskDirectoryNotAuthorized
    case dataTaskDirectoryMissing
    case dataTaskDirectoryDenied
    case dataTaskDirectoryResolutionFailed
    case dataTaskDirectoryHintNotAuthorized
    case dataTaskDirectoryHintMissing
    case dataTaskDirectoryHintDenied
    case dataTaskDirectoryHintResolutionFailed
    case dataTaskExportVerify
    case dataTaskExportVerifySucceeded
    case dataTaskSectionPreview
    case dataTaskDryRun
    case dataTaskDryRunHint
    case dataTaskPreviewSteps
    case dataTaskPreviewSQL
    case dataTaskPreviewWarnings
    case dataTaskPreviewIssues
    case dataTaskNoIssues
    case dataTaskNeedDryRun
    case dataTaskSaveBlocked
    case dataTaskWriteStatement
    case dataTaskGuardVerdict
    case dataTaskSectionRuntime
    case dataTaskStatusNotScheduled
    case dataTaskStatusDisabled
    case dataTaskStatusWaiting
    case dataTaskStatusDue
    case dataTaskStatusMissed
    case dataTaskNextRun
    case dataTaskPlannedAt
    case dataTaskMissedNotice
    case dataTaskRunNow
    case dataTaskDueNotice
    case dataTaskRunPending
    case dataTaskRunDenied
    case dataTaskRunSucceeded
    case dataTaskRunSucceededNoArtifact
    case dataTaskRunFailed
    case dataTaskRunArtifactFailed
    case dataTaskRunRejected
    case dataTaskRunNotConnected
    case dataTaskSectionHistory
    case dataTaskHistoryEmpty
    case dataTaskHistoryCount
    case dataTaskHistoryColumnTime
    case dataTaskHistoryColumnStatus
    case dataTaskHistoryColumnRows
    case dataTaskHistoryColumnDuration
    case dataTaskHistoryColumnMessage
    case dataTaskRunStatusRunning
    case dataTaskRunStatusSucceeded
    case dataTaskRunStatusFailed
    case dataTaskRunStatusSkipped
    case dataTaskSpecOpen
    case dataTaskSpecTitle
    case dataTaskSpecInput
    case dataTaskSpecHints
    case dataTaskSpecPayload
    case dataTaskSpecGenerate
    case dataTaskSpecApply
    case dataTaskSpecFailed
    case dataTaskSpecNotExecuted
    case dataTaskSpecGenerated
    case dataTaskSpecDisabled
    case dataTaskSpecNoInput
    case dataTaskSpecHint
    case dataTaskTransformKindRename
    case dataTaskTransformKindCast
    case dataTaskTransformKindDerive
    case dataTaskTransformKindDrop
    case dataTaskTransformKindMask
    case dataTaskWriteModeAppend
    case dataTaskWriteModeOverwrite
    case dataTaskWriteModeUpsert
    case dataTaskScheduleKindManual
    case dataTaskScheduleKindOnce
    case dataTaskScheduleKindRecurring
    case dataTaskOverwriteWarning
    case dataTaskUpsertWarning

    // 高危语句保护（FR-EXEC-16）
    case toolbarSafety
    case safetySafeMode
    case safetySafeModeHint
    case safetyConfirmAllWrites
    case safetyConfirmTitle
    case safetyConfirmMessage
    case safetyConfirmRun
    case safetyConfirmCancel

    // 运行范围控制（FR-EXEC-14）
    case toolbarRunScope
    case runScopeAll
    case runScopeCurrentStatement
    case runScopeSelection
    case runScopeHint
    case runScopeEmptySelection
    case runScopeNoStatement
    case runScopeEmptyText

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
    case stateCancelNotDelivered
    case stateCancelAlreadyDone
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
    case helpShortcutsTitle

    // 对象树节点动作（FR-META-14）
    case treeActionBrowseRows
    case treeActionSelectTemplate
    case treeActionInsertTemplate
    case treeActionCopyQualifiedName
    case treeActionCopyColumnName
    case treeActionViewDDL
    case treeActionTruncate
    case treeActionDrop
    case treeActionUnavailable
    case objectTreeCopied
    case objectTreeOpenedInNewTab

    // 执行计划面板（FR-DIAG-01）
    case planTitle
    case planRun
    case planAnalyze
    case planAnalyzeWarning
    case planBuffers
    case planFormatJSON
    case planSummary
    case planTree
    case planRaw
    case planEmpty
    case planUnsupported
    case planMultipleStatements
    case planFailed
    case toolbarPlanHelp
    case planSequentialScan

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
        .menuViewDatabase: [.simplifiedChinese: "数据库视图", .english: "Database View"],
        .menuViewWorkspace: [.simplifiedChinese: "工作区视图", .english: "Workspace View"],
        .activityDatabase: [.simplifiedChinese: "数据库", .english: "Database"],
        .activityWorkspace: [.simplifiedChinese: "工作区", .english: "Workspace"],
        .activityAccount: [.simplifiedChinese: "账户", .english: "Account"],
        .activitySettings: [.simplifiedChinese: "设置", .english: "Settings"],
        .workspaceChoose: [.simplifiedChinese: "选择文件夹…", .english: "Choose Folder…"],
        .workspaceSwitch: [.simplifiedChinese: "切换工作区…", .english: "Switch Workspace…"],
        .workspaceEmptyTitle: [.simplifiedChinese: "还没有选择工作区", .english: "No workspace yet"],
        .workspaceEmptyHint: [.simplifiedChinese: "选一个本地目录作为工作区：终端会在那里启动，查询归档与智能体的文件读写也都以它为准。", .english: "Pick a local folder as your workspace: the terminal starts there, and query archiving plus the agent's file access follow it."],
        .workspaceRefresh: [.simplifiedChinese: "刷新", .english: "Refresh"],
        .workspaceReveal: [.simplifiedChinese: "在访达中显示", .english: "Reveal in Finder"],
        .workspaceTreeEmpty: [.simplifiedChinese: "这个目录里没有可显示的条目。", .english: "Nothing to show in this folder."],
        .workspaceLoading: [.simplifiedChinese: "正在读取…", .english: "Loading…"],
        .workspaceSearchPlaceholder: [.simplifiedChinese: "搜索文件名…", .english: "Search file names…"],
        .workspaceSearchResultCount: [.simplifiedChinese: "找到 %@ 个文件", .english: "%@ files found"],
        .workspaceSearchTruncated: [.simplifiedChinese: "结果已达上限，请输入更精确的关键词。", .english: "Result limit reached — type a more specific query."],
        .workspaceSearchEmpty: [.simplifiedChinese: "没有匹配的文件。", .english: "No matching files."],
        .archiveUsingWorkspace: [.simplifiedChinese: "未单独指定归档目录，当前使用工作区：%@", .english: "No archive folder chosen — using the workspace: %@"],
        .directoryStatusGranted: [.simplifiedChinese: "已授权读写：%@", .english: "Read-write access granted: %@"],
        .directoryStatusStale: [.simplifiedChinese: "已授权读写：%@（书签已过期，建议重新选择一次）", .english: "Read-write access granted: %@ (bookmark is stale — choose the folder again)"],
        .directoryStatusNotAuthorized: [.simplifiedChinese: "尚未授权目录", .english: "No folder authorised yet"],
        .directoryStatusMissing: [.simplifiedChinese: "目录已不存在：%@", .english: "Folder no longer exists: %@"],
        .directoryStatusDenied: [.simplifiedChinese: "没有访问权限：%@", .english: "Access denied: %@"],
        .directoryStatusFailed: [.simplifiedChinese: "书签无法解析，建议重新选择目录", .english: "Bookmark could not be resolved — choose the folder again"],
        .accountUndecidedTitle: [.simplifiedChinese: "账户功能还没定", .english: "The account feature is not decided yet"],
        .accountUndecidedMessage: [.simplifiedChinese: "「登录后提供什么」还没定：模型配额与计费、配置跨机同步、许可校验，三者的架构代价完全不同。在定下来之前这里只放占位入口，不实现登录流程。密钥与密码也不会参与任何同步。", .english: "What signing in should give you is still undecided: model quota and billing, config sync across machines, and licence checks all cost very differently to build. Until that is settled this stays a placeholder — no sign-in flow is implemented, and secrets never take part in any sync."],
        .menuAppearance: [.simplifiedChinese: "外观…", .english: "Appearance…"],
        .appearanceTitle: [.simplifiedChinese: "外观", .english: "Appearance"],
        .appearanceAccentSection: [.simplifiedChinese: "强调色", .english: "Accent Color"],
        .appearanceAccentHint: [.simplifiedChinese: "强调色只用在选中态、主按钮与焦点环上，其余保持中性。", .english: "Used only for selections, the primary button and focus rings; everything else stays neutral."],
        .appearanceThemeNote: [.simplifiedChinese: "主题跟随系统外观：浅色走原生精致，深色走专业暗色。", .english: "Theme follows the system appearance: refined native in light, pro dark in dark."],
        .accentWhaleBlue: [.simplifiedChinese: "鲸鱼蓝", .english: "Whale Blue"],
        .accentDeepTeal: [.simplifiedChinese: "深海青", .english: "Deep Teal"],
        .accentWhaleMagenta: [.simplifiedChinese: "鲸心品红", .english: "Whale Magenta"],
        .tableDesignAlterTitle: [.simplifiedChinese: "编辑表结构", .english: "Edit Table Structure"],
        .tableDesignApply: [.simplifiedChinese: "应用变更", .english: "Apply changes"],
        .tableDesignNoChanges: [.simplifiedChinese: "没有改动。", .english: "No changes."],
        .tableDesignDestructive: [.simplifiedChinese: "以下变更会动到已有数据（删列 / 改类型），请确认：", .english: "These changes affect existing data (dropping a column or changing a type):"],
        .tableDesignPrimaryKeyLocked: [.simplifiedChinese: "主键在「编辑表结构」里只读：改主键要先删约束再重建，容易误伤数据，留待后续版本。", .english: "Primary keys are read-only while editing: changing one means dropping and recreating a constraint, which is easy to get wrong. Deferred to a later version."],
        .tableDesignLoading: [.simplifiedChinese: "正在读取表结构…", .english: "Loading table structure…"],
        .tableDesignLoadFailed: [.simplifiedChinese: "读取表结构失败：%@", .english: "Loading the table structure failed: %@"],
        .tableDesignAltered: [.simplifiedChinese: "已更新表 %@（%@ 项变更）。", .english: "Updated table %@ (%@ changes)."],
        .tableDesignAlterFailed: [.simplifiedChinese: "第 %d 条变更执行失败：%@", .english: "Change %d failed: %@"],
        .tableDesignTitle: [.simplifiedChinese: "新建表", .english: "New Table"],
        .tableDesignName: [.simplifiedChinese: "表名", .english: "Table name"],
        .tableDesignSchema: [.simplifiedChinese: "模式（schema，可留空）", .english: "Schema (optional)"],
        .tableDesignSchemaHint: [.simplifiedChinese: "留空表示用当前搜索路径里的模式。", .english: "Leave empty to use the current search path."],
        .tableDesignColumns: [.simplifiedChinese: "列", .english: "Columns"],
        .tableDesignAddColumn: [.simplifiedChinese: "添加列", .english: "Add column"],
        .tableDesignColumnName: [.simplifiedChinese: "列名", .english: "Name"],
        .tableDesignColumnType: [.simplifiedChinese: "类型", .english: "Type"],
        .tableDesignColumnNullable: [.simplifiedChinese: "可空", .english: "Nullable"],
        .tableDesignColumnPrimaryKey: [.simplifiedChinese: "主键", .english: "Primary key"],
        .tableDesignColumnDefault: [.simplifiedChinese: "默认值", .english: "Default"],
        .tableDesignPreview: [.simplifiedChinese: "将要执行的 DDL", .english: "DDL to be executed"],
        .tableDesignCreate: [.simplifiedChinese: "创建", .english: "Create"],
        .tableDesignHint: [.simplifiedChinese: "先核对下面的语句；点「创建」之前不会对数据库做任何事。", .english: "Review the statement below; nothing touches the database until you press Create."],
        .tableDesignCreated: [.simplifiedChinese: "已创建表 %@。", .english: "Created table %@."],
        .tableDesignFailed: [.simplifiedChinese: "创建表失败：%@", .english: "Creating the table failed: %@"],
        .tableDesignInvalid: [.simplifiedChinese: "表定义还有问题，请按提示修正。", .english: "The table definition still has problems; fix the listed items."],
        .tableDesignRemoveColumn: [.simplifiedChinese: "移除这一列", .english: "Remove this column"],
        .tableIssueNameEmpty: [.simplifiedChinese: "请先填写表名。", .english: "Enter a table name first."],
        .tableIssueNameInvalid: [.simplifiedChinese: "表名不合法：%@", .english: "Invalid table name: %@"],
        .tableIssueNoColumns: [.simplifiedChinese: "至少要有一列。", .english: "At least one column is required."],
        .tableIssueColumnNameEmpty: [.simplifiedChinese: "第 %d 列还没有名字。", .english: "Column %d has no name yet."],
        .tableIssueColumnNameInvalid: [.simplifiedChinese: "列名不合法：%@", .english: "Invalid column name: %@"],
        .tableIssueColumnNameDuplicate: [.simplifiedChinese: "列名重复：%@", .english: "Duplicate column name: %@"],
        .tableIssueColumnTypeEmpty: [.simplifiedChinese: "列 %@ 还没有类型。", .english: "Column %@ has no type yet."],
        .archiveTitle: [.simplifiedChinese: "查询归档", .english: "Query Archive"],
        .archiveEnable: [.simplifiedChinese: "自动保存执行的 SQL（按天一个文件）", .english: "Auto-save executed SQL (one file per day)"],
        .archiveEnableHint: [.simplifiedChinese: "执行成功后把语句追加进当天的 .sql 文件：同一条 SQL 只累计执行次数，不重复抄写。文件本身可以直接拿去执行。", .english: "After a successful run the statement is appended to that day's .sql file. Repeated statements only increase a run count instead of being copied again, and the file itself is runnable."],
        .archiveChooseDirectory: [.simplifiedChinese: "选择归档目录…", .english: "Choose archive folder…"],
        .archiveDirectoryGranted: [.simplifiedChinese: "归档目录：%@", .english: "Archive folder: %@"],
        .archiveDirectoryNotAuthorized: [.simplifiedChinese: "尚未选择归档目录。", .english: "No archive folder chosen yet."],
        .archiveDirectoryHint: [.simplifiedChinese: "文件写在所选目录的 queries/ 子目录下，例如 queries/2026-09-23.sql。", .english: "Files go into a queries/ subfolder of the chosen folder, e.g. queries/2026-09-23.sql."],
        .archiveSaved: [.simplifiedChinese: "已归档到 %@（当天 %d 条）", .english: "Archived to %@ (%d today)"],
        .archiveFailed: [.simplifiedChinese: "查询归档写入失败：%@", .english: "Writing the query archive failed: %@"],
        .archiveDirectoryStale: [.simplifiedChinese: "（授权书签已过期，建议重新选择一次）", .english: " (the bookmark is stale; please re-select it)"],
        .archiveOpenFolder: [.simplifiedChinese: "在访达中显示", .english: "Reveal in Finder"],
        .lowerPaneProblem: [.simplifiedChinese: "问题", .english: "Problems"],
        .lowerPaneOutput: [.simplifiedChinese: "输出", .english: "Output"],
        .lowerPaneTerminal: [.simplifiedChinese: "终端", .english: "Terminal"],
        .lowerPaneDebugConsole: [.simplifiedChinese: "调试控制台", .english: "Debug Console"],
        .lowerPaneToggle: [.simplifiedChinese: "显示 / 隐藏下方面板", .english: "Show/Hide Bottom Pane"],
        .lowerPaneHide: [.simplifiedChinese: "收起面板", .english: "Collapse pane"],
        .lowerPaneMaximize: [.simplifiedChinese: "最大化面板", .english: "Maximize pane"],
        .lowerPaneRestore: [.simplifiedChinese: "恢复面板", .english: "Restore pane"],
        .lowerPaneProblemEmpty: [.simplifiedChinese: "还没有问题。执行 SQL 的错误与语法诊断会出现在这里。", .english: "No problems. SQL errors and syntax diagnostics will show up here."],
        .lowerPaneOutputEmpty: [.simplifiedChinese: "还没有输出。执行 SQL 的状态、影响行数与耗时摘要会出现在这里。", .english: "No output yet. Execution status, affected rows and timings will show up here."],
        .lowerPaneDebugPlaceholder: [.simplifiedChinese: "调试控制台占位：等客户端具备编程 IDE 能力（断点 / 变量查看 / 求值）时接入。", .english: "Debug console placeholder: to be wired up when the client gains IDE-style debugging (breakpoints, variables, evaluation)."],
        .lowerPaneClear: [.simplifiedChinese: "清空", .english: "Clear"],
        .terminalRestart: [.simplifiedChinese: "重新开始 shell", .english: "Restart shell"],
        .terminalStopped: [.simplifiedChinese: "已停止", .english: "Stopped"],
        .relaunchTitle: [.simplifiedChinese: "系统菜单需要重启才能跟随", .english: "Restart to switch the system menus"],
        .relaunchMessage: [.simplifiedChinese: "应用界面已经切换。系统级菜单（文件 / 编辑 / 显示 / 窗口 / 帮助）由 macOS 渲染，语言在启动时就已固定，需要重启才能一起切换。", .english: "The app UI has switched. macOS renders the system menus (File, Edit, View, Window, Help) and fixes their language at launch, so a restart is needed for them to follow."],
        .relaunchMessageUnsaved: [.simplifiedChinese: "注意：还有 %d 个页签有未保存的改动，重启会丢失。", .english: "Note: %d tab(s) have unsaved changes that would be lost."],
        .relaunchNow: [.simplifiedChinese: "立即重启", .english: "Restart now"],
        .relaunchLater: [.simplifiedChinese: "稍后", .english: "Later"],

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
        .toolbarExecuteHelp: [.simplifiedChinese: "执行 SQL", .english: "Run SQL"],
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
        .resultTruncated: [.simplifiedChinese: "结果已截断：仅显示前 %d 行，还有更多行未取（可在结果区调整上限或加 LIMIT）", .english: "Result truncated: showing the first %d rows; more rows were not fetched (raise the limit or add LIMIT)"],
        .resultTruncatedTag: [.simplifiedChinese: "已截断", .english: "truncated"],
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
        .menuAgentGenerateSQL: [.simplifiedChinese: "文生 SQL…", .english: "Text-to-SQL…"],
        .agentSQLTitle: [.simplifiedChinese: "自然语言 → SQL", .english: "Plain language → SQL"],
        .agentSQLInstruction: [.simplifiedChinese: "你想要什么？", .english: "What do you want?"],
        .agentSQLInstructionPlaceholder: [.simplifiedChinese: "例如：统计每个客户近 30 天的下单总额，按金额倒序", .english: "e.g. total order amount per customer over the last 30 days, highest first"],
        .agentSQLIncludeTables: [.simplifiedChinese: "把当前库的表与列结构发给模型", .english: "Send table and column structure"],
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
        .agentSQLSubmit: [.simplifiedChinese: "提交审批…", .english: "Submit for approval…"],
        .agentSQLSubmittedPending: [.simplifiedChinese: "已提交审批：请在弹出的审批单里逐条批准或拒绝。", .english: "Submitted: approve or reject it in the approval sheet."],
        .agentSQLSubmittedAuto: [.simplifiedChinese: "该语句无需审批（只读或已在白名单内），已放入新页签，未自动执行。", .english: "No approval needed (read-only or allowlisted). Opened in a new tab; not executed automatically."],
        .agentSQLDenied: [.simplifiedChinese: "安全护栏已拒绝：%@", .english: "Refused by the guardrail: %@"],

        .menuAgentAudit: [.simplifiedChinese: "审批与审计…", .english: "Approvals & Audit…"],
        .menuEgressLog: [.simplifiedChinese: "外发日志…", .english: "Egress Log…"],
        .menuNewBrowserTab: [.simplifiedChinese: "新建浏览器页签", .english: "New Browser Tab"],
        .browserTitle: [.simplifiedChinese: "浏览器", .english: "Browser"],
        .browserRestoredTitle: [.simplifiedChinese: "已恢复的页签（尚未加载）", .english: "Restored tab (not loaded yet)"],
        .browserRestoredHint: [.simplifiedChinese: "恢复会话不会自动发起请求 —— 点「刷新」才会真正加载。", .english: "Restoring a session never fires a request by itself — press Reload to actually load it."],        .browserAddressPlaceholder: [.simplifiedChinese: "输入地址后回车（默认不加载任何远程内容）", .english: "Type an address and press Return (nothing remote loads by default)"],
        .browserBack: [.simplifiedChinese: "后退", .english: "Back"],
        .browserForward: [.simplifiedChinese: "前进", .english: "Forward"],
        .browserReload: [.simplifiedChinese: "刷新", .english: "Reload"],
        .browserStop: [.simplifiedChinese: "停止", .english: "Stop"],
        .browserEmptyHint: [.simplifiedChinese: "空白页 —— 输入地址才会发起请求；每次出网都会记进「外发日志…」", .english: "Blank page — a request only happens when you navigate; every request is recorded in the Egress Log"],        .agentApprovalConnectionMismatch: [.simplifiedChinese: "审批单上的连接是「%@」，当前选中的是「%@」—— 已拒绝执行。请切回原连接后重新提交。", .english: "This approval was for connection \"%@\" but the current selection is \"%@\" — execution refused. Switch back to that connection and submit again."],
        .egressColumnTime: [.simplifiedChinese: "时间", .english: "Time"],
        .egressColumnKind: [.simplifiedChinese: "类别", .english: "Kind"],
        .egressColumnTarget: [.simplifiedChinese: "目标", .english: "Target"],
        .egressColumnOrigin: [.simplifiedChinese: "触发来源", .english: "Origin"],
        .egressColumnOutcome: [.simplifiedChinese: "结果", .english: "Outcome"],
        .egressTitle: [.simplifiedChinese: "外发日志", .english: "Egress Log"],
        .egressSubtitle: [.simplifiedChinese: "本机所有出网请求都会记在这里（智能体模型调用、内嵌浏览器、外部程序、更新检查）。默认零外发的承诺，靠它可查、可导出、可清空。", .english: "Every outbound request from this machine is recorded here (agent model calls, embedded browser, external tools, update checks). This is what makes the zero-egress promise verifiable."],
        .egressEmpty: [.simplifiedChinese: "还没有任何出网记录 —— 这就是「默认零外发」的样子", .english: "No egress records yet — this is what zero egress looks like"],
        .egressClear: [.simplifiedChinese: "清空", .english: "Clear"],
        .egressClearConfirmTitle: [.simplifiedChinese: "清空外发日志？", .english: "Clear the egress log?"],
        .egressClearConfirmMessage: [.simplifiedChinese: "清空后无法恢复。审计用的审批记录不受影响。", .english: "This cannot be undone. Approval audit records are not affected."],
        .egressCleared: [.simplifiedChinese: "外发日志已清空", .english: "Egress log cleared"],
        .egressExportCSV: [.simplifiedChinese: "导出 CSV", .english: "Export CSV"],
        .egressExportJSON: [.simplifiedChinese: "导出 JSON", .english: "Export JSON"],
        .egressExported: [.simplifiedChinese: "已导出 %d 条外发记录到 %@", .english: "Exported %d egress record(s) to %@"],
        .egressExportEmpty: [.simplifiedChinese: "还没有可导出的外发记录", .english: "No egress records to export yet"],
        .egressExportFailed: [.simplifiedChinese: "导出失败：%@", .english: "Export failed: %@"],
        .egressKindAgentModel: [.simplifiedChinese: "智能体模型", .english: "Agent model"],
        .egressKindBrowser: [.simplifiedChinese: "内嵌浏览器", .english: "Embedded browser"],
        .egressKindExternalProgram: [.simplifiedChinese: "外部程序", .english: "External tool"],
        .egressKindUpdateCheck: [.simplifiedChinese: "更新检查", .english: "Update check"],
        .egressOutcomeAllowed: [.simplifiedChinese: "已发出", .english: "Sent"],
        .egressOutcomeDenied: [.simplifiedChinese: "已拦下", .english: "Blocked"],
        .egressOutcomeFailed: [.simplifiedChinese: "失败", .english: "Failed"],
        .egressCount: [.simplifiedChinese: "共 %d 条", .english: "%d record(s)"],
        .agentAuditTitle: [.simplifiedChinese: "审批与审计", .english: "Approvals & Audit"],
        .agentAuditRefresh: [.simplifiedChinese: "刷新", .english: "Refresh"],
        .agentAuditClear: [.simplifiedChinese: "清空审计…", .english: "Clear audit…"],
        .agentAuditClearConfirmTitle: [.simplifiedChinese: "清空审计记录？", .english: "Clear audit records?"],
        .agentAuditClearConfirmMessage: [.simplifiedChinese: "将删除本地全部审计记录（agent-audit.jsonl），该操作不可撤销。", .english: "This permanently deletes all local audit records (agent-audit.jsonl)."],
        .agentAuditCleared: [.simplifiedChinese: "已清空审计记录。", .english: "Audit records cleared."],
        .agentAuditExportJSON: [.simplifiedChinese: "导出 JSON…", .english: "Export JSON…"],
        .agentAuditExportCSV: [.simplifiedChinese: "导出 CSV…", .english: "Export CSV…"],
        .agentAuditExport: [.simplifiedChinese: "导出审计记录", .english: "Export audit records"],
        .agentAuditExported: [.simplifiedChinese: "已导出 %d 条审计记录到 %@", .english: "Exported %d audit record(s) to %@"],
        .agentAuditExportFailed: [.simplifiedChinese: "导出审计记录失败：%@", .english: "Exporting audit records failed: %@"],
        .agentAuditExportEmpty: [.simplifiedChinese: "还没有可导出的审计记录", .english: "No audit records to export yet"],
        .agentAuditEmpty: [.simplifiedChinese: "还没有审计记录。智能体每次动作都会在这里留痕。", .english: "No audit records yet. Every agent action is recorded here."],
        .agentAuditFilteredEmpty: [.simplifiedChinese: "没有符合筛选条件的记录。", .english: "No records match the filter."],
        .agentAuditFilterOutcome: [.simplifiedChinese: "结果状态", .english: "Outcome"],
        .agentAuditFilterAll: [.simplifiedChinese: "全部", .english: "All"],
        .agentAuditFilterConnection: [.simplifiedChinese: "连接", .english: "Connection"],
        .agentAuditFilterSearch: [.simplifiedChinese: "搜索语句 / 连接 / 模型", .english: "Search statement, connection, model"],
        .agentAuditRecords: [.simplifiedChinese: "审计记录", .english: "Audit records"],
        .agentAuditRecordsCount: [.simplifiedChinese: "共 %d 条", .english: "%d record(s)"],
        .agentAuditColumnTime: [.simplifiedChinese: "时间", .english: "Time"],
        .agentAuditColumnConnection: [.simplifiedChinese: "连接", .english: "Connection"],
        .agentAuditColumnStatement: [.simplifiedChinese: "语句 / 动作", .english: "Statement / action"],
        .agentAuditColumnModel: [.simplifiedChinese: "模型", .english: "Model"],
        .agentAuditColumnOutcome: [.simplifiedChinese: "结果状态", .english: "Outcome"],
        .agentAuditColumnDuration: [.simplifiedChinese: "耗时", .english: "Duration"],
        .agentAuditOriginModelCall: [.simplifiedChinese: "模型调用", .english: "Model call"],
        .agentAuditColumnGuard: [.simplifiedChinese: "护栏判定", .english: "Guardrail"],
        .agentAuditSelectHint: [.simplifiedChinese: "选中一条记录，查看完整语句与护栏判定。", .english: "Select a record to see the full statement and guardrail verdict."],
        .agentAuditGuardNone: [.simplifiedChinese: "未发现高危操作", .english: "No high-risk finding"],
        .agentAuditRedactedHint: [.simplifiedChinese: "导出前会抹掉形似密钥的片段（API Key / 口令永不进审计）。", .english: "Secret-like fragments are redacted before export (API keys and passwords never enter the audit)."],
        .agentAuditLoadFailed: [.simplifiedChinese: "读取审计记录失败：%@", .english: "Loading audit records failed: %@"],

        .agentApprovalSection: [.simplifiedChinese: "待审批", .english: "Pending approvals"],
        .agentApprovalEmpty: [.simplifiedChinese: "没有待审批的动作。", .english: "No actions waiting for approval."],
        .agentApprovalTitle: [.simplifiedChinese: "智能体动作需要批准", .english: "Agent action needs approval"],
        .agentApprovalMessage: [.simplifiedChinese: "智能体发起的写操作 / DDL / 外部动作在执行前必须逐次批准，可以拒绝。", .english: "Agent-initiated writes, DDL and external actions must be approved one by one before running — and can be rejected."],
        .agentApprovalApprove: [.simplifiedChinese: "批准并执行", .english: "Approve & Run"],
        .agentApprovalReject: [.simplifiedChinese: "拒绝", .english: "Reject"],
        .agentApprovalNote: [.simplifiedChinese: "备注（可选，会记入审计）", .english: "Note (optional, recorded in the audit)"],
        .agentApprovalReview: [.simplifiedChinese: "查看…", .english: "Review…"],
        .agentApprovalPendingCount: [.simplifiedChinese: "待审批 %d 条", .english: "%d pending"],
        .agentApprovalApproved: [.simplifiedChinese: "已批准并执行。", .english: "Approved and run."],
        .agentApprovalRejected: [.simplifiedChinese: "已拒绝，动作不会执行。", .english: "Rejected; the action will not run."],
        .agentApprovalDismissHint: [.simplifiedChinese: "关闭本窗口不会批准，动作会留在「待审批」里。", .english: "Closing this sheet does not approve it; the action stays pending."],

        .agentGuardSection: [.simplifiedChinese: "只读模式与白名单", .english: "Read-only mode & allowlist"],
        .agentReadOnlyMode: [.simplifiedChinese: "只读模式（推荐）", .english: "Read-only mode (recommended)"],
        .agentReadOnlyHint: [.simplifiedChinese: "开启后，智能体发起的写操作 / DDL 一律被拒绝并给出可读原因。", .english: "When on, agent-initiated writes and DDL are refused with a readable reason."],
        .agentAllowlist: [.simplifiedChinese: "白名单（免审批的语句类别）", .english: "Allowlist (kinds exempt from approval)"],
        .agentAllowlistHint: [.simplifiedChinese: "白名单只免除审批，不能突破只读模式；无法归类的语句永远需要审批。", .english: "The allowlist only exempts kinds from approval and never bypasses read-only mode; unclassified statements always need approval."],
        .agentGuardSave: [.simplifiedChinese: "保存策略", .english: "Save policy"],
        .agentGuardSaved: [.simplifiedChinese: "已保存只读模式与白名单。", .english: "Read-only mode and allowlist saved."],
        .agentGuardWritesWarning: [.simplifiedChinese: "只读模式已关闭：智能体可以发起写操作 / DDL，每次仍需逐次批准。", .english: "Read-only mode is off: the agent may request writes/DDL, each still approved one by one."],

        .agentKindReadQuery: [.simplifiedChinese: "只读查询", .english: "Read-only query"],
        .agentKindDataChange: [.simplifiedChinese: "数据变更", .english: "Data change"],
        .agentKindSchemaChange: [.simplifiedChinese: "结构变更", .english: "Schema change"],
        .agentKindPrivilegeChange: [.simplifiedChinese: "权限变更", .english: "Privilege change"],
        .agentKindSessionControl: [.simplifiedChinese: "会话 / 事务控制", .english: "Session/transaction control"],
        .agentKindUnknown: [.simplifiedChinese: "无法识别的语句", .english: "Unrecognized statement"],
        .agentOutcomeGenerated: [.simplifiedChinese: "已生成（未执行）", .english: "Generated (not run)"],
        .agentOutcomeDenied: [.simplifiedChinese: "被护栏拒绝", .english: "Refused by guardrail"],
        .agentOutcomePendingApproval: [.simplifiedChinese: "待批准", .english: "Pending approval"],
        .agentOutcomeApproved: [.simplifiedChinese: "已批准", .english: "Approved"],
        .agentOutcomeRejected: [.simplifiedChinese: "已拒绝", .english: "Rejected"],
        .agentOutcomeExpired: [.simplifiedChinese: "已失效", .english: "Expired"],
        .agentOutcomeExecuted: [.simplifiedChinese: "已执行", .english: "Executed"],
        .agentOutcomeFailed: [.simplifiedChinese: "执行失败", .english: "Failed"],
        .agentRiskLow: [.simplifiedChinese: "低", .english: "Low"],
        .agentRiskElevated: [.simplifiedChinese: "较高", .english: "Elevated"],
        .agentRiskDestructive: [.simplifiedChinese: "高危", .english: "Destructive"],
        .toolbarSafety: [.simplifiedChinese: "防护", .english: "Safety"],
        .safetySafeMode: [.simplifiedChinese: "高危语句保护", .english: "Safe mode"],
        .safetySafeModeHint: [.simplifiedChinese: "对不带条件的批量更新 / 删除、删表、清空表等，执行前先确认一次。", .english: "Confirm once before running unqualified UPDATE/DELETE, DROP or TRUNCATE."],
        .safetyConfirmAllWrites: [.simplifiedChinese: "每次写入都确认", .english: "Confirm every write"],
        .safetyConfirmTitle: [.simplifiedChinese: "这条语句有风险，确定执行？", .english: "This statement looks risky. Run it?"],
        .safetyConfirmMessage: [.simplifiedChinese: "以下是检测到的风险点：", .english: "Detected risks:"],
        .safetyConfirmRun: [.simplifiedChinese: "仍然执行", .english: "Run anyway"],
        .safetyConfirmCancel: [.simplifiedChinese: "取消", .english: "Cancel"],
        .toolbarRunScope: [.simplifiedChinese: "运行范围", .english: "Run scope"],
        .runScopeAll: [.simplifiedChinese: "整篇", .english: "Entire script"],
        .runScopeCurrentStatement: [.simplifiedChinese: "光标所在语句", .english: "Statement at cursor"],
        .runScopeSelection: [.simplifiedChinese: "选中片段", .english: "Selection only"],
        .runScopeHint: [.simplifiedChinese: "选择执行时只跑哪一段；被 Safe Mode 拦下时也只检查这一段。", .english: "Which part to run; Safe mode only checks this part too."],
        .runScopeEmptySelection: [.simplifiedChinese: "没有选中任何内容，请先选中要执行的片段。", .english: "Nothing is selected — select the fragment you want to run first."],
        .runScopeNoStatement: [.simplifiedChinese: "光标不在任何语句上。", .english: "The cursor is not on any statement."],
        .runScopeEmptyText: [.simplifiedChinese: "编辑器里还没有内容。", .english: "The editor is empty."],

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
        .stateCancelNotDelivered: [.simplifiedChinese: "停止未能下发到服务端：%@（该查询可能仍在运行）", .english: "Stop was not delivered to the server: %@ (the query may still be running)"],
        .stateCancelAlreadyDone: [.simplifiedChinese: "该语句已结束，无需停止", .english: "That statement already finished — nothing to stop"],
        .stateExecutionFailed: [.simplifiedChinese: "执行失败", .english: "Execution failed"],
        .stateFinishedEmpty: [.simplifiedChinese: "执行完成，无结果集", .english: "Finished with no result set"],
        .stateQueryNoResultSet: [.simplifiedChinese: "查询没有返回结果集", .english: "The query returned no result set"],
        .stateMissingPassword: [.simplifiedChinese: "连接缺少密码，请重新编辑连接并保存密码", .english: "Password missing; edit the connection and save the password"],

        .errorInvalidConfiguration: [.simplifiedChinese: "连接配置无效：%@", .english: "Invalid connection configuration: %@"],
        .errorNotConnected: [.simplifiedChinese: "当前没有已建立的数据库连接", .english: "No database connection is established"],
        .errorNotImplemented: [.simplifiedChinese: "功能尚未实现：%@", .english: "Not implemented yet: %@"],
        .errorKeychain: [.simplifiedChinese: "凭据存储操作失败（错误码 %d）", .english: "Credential store error (code %d)"],
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
        .toolbarSaveFileHelp: [.simplifiedChinese: "保存到文件", .english: "Save to file"],
        .toolbarSaveAs: [.simplifiedChinese: "另存为…", .english: "Save As…"],
        .toolbarEditHelp: [.simplifiedChinese: "编辑", .english: "Edit"],
        .toolbarHelpHelp: [.simplifiedChinese: "快捷键与帮助", .english: "Shortcuts & help"],
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
        .helpShortcutsTitle: [.simplifiedChinese: "快捷键", .english: "Keyboard shortcuts"],
        .treeActionBrowseRows: [.simplifiedChinese: "浏览前 %d 行", .english: "Browse first %d rows"],
        .treeActionSelectTemplate: [.simplifiedChinese: "生成 SELECT 模板", .english: "Generate SELECT template"],
        .treeActionInsertTemplate: [.simplifiedChinese: "生成 INSERT 模板", .english: "Generate INSERT template"],
        .treeActionCopyQualifiedName: [.simplifiedChinese: "复制限定名", .english: "Copy qualified name"],
        .treeActionCopyColumnName: [.simplifiedChinese: "复制列名", .english: "Copy column name"],
        .treeActionViewDDL: [.simplifiedChinese: "查看建表 DDL", .english: "View CREATE TABLE DDL"],
        .treeActionTruncate: [.simplifiedChinese: "生成清空语句（TRUNCATE）", .english: "Generate TRUNCATE statement"],
        .treeActionDrop: [.simplifiedChinese: "生成删除语句（DROP）", .english: "Generate DROP statement"],
        .treeActionUnavailable: [.simplifiedChinese: "该操作需要先加载表结构，或对该节点不可用。", .english: "This action needs the table structure to be loaded, or does not apply to this node."],
        .objectTreeCopied: [.simplifiedChinese: "已复制：%@", .english: "Copied: %@"],
        .objectTreeOpenedInNewTab: [.simplifiedChinese: "已在新页签中生成语句（未执行）。", .english: "Statement generated in a new tab (not executed)."],
        .planTitle: [.simplifiedChinese: "执行计划", .english: "Execution plan"],
        .planRun: [.simplifiedChinese: "分析", .english: "Analyze"],
        .planAnalyze: [.simplifiedChinese: "执行 ANALYZE", .english: "Run ANALYZE"],
        .planAnalyzeWarning: [.simplifiedChinese: "⚠️ ANALYZE 会**真正执行**这条语句（含写操作），不只是查看计划。", .english: "⚠️ ANALYZE actually executes the statement (including writes), it does not just show the plan."],
        .planBuffers: [.simplifiedChinese: "含缓冲区统计 BUFFERS", .english: "Include BUFFERS"],
        .planFormatJSON: [.simplifiedChinese: "使用 JSON 格式", .english: "Use JSON format"],
        .planSummary: [.simplifiedChinese: "摘要", .english: "Summary"],
        .planTree: [.simplifiedChinese: "计划树", .english: "Plan tree"],
        .planRaw: [.simplifiedChinese: "原始输出", .english: "Raw output"],
        .planEmpty: [.simplifiedChinese: "还没有计划。点「分析」查看当前语句的执行计划。", .english: "No plan yet. Press Analyze to inspect the current statement."],
        .planUnsupported: [.simplifiedChinese: "当前语句不适合做执行计划（只支持 SELECT / INSERT / UPDATE / DELETE / WITH / VALUES / TABLE）。", .english: "This statement cannot be explained (only SELECT / INSERT / UPDATE / DELETE / WITH / VALUES / TABLE)."],
        .planMultipleStatements: [.simplifiedChinese: "编辑器里有 %d 条语句，只分析了第一条。", .english: "The editor has %d statements; only the first was analyzed."],
        .planFailed: [.simplifiedChinese: "获取执行计划失败：%@", .english: "Failed to get the execution plan: %@"],
        .toolbarPlanHelp: [.simplifiedChinese: "执行计划（EXPLAIN）", .english: "Execution plan (EXPLAIN)"],
        .planSequentialScan: [.simplifiedChinese: "全表扫描", .english: "Sequential scan"],
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

        // 数据任务（FR-AI-05 / FR-AI-06 / FR-AI-08）
        .menuDataTask: [.simplifiedChinese: "数据任务…", .english: "Data Tasks…"],
        .dataTaskTitle: [.simplifiedChinese: "数据任务", .english: "Data Tasks"],
        .dataTaskName: [.simplifiedChinese: "任务名", .english: "Task name"],
        .dataTaskNotExecutedHint: [.simplifiedChinese: "试运行与保存都不会执行任务；真正执行时会先提交审批（只读模式下会被拒）。", .english: "Neither a dry run nor saving executes the task. A real run is submitted for approval first (and is denied in read-only mode)."],
        .dataTaskRefresh: [.simplifiedChinese: "刷新", .english: "Refresh"],
        .dataTaskNew: [.simplifiedChinese: "新建任务", .english: "New Task"],
        .dataTaskRevert: [.simplifiedChinese: "放弃改动", .english: "Revert"],
        .dataTaskSave: [.simplifiedChinese: "保存任务", .english: "Save Task"],
        .dataTaskDelete: [.simplifiedChinese: "删除任务", .english: "Delete Task"],
        .dataTaskDeleteConfirmTitle: [.simplifiedChinese: "删除数据任务？", .english: "Delete this data task?"],
        .dataTaskDeleteConfirmMessage: [.simplifiedChinese: "将删除任务「%@」及其执行历史，该操作不可撤销。", .english: "This deletes the task “%@” and its run history. It cannot be undone."],
        .dataTaskDeleted: [.simplifiedChinese: "已删除任务「%@」", .english: "Deleted task “%@”"],
        .dataTaskDeleteFailed: [.simplifiedChinese: "删除任务失败：%@", .english: "Deleting the task failed: %@"],
        .dataTaskSaved: [.simplifiedChinese: "已保存任务「%@」", .english: "Saved task “%@”"],
        .dataTaskSaveFailed: [.simplifiedChinese: "保存任务失败：%@", .english: "Saving the task failed: %@"],
        .dataTaskLoadFailed: [.simplifiedChinese: "读取数据任务失败：%@", .english: "Loading data tasks failed: %@"],
        .dataTaskSearchPlaceholder: [.simplifiedChinese: "搜索任务（名称 / specs / 表名）", .english: "Search tasks (name, specs, table)"],
        .dataTaskOnlyEnabled: [.simplifiedChinese: "只看启用", .english: "Enabled only"],
        .dataTaskListEmpty: [.simplifiedChinese: "还没有数据任务。点「新建任务」把一段规格说明变成可执行任务。", .english: "No data tasks yet. Create one to turn a spec into an executable task."],
        .dataTaskNoSelection: [.simplifiedChinese: "从左侧选择一个任务，或新建一个。", .english: "Select a task on the left, or create one."],
        .dataTaskSelectHint: [.simplifiedChinese: "选中任务后可编辑定义、试运行预览并查看执行历史。", .english: "Pick a task to edit its definition, dry-run it and inspect run history."],
        .dataTaskEnabled: [.simplifiedChinese: "启用（停用后不再排期）", .english: "Enabled (a disabled task is never scheduled)"],
        .dataTaskEnable: [.simplifiedChinese: "恢复", .english: "Enable"],
        .dataTaskDisable: [.simplifiedChinese: "停用", .english: "Disable"],
        .dataTaskDisabledHint: [.simplifiedChinese: "该任务已停用：调度器不会为它排期，手动执行仍可用。", .english: "Disabled: the scheduler will not schedule it, but you can still run it manually."],
        .dataTaskSectionSpecs: [.simplifiedChinese: "规格说明（specs）", .english: "Specification (specs)"],
        .dataTaskSpecsHint: [.simplifiedChinese: "specs 与任务定义同时留存，都是可编辑文本；改完先试运行，再保存。", .english: "Both specs and the definition are kept as editable text. Dry-run before saving."],
        .dataTaskSectionSource: [.simplifiedChinese: "数据来源", .english: "Source"],
        .dataTaskSchema: [.simplifiedChinese: "模式（schema）", .english: "Schema"],
        .dataTaskTable: [.simplifiedChinese: "表名", .english: "Table"],
        .dataTaskSourceColumns: [.simplifiedChinese: "源列（逗号或换行分隔）", .english: "Columns (comma or newline separated)"],
        .dataTaskSourceColumnsHint: [.simplifiedChinese: "留空表示全部列（*）；留空时无法使用「丢弃列」转换。", .english: "Empty means all columns (*); “drop column” cannot be used in that case."],
        .dataTaskFilter: [.simplifiedChinese: "过滤条件（WHERE 之后）", .english: "Filter (after WHERE)"],
        .dataTaskFilterHint: [.simplifiedChinese: "只写片段，不要带 WHERE 关键字与分号。", .english: "Fragment only — no WHERE keyword, no semicolon."],
        .dataTaskSectionTransformations: [.simplifiedChinese: "转换", .english: "Transformations"],
        .dataTaskAddTransformation: [.simplifiedChinese: "添加转换", .english: "Add transformation"],
        .dataTaskRemoveTransformation: [.simplifiedChinese: "移除", .english: "Remove"],
        .dataTaskTransformationColumn: [.simplifiedChinese: "源列", .english: "Column"],
        .dataTaskTransformationTargetColumn: [.simplifiedChinese: "目标列", .english: "Target column"],
        .dataTaskTransformationExpression: [.simplifiedChinese: "表达式", .english: "Expression"],
        .dataTaskTransformEmpty: [.simplifiedChinese: "还没有转换步骤：源列会原样写入目标。", .english: "No transformations: source columns are written as-is."],
        .dataTaskSectionTarget: [.simplifiedChinese: "写入目标", .english: "Target"],
        .dataTaskTargetTable: [.simplifiedChinese: "目标表", .english: "Target table"],
        .dataTaskWriteMode: [.simplifiedChinese: "写入模式", .english: "Write mode"],
        .dataTaskKeyColumns: [.simplifiedChinese: "冲突键列", .english: "Conflict keys"],
        .dataTaskKeyColumnsHint: [.simplifiedChinese: "更新插入（upsert）必须指定，用逗号分隔。", .english: "Required for upsert; comma separated."],
        .dataTaskSectionSchedule: [.simplifiedChinese: "调度", .english: "Schedule"],
        .dataTaskScheduleKind: [.simplifiedChinese: "调度方式", .english: "Schedule type"],
        .dataTaskRunAt: [.simplifiedChinese: "执行时间", .english: "Run at"],
        .dataTaskIntervalSeconds: [.simplifiedChinese: "间隔（秒）", .english: "Interval (seconds)"],
        .dataTaskStartAt: [.simplifiedChinese: "首次执行时间", .english: "First run at"],
        .dataTaskDateHint: [.simplifiedChinese: "时间格式：yyyy-MM-dd HH:mm（留空表示未设置）", .english: "Time format: yyyy-MM-dd HH:mm (empty means unset)"],
        .dataTaskSectionExport: [.simplifiedChinese: "导出目录（需授权）", .english: "Export directory (authorized)"],
        .dataTaskExportFormat: [.simplifiedChinese: "产物格式", .english: "Artifact format"],
        .dataTaskFileNameTemplate: [.simplifiedChinese: "文件名模板", .english: "File name template"],
        .dataTaskFileNameHint: [.simplifiedChinese: "可用 {task} 与 {timestamp}；路径分隔符会被剥掉。", .english: "{task} and {timestamp} are available; path separators are stripped."],
        .dataTaskChooseDirectory: [.simplifiedChinese: "选择目录…", .english: "Choose directory…"],
        .dataTaskUseStoredDirectory: [.simplifiedChinese: "使用已授权目录", .english: "Use an authorized directory"],
        .dataTaskNoStoredDirectory: [.simplifiedChinese: "还没有已授权目录", .english: "No authorized directory yet"],
        .dataTaskDirectoryGranted: [.simplifiedChinese: "导出目录：%@", .english: "Export directory: %@"],
        .dataTaskDirectoryGrantedStale: [.simplifiedChinese: "导出目录：%@（授权书签已过期，建议重新选择一次）", .english: "Export directory: %@ (the bookmark is stale; please re-select it)"],
        .dataTaskDirectoryNotAuthorized: [.simplifiedChinese: "尚未授权导出目录。", .english: "No export directory authorized yet."],
        .dataTaskDirectoryMissing: [.simplifiedChinese: "授权目录已不存在：%@", .english: "The authorized directory no longer exists: %@"],
        .dataTaskDirectoryDenied: [.simplifiedChinese: "没有访问授权目录的权限：%@", .english: "No permission to access the authorized directory: %@"],
        .dataTaskDirectoryResolutionFailed: [.simplifiedChinese: "授权书签无法解析：%@", .english: "The bookmark cannot be resolved: %@"],
        .dataTaskDirectoryHintNotAuthorized: [.simplifiedChinese: "请选择一个目录并授权导出；也可以先不导出，只写库。", .english: "Choose a directory to authorize exports, or leave it unset and only write to the database."],
        .dataTaskDirectoryHintMissing: [.simplifiedChinese: "目录可能被移动或所在磁盘未挂载，请重新选择。", .english: "The directory may have moved or its volume is unmounted; please re-select."],
        .dataTaskDirectoryHintDenied: [.simplifiedChinese: "请在系统设置中授予文件访问权限，或改选其他目录。", .english: "Grant file access in System Settings, or choose another directory."],
        .dataTaskDirectoryHintResolutionFailed: [.simplifiedChinese: "请重新选择目录以生成新的授权书签。", .english: "Re-select the directory to create a fresh bookmark."],
        .dataTaskExportVerify: [.simplifiedChinese: "写入验证文件", .english: "Write a verification file"],
        .dataTaskExportVerifySucceeded: [.simplifiedChinese: "已写入验证文件：%@", .english: "Verification file written: %@"],
        .dataTaskSectionPreview: [.simplifiedChinese: "试运行与预览", .english: "Dry run & preview"],
        .dataTaskDryRun: [.simplifiedChinese: "试运行", .english: "Dry run"],
        .dataTaskDryRunHint: [.simplifiedChinese: "试运行只做预览：分步说明 + 预览语句（只取 10 行），绝不真正执行。", .english: "A dry run only previews: steps plus statements limited to 10 rows. Nothing is executed."],
        .dataTaskPreviewSteps: [.simplifiedChinese: "执行步骤", .english: "Steps"],
        .dataTaskPreviewSQL: [.simplifiedChinese: "预览语句", .english: "Preview statements"],
        .dataTaskPreviewWarnings: [.simplifiedChinese: "告警", .english: "Warnings"],
        .dataTaskPreviewIssues: [.simplifiedChinese: "问题（解决后才能保存）", .english: "Problems (fix before saving)"],
        .dataTaskNoIssues: [.simplifiedChinese: "定义校验通过。", .english: "The definition passes validation."],
        .dataTaskNeedDryRun: [.simplifiedChinese: "保存前必须先试运行一次。", .english: "Run a dry run before saving."],
        .dataTaskSaveBlocked: [.simplifiedChinese: "定义还有问题，保存已禁用。", .english: "The definition still has problems; saving is disabled."],
        .dataTaskWriteStatement: [.simplifiedChinese: "写入语句（真正执行时会先提交审批）", .english: "Write statement (submitted for approval before it runs)"],
        .dataTaskGuardVerdict: [.simplifiedChinese: "护栏判定", .english: "Guardrail verdict"],
        .dataTaskSectionRuntime: [.simplifiedChinese: "调度状态与执行", .english: "Schedule status & runs"],
        .dataTaskStatusNotScheduled: [.simplifiedChinese: "未排期", .english: "Not scheduled"],
        .dataTaskStatusDisabled: [.simplifiedChinese: "已停用", .english: "Disabled"],
        .dataTaskStatusWaiting: [.simplifiedChinese: "等待", .english: "Waiting"],
        .dataTaskStatusDue: [.simplifiedChinese: "到点", .english: "Due"],
        .dataTaskStatusMissed: [.simplifiedChinese: "错过", .english: "Missed"],
        .dataTaskNextRun: [.simplifiedChinese: "下次执行：%@", .english: "Next run: %@"],
        .dataTaskPlannedAt: [.simplifiedChinese: "计划时间：%@", .english: "Planned at: %@"],
        .dataTaskMissedNotice: [.simplifiedChinese: "晚了约 %d 分钟，请确认是否现在执行。", .english: "About %d minutes late — confirm whether to run it now."],
        .dataTaskRunNow: [.simplifiedChinese: "现在执行…", .english: "Run now…"],
        .dataTaskDueNotice: [.simplifiedChinese: "有数据任务已到点，正在按计划推进（写库前仍需批准）。", .english: "A data task is due and is being brought forward (it still needs approval before writing)."],
        .dataTaskRunPending: [.simplifiedChinese: "已提交审批：批准之后才会真正写库。", .english: "Submitted for approval; it writes only after you approve it."],
        .dataTaskRunDenied: [.simplifiedChinese: "安全护栏拒绝了这次执行：%@", .english: "The guardrail denied this run: %@"],
        .dataTaskRunSucceeded: [.simplifiedChinese: "执行完成：写入 %d 行，产物已导出到 %@", .english: "Run finished: %d row(s) written, artifact exported to %@"],
        .dataTaskRunSucceededNoArtifact: [.simplifiedChinese: "执行完成：写入 %d 行（该任务未配置导出目录）。", .english: "Run finished: %d row(s) written (no export directory configured)."],
        .dataTaskRunFailed: [.simplifiedChinese: "执行失败：%@", .english: "Run failed: %@"],
        .dataTaskRunArtifactFailed: [.simplifiedChinese: "写入已完成，但产物导出失败：%@", .english: "The write finished, but exporting the artifact failed: %@"],
        .dataTaskRunRejected: [.simplifiedChinese: "本次执行未获批准，没有写库。", .english: "This run was not approved, so nothing was written."],
        .dataTaskRunNotConnected: [.simplifiedChinese: "请先连接一个数据库再执行任务。", .english: "Connect to a database before running a task."],
        .dataTaskSectionHistory: [.simplifiedChinese: "执行历史", .english: "Run history"],
        .dataTaskHistoryEmpty: [.simplifiedChinese: "该任务还没有执行记录。", .english: "No runs recorded for this task yet."],
        .dataTaskHistoryCount: [.simplifiedChinese: "共 %d 条", .english: "%d run(s)"],
        .dataTaskHistoryColumnTime: [.simplifiedChinese: "时间", .english: "Time"],
        .dataTaskHistoryColumnStatus: [.simplifiedChinese: "状态", .english: "Status"],
        .dataTaskHistoryColumnRows: [.simplifiedChinese: "行数", .english: "Rows"],
        .dataTaskHistoryColumnDuration: [.simplifiedChinese: "耗时", .english: "Duration"],
        .dataTaskHistoryColumnMessage: [.simplifiedChinese: "消息", .english: "Message"],
        .dataTaskRunStatusRunning: [.simplifiedChinese: "执行中", .english: "Running"],
        .dataTaskRunStatusSucceeded: [.simplifiedChinese: "成功", .english: "Succeeded"],
        .dataTaskRunStatusFailed: [.simplifiedChinese: "失败", .english: "Failed"],
        .dataTaskRunStatusSkipped: [.simplifiedChinese: "已跳过", .english: "Skipped"],
        .dataTaskSpecOpen: [.simplifiedChinese: "由规格说明生成…", .english: "Generate from specs…"],
        .dataTaskSpecTitle: [.simplifiedChinese: "由规格说明生成任务定义", .english: "Generate a task definition from specs"],
        .dataTaskSpecInput: [.simplifiedChinese: "规格说明（自然语言）", .english: "Specification (natural language)"],
        .dataTaskSpecHints: [.simplifiedChinese: "额外约束（可选）", .english: "Extra constraints (optional)"],
        .dataTaskSpecPayload: [.simplifiedChinese: "将要外发给模型的内容", .english: "Content that will be sent to the model"],
        .dataTaskSpecGenerate: [.simplifiedChinese: "生成定义", .english: "Generate definition"],
        .dataTaskSpecApply: [.simplifiedChinese: "应用到编辑器", .english: "Apply to editor"],
        .dataTaskSpecFailed: [.simplifiedChinese: "生成失败：%@", .english: "Generation failed: %@"],
        .dataTaskSpecNotExecuted: [.simplifiedChinese: "生成结果只填进编辑器：不会保存，也不会执行。", .english: "The result only fills the editor: nothing is saved or executed."],
        .dataTaskSpecGenerated: [.simplifiedChinese: "已生成定义（请核对后再保存）。", .english: "Definition generated — review it before saving."],
        .dataTaskSpecDisabled: [.simplifiedChinese: "智能体总开关已关闭，不会外发任何内容。", .english: "The agent master switch is off; nothing will be sent."],
        .dataTaskSpecNoInput: [.simplifiedChinese: "请先填写规格说明。", .english: "Enter a specification first."],
        .dataTaskSpecHint: [.simplifiedChinese: "模型只给出定义草案，保存前仍要试运行预览。", .english: "The model only drafts a definition; still dry-run it before saving."],
        .dataTaskTransformKindRename: [.simplifiedChinese: "重命名", .english: "Rename"],
        .dataTaskTransformKindCast: [.simplifiedChinese: "类型转换", .english: "Cast"],
        .dataTaskTransformKindDerive: [.simplifiedChinese: "派生列", .english: "Derive column"],
        .dataTaskTransformKindDrop: [.simplifiedChinese: "丢弃列", .english: "Drop column"],
        .dataTaskTransformKindMask: [.simplifiedChinese: "脱敏", .english: "Mask"],
        .dataTaskWriteModeAppend: [.simplifiedChinese: "追加", .english: "Append"],
        .dataTaskWriteModeOverwrite: [.simplifiedChinese: "覆盖", .english: "Overwrite"],
        .dataTaskWriteModeUpsert: [.simplifiedChinese: "更新插入", .english: "Upsert"],
        .dataTaskScheduleKindManual: [.simplifiedChinese: "手动", .english: "Manual"],
        .dataTaskScheduleKindOnce: [.simplifiedChinese: "一次性", .english: "Once"],
        .dataTaskScheduleKindRecurring: [.simplifiedChinese: "周期", .english: "Recurring"],
        .dataTaskOverwriteWarning: [.simplifiedChinese: "覆盖模式会先清空目标表；真正执行时仍需逐次审批。", .english: "Overwrite truncates the target table first; the run still needs per-run approval."],
        .dataTaskUpsertWarning: [.simplifiedChinese: "更新插入会改写目标表里已存在的行。", .english: "Upsert rewrites rows that already exist in the target table."],
    ]
}
