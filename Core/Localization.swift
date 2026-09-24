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
    case tableDesignIndexes
    case tableDesignAddIndex
    case tableDesignIndexName
    case tableDesignIndexColumns
    case tableDesignIndexUnique
    case tableDesignIndexWhere
    case tableDesignNoIndexes
    case tableDesignConstraints
    case tableDesignAddConstraint
    case tableDesignAddForeignKey
    case tableDesignConstraintName
    case tableDesignConstraintDefinition
    case tableDesignForeignKeyColumns
    case tableDesignForeignKeyTable
    case tableDesignOnDelete
    case tableDesignOnUpdate
    case tableDesignNoConstraints
    case tableDesignPrimaryKeyKept
    case tableDesignWillDrop
    case tableDesignExtrasHint
    case referentialActionNone
    case referentialActionNoAction
    case referentialActionRestrict
    case referentialActionCascade
    case referentialActionSetNull
    case referentialActionSetDefault
    case constraintKindPrimaryKey
    case constraintKindUnique
    case constraintKindForeignKey
    case constraintKindCheck
    case constraintKindOther
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
    case lowerPaneProblemSkipped
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

    // 结果区：表头排序（FR-RES-08）
    case resultCopyAs
    case resultSortHelp
    case resultSortClear

    // 结果区：筛选条（FR-RES-09）
    case resultFilterAdd
    case resultFilterColumn
    case resultFilterValue
    case resultFilterRemove
    case resultFilterClear
    case resultFilterCaseSensitive
    case resultFilterClientOnlyNote
    case resultFilterGenerateWhere
    case resultFilterWhereInjected
    case resultFilterWhereAlreadyPresent
    case resultFilterWhereFailed

    // 结果区：筛选运算符
    case filterOpContains
    case filterOpNotContains
    case filterOpEquals
    case filterOpNotEquals
    case filterOpGreaterThan
    case filterOpGreaterThanOrEqual
    case filterOpLessThan
    case filterOpLessThanOrEqual
    case filterOpIsEmpty
    case filterOpIsNotEmpty

    // 结果区：分页条（FR-RES-10）
    case resultPageIndicator
    case resultPageSize
    case resultPageAll
    case resultPageFirst
    case resultPagePrevious
    case resultPageNext
    case resultPageLast

    // 按条件浏览 / 统计行数（FR-DATA-02）
    case browseSheetTitle
    case browseSheetServerSideNote
    case browseSheetWhere
    case browseSheetWherePlaceholder
    case browseSheetOrderBy
    case browseSheetOrderByPlaceholder
    case browseSheetLimit
    case browseSheetOffset
    case browseSheetPreview
    case browseSheetHint
    case browseSheetBrowse
    case browseSheetCount
    case browseSheetRefused
    case browseSheetBrowsing
    case browseSheetCounting

    // 查看 DDL（FR-META-13）
    case treeDDLUnsupported
    case treeDDLEmpty
    case treeDDLReady

    // 连接配置迁移（FR-CONN-10）
    case connectionEnvProduction
    case connectionEnvStaging
    case connectionEnvTesting
    case connectionEnvDevelopment
    case connectionEnvironmentLabel
    case connectionEnvironmentNone
    case connectionColorLabel
    case connectionColorNone
    case connectionProductionBadgeHelp
    case connectionMigrated
    case connectionNewerVersionKept

    // 事务模式（FR-EXEC-15）
    case commandNewQuery
    case commandExecute
    case commandStop
    case commandCheck
    case commandFormat
    case commandExecutionPlan
    case commandFind
    case commandReplace
    case commandGoToLine
    case commandExportCSV
    case commandExportJSON
    case commandBrowseRows
    case commandTableDDL
    case commandSessions
    case commandLocks
    case commandSwitchConnection
    case commandAgentSQL
    case commandSyntheticData
    case commandEgressLog
    case commandHelp
    case paletteCategoryQuery
    case paletteCategoryResult
    case paletteCategoryObject
    case paletteCategoryServer
    case paletteCategoryAgent
    case paletteCategoryHelp
    case commandGoToLineHint
    case commandPalettePlaceholder
    case commandPaletteNoMatch
    case commandPaletteHint
    // 全库对象搜索（FR-META-12 界面）
    case objectSearchTitle
    // 例行候选面板（FR-AI-14 的界面入口）
    case routineCandidatesTitle
    case routineCandidatesHint
    case routineCandidatesEmpty
    case routineCandidatesBlockedTitle
    case routineCandidatesVeto
    case routineCandidatesVetoed
    case routineCandidatesInsert
    case objectSearchPlaceholder
    case objectSearchHint
    case objectSearchNoMatch
    case objectSearchTruncated
    case objectSearchBrowse
    case objectSearchResultCount
    case objectSearchUnsupported
    case objectSearchKindTable
    case objectSearchKindView
    case objectSearchKindColumn
    case objectSearchKindFunction
    case objectSearchKindOther
    // 行详情侧栏（FR-DATA-05 界面）
    case rowDetailTitle
    case rowDetailNoSelection
    case rowDetailCopyValue
    // 命令面板需要"先选一个对象"时的提示
    case paletteNeedsTreeObject
    case queryParameterTitle
    case queryParameterHint
    case queryParameterName
    case queryParameterValue
    case queryParameterType
    case queryParameterRun
    case queryParameterMissing
    case queryParameterUnused
    case queryParameterEmpty
    case syntheticTitle
    case syntheticRows
    case syntheticSeed
    case syntheticColumns
    case syntheticPreview
    case syntheticGenerate
    case syntheticExport
    case syntheticWrite
    case syntheticWritePending
    case syntheticWriteDenied
    case syntheticWriteDone
    case syntheticExported
    case syntheticInsertFailed
    case syntheticSpecIssue
    case syntheticAutoSpecNote
    case syntheticOverwrite
    case sessionTitle
    case sessionRefresh
    case sessionPermissionNote
    case sessionLoading
    case sessionEmpty
    case sessionCount
    case sessionWaiting
    case sessionElapsed
    case sessionCancelStatement
    case sessionCancelStatementHelp
    case sessionTerminate
    case sessionTerminateHelp
    case sessionTerminateConfirmTitle
    case sessionTerminateConfirm
    case sessionTerminateConfirmMessage
    case sessionLoadFailed
    case sessionUnsupported
    case sessionSignalUnsupported
    case sessionSignalDenied
    case sessionTerminated
    case sessionStatementCancelled
    case transactionModeAuto
    case transactionModeManual
    case transactionCommit
    case transactionRollback
    case transactionOpenBadge
    case transactionAbortedBadge
    case transactionCommitted
    case transactionRolledBack
    case transactionBeginFailed
    case transactionRolledBackOnLeave
    case transactionRefusedNotManual
    case transactionRefusedNothing
    case transactionRefusedAborted
    case transactionRefusedOpen
    case transactionHelp

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
    case relaunchBlocked
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
    case egressFilterAll
    case egressFilterHint
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

    // 规格 / 定义的版本历史与回滚（FR-AI-11 的界面入口）
    case dataTaskVersionsOpen
    case dataTaskVersionsTitle
    case dataTaskVersionsHint
    case dataTaskVersionsEmpty
    case dataTaskVersionsColumnNumber
    case dataTaskVersionsColumnTime
    case dataTaskVersionsColumnNote
    case dataTaskVersionsColumnCurrent
    case dataTaskVersionsSameCurrent
    case dataTaskVersionsDifferentCurrent
    case dataTaskVersionsUnknownCurrent
    case dataTaskVersionsCompareTitle
    case dataTaskVersionsCompareLeft
    case dataTaskVersionsCompareRight
    case dataTaskVersionsDiffTitle
    case dataTaskVersionsDiffEmpty
    case dataTaskVersionsDiffCount
    case dataTaskVersionsDiffNoSelection
    case dataTaskVersionsRollback
    case dataTaskVersionsRollbackConfirmTitle
    case dataTaskVersionsRollbackConfirmMessage
    case dataTaskVersionsRolledBack
    case dataTaskVersionsRollbackNote
    case dataTaskVersionsRollbackFailed
    case dataTaskVersionsLoadFailed
    case dataTaskVersionsAppendOnlyNote
    case dataTaskVersionsNoSelection

    // 高危语句保护（FR-EXEC-16）
    case toolbarSafety
    case safetySafeMode
    case safetySafeModeHint
    case safetyConfirmAllWrites
    case safetyConfirmTitle
    case safetyConfirmMessage
    case safetyReadOnlyRefused
    case startupSQLFailed
    case backupRestoreTitle
    case backupRestoreHint
    case backupRestoreKindDump
    case backupRestoreKindDumpAll
    case backupRestoreKindRestore
    case backupRestoreFormat
    case backupRestoreArchive
    case backupRestoreChoose
    case backupRestoreTool
    case backupRestoreCheck
    case backupRestoreRun
    case backupRestoreCommandPreview
    case backupSandboxHint
    // 恢复到指定库（FR-IO-05 的界面入口）
    case backupRestoreTargetDatabase
    case backupRestoreTargetDatabaseHint
    case backupRestoreSection
    case backupRestoreSectionAll
    case backupRestoreSectionPreData
    case backupRestoreSectionData
    case backupRestoreSectionPostData
    case backupRestoreClean
    case backupRestoreJobsLabel
    case backupRestoreJobsLabelOff
    case backupRestoreRunRestore
    case backupRestoreSectionStarting
    case backupRestoreSectionsDone
    case backupRestoreSectionFailed
    case backupRestoreStopped
    case backupRestoreResumeLead
    case backupRestoreModeSectioned
    case backupRestoreFailedUnknownSection
    case backupRestoreLogCommand
    case backupRestoreLogReason
    case backupRestoreIncomplete
    case startupSQLRefused
    case connectionFormReadOnly
    case connectionFormReadOnlyHint
    case connectionFormStartupSQL
    case connectionFormGroup
    case connectionFormGroupExisting
    case connectionFormStartupSQLHint
    // 从连接 URL 导入（FR-CONN-19）
    case connectionFormURLImport
    case connectionFormURLPlaceholder
    case connectionFormURLImportAction
    case connectionFormURLImported
    case connectionFormURLIgnored
    case connectionFormURLFailed
    // 连接保活设置（FR-CONN-20）
    case connectionSettingsTitle
    case connectionSettingsKeepAliveSection
    case connectionSettingsKeepAliveToggle
    case connectionSettingsKeepAliveInterval
    case connectionSettingsKeepAliveLowerBound
    case connectionSettingsKeepAliveHint
    case connectionSettingsKeepAliveNever
    case connectionSettingsKeepAliveStatus
    case connectionSettingsKeepAliveUnhealthy
    case menuConnectionSettings
    // 数据库统计面板（FR-DIAG-04）
    case databaseStatsTitle
    case databaseStatsRefresh
    case databaseStatsTableSizes
    case databaseStatsIndexHit
    case databaseStatsConnections
    case databaseStatsCacheHit
    case databaseStatsCacheDetail
    case databaseStatsUnsupported
    case databaseStatsEmpty
    case databaseStatsEmptySection
    case databaseStatsNoScans
    case databaseStatsLoading
    case databaseStatsFailure
    // 终端偏好（FR-EDIT-29 的后续）
    case appearanceTerminalSection
    case terminalAppearanceFollowSystem
    case terminalAppearanceAlwaysDark
    case terminalAppearanceAlwaysLight
    case terminalFontSizeLabel
    case terminalFontSizeHint
    case terminalPreviewHint
    case terminalPreviewNormal
    case terminalPreviewBright
    case terminalPreviewDim
    case terminalPreviewSelection
    case terminalAppearanceHint
    // 服务器级对象管理面板（FR-SESS-03）
    case menuServerObjects
    case serverObjectsTitle
    case serverObjectsHint
    case serverObjectsRefresh
    case serverObjectsLoading
    case serverObjectsEmpty
    case serverObjectsKindRole
    case serverObjectsKindTablespace
    case serverObjectsKindExtension
    case serverObjectsUnsupported
    case serverObjectsApproximation
    case serverObjectsTablespaceReadOnly
    case serverObjectsCreateTitle
    case serverObjectsNamePlaceholder
    case serverObjectsPasswordPlaceholder
    case serverObjectsHostPlaceholder
    case serverObjectsSchemaPlaceholder
    case serverObjectsCanLogin
    case serverObjectsSuperuser
    case serverObjectsPreviewCreateRole
    case serverObjectsPreviewDropRole
    case serverObjectsPreviewCreateExtension
    case serverObjectsPreviewDropExtension
    case serverObjectsPreview
    case serverObjectsConfirm
    case serverObjectsDryRunHint
    case serverObjectsNoPreview
    case serverObjectsNoSelection
    case serverObjectsExecuted
    case serverObjectsRejected
    case serverObjectsFailure
    case serverObjectsRisk
    case serverObjectsRiskElevated
    case serverObjectsRiskDestructive
    case serverObjectsConfirmCreate
    case serverObjectsConfirmDestructive
    case serverObjectsWarnings
    // Schema 对比与同步面板（FR-DDL-04）
    case schemaDiffTitle
    case schemaDiffHint
    case schemaDiffSource
    case schemaDiffTarget
    case schemaDiffDatabase
    case schemaDiffSchema
    case schemaDiffAllowDrop
    case schemaDiffCompare
    case schemaDiffIdentical
    case schemaDiffMissingInTarget
    case schemaDiffExtraInTarget
    case schemaDiffChanged
    case schemaDiffSkipped
    case schemaDiffStatements
    case schemaDiffNoStatements
    case schemaDiffCopied
    case schemaDiffCopy
    case schemaDiffOpenInTab
    case schemaDiffFailed
    case schemaDiffPickConnections
    case schemaDiffLoading
    // 外键引用导航的界面入口（FR-DATA-06）
    case resultJumpToReferencedRow
    case fkJumpTitle
    case fkJumpSource
    case fkJumpPickTarget
    case fkJumpNoForeignKey
    case fkJumpUnknownTable
    case fkJumpNullValue
    case fkJumpStatus
    case fkJumpFailed
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
    case statePasswordSearched

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
    case treeActionBrowseWithCondition

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
    // 超大结果集：流式（游标逐页）导出（FR-RES-13）
    case exportStreamProgress
    case exportStreamSucceeded
    case exportStreamNoRows
    case exportStreamNotPossible
    case exportStreamReasonMultiStatement
    case exportStreamReasonNotQuery
    case exportStreamReasonManualTransaction
    // 结果集内联编辑（FR-DATA-04）
    case inlineEditNoSourceTable
    case inlineEditActive
    case inlineEditAppendRow
    case inlineEditDiscard
    case inlineEditPreview
    case inlineEditMarkDelete
    case inlineEditUnmarkDelete
    case inlineEditDeletedTag
    case inlineEditPendingCell
    case inlineEditPreviewTitle
    case inlineEditPreviewHint
    case inlineEditRefused
    case inlineEditCommit
    case inlineEditSucceeded
    case inlineEditRolledBack
    case inlineEditPlanFailed
    case inlineEditManualTransaction
    case inlineEditUnsupportedDialect
    case inlineEditDiscardedOnViewChange
    case inlineEditStatementCount
    case inlineEditDiscarded
    case inlineEditCellHint
    case inlineEditInsertTitle
    case inlineEditInsertHint
    case inlineEditInsertConfirm
    case inlineEditInsertEmpty
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

    // 记忆治理（FR-AI-15 的界面入口：例行候选面板里的「记忆」页签）
    case memoryGovernanceTabCandidates
    case memoryGovernanceTabMemory
    case memoryGovernanceHint
    case memoryGovernanceEmpty
    case memoryGovernanceArchiveDisabled
    case memoryGovernanceIndexNote
    case memoryGovernanceExplain
    case memoryGovernanceRetentionForget
    case memoryGovernanceRetentionKeep
    case memoryGovernanceKindLabel
    case memoryGovernanceDelete
    case memoryGovernanceDeleteConfirmTitle
    case memoryGovernanceDeleteConfirmMessage
    case memoryGovernanceDeleted
    case memoryGovernanceDeleteFailed
    case memoryGovernanceClearLayer
    case memoryGovernanceClearConfirmTitle
    case memoryGovernanceClearConfirmMessage
    case memoryGovernanceCleared
    case memoryGovernanceClearFailed
    case memoryGovernanceLayerNote
    case memoryGovernanceRecordingTitle
    case memoryGovernanceRecordingToggle
    case memoryGovernanceRecordingOn
    case memoryGovernanceRecordingOff
    case memoryGovernanceLoadFailed

    // CSV / TSV / JSON 导入（FR-IO-03 的整套界面）
    case menuImportData
    case importTitle
    case importHint
    case importFile
    case importChooseFile
    case importNoFile
    case importFormat
    case importHasHeader
    case importTargetTable
    case importTargetTableHint
    case importParse
    case importParseFailed
    case importReadFailed
    case importSourceSummary
    case importWarnings
    case importColumnMapping
    case importMappingMissing
    case importMappingUnknown
    case importMappingMissingRequired
    case importMappingEmpty
    case importPrecheckInvalid
    case importWriteMode
    case importWriteModeCopy
    case importWriteModeBatchInsert
    case importCopyStatement
    case importPreviewTitle
    case importPreviewEmpty
    case importExecute
    case importStop
    case importConfirmTitle
    case importConfirmMessage
    case importRunning
    case importProgress
    case importCopyStarted
    case importDone
    case importDoneCopy
    case importFailed
    case importPartial
    case importCancelled
    case importLog
    case importNeedsConnection
    case importNeedsParsedFile
    case importStructureFailed
    case importStructureEmpty
    case importNothingMapped
    case importSampleNote
    case importCopyAtomicNote
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
        .tableDesignIndexes: [.simplifiedChinese: "索引", .english: "Indexes"],
        .tableDesignAddIndex: [.simplifiedChinese: "加索引", .english: "Add index"],
        .tableDesignIndexName: [.simplifiedChinese: "索引名", .english: "Index name"],
        .tableDesignIndexColumns: [.simplifiedChinese: "列（逗号分隔）", .english: "Columns (comma separated)"],
        .tableDesignIndexUnique: [.simplifiedChinese: "唯一", .english: "Unique"],
        .tableDesignIndexWhere: [.simplifiedChinese: "条件（可选）", .english: "WHERE (optional)"],
        .tableDesignNoIndexes: [.simplifiedChinese: "没有读取到索引（或该库类型不支持读取）", .english: "No indexes were read (or this database type does not support reading them)"],
        .tableDesignConstraints: [.simplifiedChinese: "外键与约束", .english: "Foreign keys and constraints"],
        .tableDesignAddConstraint: [.simplifiedChinese: "加约束（UNIQUE / CHECK）", .english: "Add constraint (UNIQUE / CHECK)"],
        .tableDesignAddForeignKey: [.simplifiedChinese: "加外键", .english: "Add foreign key"],
        .tableDesignConstraintName: [.simplifiedChinese: "约束名", .english: "Constraint name"],
        .tableDesignConstraintDefinition: [.simplifiedChinese: "定义（如 UNIQUE (email) / CHECK (age > 0)）", .english: "Definition (e.g. UNIQUE (email) / CHECK (age > 0))"],
        .tableDesignForeignKeyColumns: [.simplifiedChinese: "本表列", .english: "Local columns"],
        .tableDesignForeignKeyTable: [.simplifiedChinese: "引用表", .english: "Referenced table"],
        .tableDesignOnDelete: [.simplifiedChinese: "删除时", .english: "On delete"],
        .tableDesignOnUpdate: [.simplifiedChinese: "更新时", .english: "On update"],
        .tableDesignNoConstraints: [.simplifiedChinese: "没有读取到约束（或该库类型不支持读取）", .english: "No constraints were read (or this database type does not support reading them)"],
        .tableDesignPrimaryKeyKept: [.simplifiedChinese: "主键不在此处删除（请用 SQL）", .english: "Primary keys are not dropped here (use SQL)"],
        .tableDesignWillDrop: [.simplifiedChinese: "将删除", .english: "will be dropped"],
        .tableDesignExtrasHint: [.simplifiedChinese: "索引与外键在改列之后创建；删除既有对象请在左侧取消勾选。留空的行提交时会被忽略", .english: "Indexes and foreign keys are created after column changes; uncheck an existing object to drop it. Empty rows are ignored on submit"],
        .referentialActionNone: [.simplifiedChinese: "不指定", .english: "Not specified"],
        .referentialActionNoAction: [.simplifiedChinese: "NO ACTION（不动作）", .english: "NO ACTION"],
        .referentialActionRestrict: [.simplifiedChinese: "RESTRICT（禁止）", .english: "RESTRICT"],
        .referentialActionCascade: [.simplifiedChinese: "CASCADE（级联）", .english: "CASCADE"],
        .referentialActionSetNull: [.simplifiedChinese: "SET NULL（置空）", .english: "SET NULL"],
        .referentialActionSetDefault: [.simplifiedChinese: "SET DEFAULT（置默认值）", .english: "SET DEFAULT"],
        .constraintKindPrimaryKey: [.simplifiedChinese: "主键", .english: "Primary key"],
        .constraintKindUnique: [.simplifiedChinese: "唯一", .english: "Unique"],
        .constraintKindForeignKey: [.simplifiedChinese: "外键", .english: "Foreign key"],
        .constraintKindCheck: [.simplifiedChinese: "检查", .english: "Check"],
        .constraintKindOther: [.simplifiedChinese: "其他", .english: "Other"],
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
        .lowerPaneProblemSkipped: [.simplifiedChinese: "SQL 超过 %@ 字符，已**暂停实时语法检查**（执行与语法高亮不受影响）", .english: "SQL is longer than %@ characters, so real-time syntax checking is paused (running and highlighting are unaffected)"],
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

        .resultCopyAs: [.simplifiedChinese: "复制为…", .english: "Copy As…"],
        .resultSortHelp: [.simplifiedChinese: "点击排序：升序 → 降序 → 取消；按住 Shift 点击可加为次要排序键", .english: "Click to sort: ascending → descending → off; Shift-click to add a secondary sort key"],
        .resultSortClear: [.simplifiedChinese: "清除排序", .english: "Clear Sort"],

        .resultFilterAdd: [.simplifiedChinese: "添加筛选", .english: "Add Filter"],
        .resultFilterColumn: [.simplifiedChinese: "列", .english: "Column"],
        .resultFilterValue: [.simplifiedChinese: "比较值", .english: "Value"],
        .resultFilterRemove: [.simplifiedChinese: "移除这条筛选", .english: "Remove this filter"],
        .resultFilterClear: [.simplifiedChinese: "清空筛选", .english: "Clear Filters"],
        .resultFilterCaseSensitive: [.simplifiedChinese: "区分大小写", .english: "Case sensitive"],
        .resultFilterClientOnlyNote: [.simplifiedChinese: "仅对已加载的 %d 行生效（客户端排序 / 筛选）", .english: "Applies to the %d loaded rows only (client-side sort/filter)"],
        .resultFilterGenerateWhere: [.simplifiedChinese: "用筛选条件生成 WHERE", .english: "Generate WHERE from filters"],
        .resultFilterWhereInjected: [.simplifiedChinese: "已在编辑器中插入 WHERE 条件 —— 请过目后再执行", .english: "WHERE clause inserted into the editor — review it before running"],
        .resultFilterWhereAlreadyPresent: [.simplifiedChinese: "编辑器中的查询已有 WHERE，未自动合并 —— 请把条件手动并进去", .english: "The query already has a WHERE clause; nothing was merged — add the condition manually"],
        .resultFilterWhereFailed: [.simplifiedChinese: "无法生成 WHERE：%@", .english: "Cannot generate WHERE: %@"],

        .filterOpContains: [.simplifiedChinese: "包含", .english: "contains"],
        .filterOpNotContains: [.simplifiedChinese: "不包含", .english: "does not contain"],
        .filterOpEquals: [.simplifiedChinese: "等于", .english: "equals"],
        .filterOpNotEquals: [.simplifiedChinese: "不等于", .english: "does not equal"],
        .filterOpGreaterThan: [.simplifiedChinese: "大于", .english: "greater than"],
        .filterOpGreaterThanOrEqual: [.simplifiedChinese: "大于等于", .english: "greater than or equal"],
        .filterOpLessThan: [.simplifiedChinese: "小于", .english: "less than"],
        .filterOpLessThanOrEqual: [.simplifiedChinese: "小于等于", .english: "less than or equal"],
        .filterOpIsEmpty: [.simplifiedChinese: "为空", .english: "is empty"],
        .filterOpIsNotEmpty: [.simplifiedChinese: "非空", .english: "is not empty"],

        .resultPageIndicator: [.simplifiedChinese: "第 %d / %d 页 · 共 %d 行", .english: "Page %d / %d · %d rows"],
        .resultPageSize: [.simplifiedChinese: "每页", .english: "Rows per page"],
        .resultPageAll: [.simplifiedChinese: "全部", .english: "All"],
        .resultPageFirst: [.simplifiedChinese: "第一页", .english: "First page"],
        .resultPagePrevious: [.simplifiedChinese: "上一页", .english: "Previous page"],
        .resultPageNext: [.simplifiedChinese: "下一页", .english: "Next page"],
        .resultPageLast: [.simplifiedChinese: "最后一页", .english: "Last page"],

        .browseSheetTitle: [.simplifiedChinese: "按条件浏览：%@", .english: "Browse with a condition: %@"],
        .browseSheetServerSideNote: [.simplifiedChinese: "这里的条件会**发给数据库**执行（与结果区里的客户端筛选不同 —— 那个只在已取回的行上生效）", .english: "These conditions are sent to the database (unlike the client-side filter in the result area, which only applies to rows already fetched)"],
        .browseSheetWhere: [.simplifiedChinese: "WHERE 条件", .english: "WHERE condition"],
        .browseSheetWherePlaceholder: [.simplifiedChinese: "如：status = 'active' AND created_at > now() - interval '7 days'", .english: "e.g. status = 'active' AND created_at > now() - interval '7 days'"],
        .browseSheetOrderBy: [.simplifiedChinese: "ORDER BY（可留空）", .english: "ORDER BY (optional)"],
        .browseSheetOrderByPlaceholder: [.simplifiedChinese: "如：created_at DESC", .english: "e.g. created_at DESC"],
        .browseSheetLimit: [.simplifiedChinese: "行数", .english: "Rows"],
        .browseSheetOffset: [.simplifiedChinese: "偏移", .english: "Offset"],
        .browseSheetPreview: [.simplifiedChinese: "将要执行的语句", .english: "Statement to run"],
        .browseSheetHint: [.simplifiedChinese: "写 `WHERE` / `ORDER BY` 关键字也可以；语句只允许一条（出现分号会被拒绝）", .english: "You may include the WHERE / ORDER BY keywords; only one statement is allowed (a semicolon is refused)"],
        .browseSheetBrowse: [.simplifiedChinese: "浏览", .english: "Browse"],
        .browseSheetCount: [.simplifiedChinese: "统计行数", .english: "Count rows"],
        .browseSheetRefused: [.simplifiedChinese: "条件无法生成语句（%@）：请写成单条表达式，并把 ORDER BY 填到它自己的框里", .english: "The condition cannot be turned into a statement (%@): write a single expression and put ORDER BY in its own field"],
        .browseSheetBrowsing: [.simplifiedChinese: "正在按条件浏览…", .english: "Browsing with the condition…"],
        .browseSheetCounting: [.simplifiedChinese: "正在统计行数…", .english: "Counting rows…"],

        .treeDDLUnsupported: [.simplifiedChinese: "该数据库类型暂不支持查看此对象的 DDL", .english: "Viewing DDL for this object is not supported on this database type"],
        .treeDDLEmpty: [.simplifiedChinese: "没有取到 %@ 的 DDL —— 可能是权限不足（元数据函数对无权限对象返回空）", .english: "No DDL was returned for %@ — this usually means insufficient privileges (metadata functions return empty for objects you cannot see)"],
        .treeDDLReady: [.simplifiedChinese: "已把 %@ 的 DDL 放进新页签（未执行）", .english: "DDL for %@ was opened in a new tab (not executed)"],

        .connectionEnvProduction: [.simplifiedChinese: "生产", .english: "Production"],
        .connectionEnvStaging: [.simplifiedChinese: "预发", .english: "Staging"],
        .connectionEnvTesting: [.simplifiedChinese: "测试", .english: "Testing"],
        .connectionEnvDevelopment: [.simplifiedChinese: "开发", .english: "Development"],
        .connectionEnvironmentLabel: [.simplifiedChinese: "环境标签", .english: "Environment"],
        .connectionEnvironmentNone: [.simplifiedChinese: "未标记", .english: "Not tagged"],
        .connectionColorLabel: [.simplifiedChinese: "颜色", .english: "Color"],
        .connectionColorNone: [.simplifiedChinese: "跟随环境标签", .english: "Follow environment"],
        .connectionProductionBadgeHelp: [.simplifiedChinese: "这是生产连接：高危语句（DROP / TRUNCATE / 无 WHERE 的 UPDATE、DELETE）在执行前一定会要求确认，Safe Mode 总开关关掉也如此", .english: "This is a production connection: high-risk statements always ask for confirmation, even with Safe Mode off"],
        .connectionMigrated: [.simplifiedChinese: "已把 %d 条连接配置升级到当前格式", .english: "Upgraded %d connection profiles to the current format"],
        .connectionNewerVersionKept: [.simplifiedChinese: "有连接配置来自更新的版本（schemaVersion %@）：已原样保留，未改写。请升级应用后再编辑，否则新字段可能在保存时丢失", .english: "Some connection profiles come from a newer version (schemaVersion %@). They were kept as-is and not rewritten; upgrade the app before editing, or newer fields may be lost on save"],

        .commandNewQuery: [.simplifiedChinese: "新建查询", .english: "New Query"],
        .commandExecute: [.simplifiedChinese: "执行", .english: "Execute"],
        .commandStop: [.simplifiedChinese: "停止", .english: "Stop"],
        .commandCheck: [.simplifiedChinese: "语法检查", .english: "Check Syntax"],
        .commandFormat: [.simplifiedChinese: "格式化 SQL", .english: "Format SQL"],
        .commandExecutionPlan: [.simplifiedChinese: "执行计划", .english: "Execution Plan"],
        .commandFind: [.simplifiedChinese: "查找", .english: "Find"],
        .commandReplace: [.simplifiedChinese: "替换", .english: "Replace"],
        .commandGoToLine: [.simplifiedChinese: "跳到行", .english: "Go to Line"],
        .commandExportCSV: [.simplifiedChinese: "导出 CSV", .english: "Export CSV"],
        .commandExportJSON: [.simplifiedChinese: "导出 JSON", .english: "Export JSON"],
        .commandBrowseRows: [.simplifiedChinese: "浏览前若干行", .english: "Browse Rows"],
        .commandTableDDL: [.simplifiedChinese: "查看 DDL", .english: "View DDL"],
        .commandSessions: [.simplifiedChinese: "服务器会话", .english: "Server Sessions"],
        .commandLocks: [.simplifiedChinese: "锁与阻塞", .english: "Locks"],
        .commandSwitchConnection: [.simplifiedChinese: "切换连接", .english: "Switch Connection"],
        .commandAgentSQL: [.simplifiedChinese: "用自然语言生成 SQL", .english: "Generate SQL from Natural Language"],
        .commandSyntheticData: [.simplifiedChinese: "生成测试数据", .english: "Generate Test Data"],
        .commandEgressLog: [.simplifiedChinese: "外发日志", .english: "Egress Log"],
        .commandHelp: [.simplifiedChinese: "帮助与快捷键", .english: "Help & Shortcuts"],
        .paletteCategoryQuery: [.simplifiedChinese: "查询", .english: "Query"],
        .paletteCategoryResult: [.simplifiedChinese: "结果", .english: "Result"],
        .paletteCategoryObject: [.simplifiedChinese: "对象", .english: "Object"],
        .paletteCategoryServer: [.simplifiedChinese: "服务器", .english: "Server"],
        .paletteCategoryAgent: [.simplifiedChinese: "智能体", .english: "Agent"],
        .paletteCategoryHelp: [.simplifiedChinese: "帮助", .english: "Help"],
        .commandGoToLineHint: [.simplifiedChinese: "跳转到行请用 %@（面板里没有行号输入框）", .english: "Use %@ to jump to a line (the palette has no line-number field)"],
        .commandPalettePlaceholder: [.simplifiedChinese: "输入命令名…（支持首字母缩写与中文）", .english: "Type a command…(acronyms and Chinese work)"],
        .commandPaletteNoMatch: [.simplifiedChinese: "没有匹配的命令", .english: "No matching command"],
        .commandPaletteHint: [.simplifiedChinese: "↑↓ 选择 · ↩ 执行 · esc 关闭", .english: "↑↓ select · ↩ run · esc close"],
        .routineCandidatesTitle: [.simplifiedChinese: "例行候选", .english: "Routine candidates"],
        .routineCandidatesHint: [.simplifiedChinese: "从查询归档里看「你反复在做什么」。**四条判据全满足**才列进候选：跨天频次、跨越天数、时刻集中度、只改参数 —— 这里**只给建议，不会自动建任务**", .english: "What you keep doing, derived from your query archive. A candidate needs all four: frequency, day span, time-of-day concentration, and parameter-only variation. Suggestions only — nothing is scheduled automatically"],
        .routineCandidatesEmpty: [.simplifiedChinese: "还没有符合四条判据的候选。下面列出「差在哪」，比只给一个空列表有用", .english: "No candidate meets all four criteria yet — below is what is missing"],
        .routineCandidatesBlockedTitle: [.simplifiedChinese: "未达标（差在哪）", .english: "Not yet (what is missing)"],
        .routineCandidatesVeto: [.simplifiedChinese: "不再建议", .english: "Never suggest"],
        .routineCandidatesVetoed: [.simplifiedChinese: "已否决", .english: "Vetoed"],
        .routineCandidatesInsert: [.simplifiedChinese: "插入编辑器", .english: "Insert into editor"],
        .objectSearchTitle: [.simplifiedChinese: "全库对象搜索", .english: "Search objects"],
        .objectSearchPlaceholder: [.simplifiedChinese: "输入名称片段（表 / 视图 / 列 / 函数）…", .english: "Type a name fragment (table / view / column / function)…"],
        .objectSearchHint: [.simplifiedChinese: "跨 schema 匹配表 / 视图 / 列 / 函数；**空输入不列结果**（全库对象上万条，列前几条只会误导）", .english: "Matches tables / views / columns / functions across schemas; an empty query lists nothing (thousands of objects would only mislead)"],
        .objectSearchNoMatch: [.simplifiedChinese: "没有匹配的对象", .english: "No matching object"],
        .objectSearchTruncated: [.simplifiedChinese: "元数据已达 10,000 行上限，结果**可能不完整** —— 用 schema 缩小范围再搜", .english: "Metadata hit the 10,000-row cap; results may be incomplete — narrow by schema and search again"],
        .objectSearchResultCount: [.simplifiedChinese: "在 %@ 个对象里搜到 %@ 条", .english: "Matched %@ of %@ objects"],
        .objectSearchUnsupported: [.simplifiedChinese: "%@ 方言暂不支持全库对象搜索（它吃的是 PostgreSQL 的系统目录）", .english: "Object search is not supported on %@ (it reads PostgreSQL system catalogs)"],
        .objectSearchBrowse: [.simplifiedChinese: "浏览数据", .english: "Browse data"],
        .objectSearchKindTable: [.simplifiedChinese: "表", .english: "Table"],
        .objectSearchKindView: [.simplifiedChinese: "视图", .english: "View"],
        .objectSearchKindColumn: [.simplifiedChinese: "列", .english: "Column"],
        .objectSearchKindFunction: [.simplifiedChinese: "函数", .english: "Function"],
        .objectSearchKindOther: [.simplifiedChinese: "其他", .english: "Other"],
        .rowDetailTitle: [.simplifiedChinese: "行详情", .english: "Row detail"],
        .rowDetailNoSelection: [.simplifiedChinese: "在上方结果里选中一行，这里按**列顺序竖排**显示全部字段", .english: "Select a row above to see every field listed vertically"],
        .rowDetailCopyValue: [.simplifiedChinese: "复制值", .english: "Copy value"],
        .paletteNeedsTreeObject: [.simplifiedChinese: "这条命令需要先选中一个表 / 视图：请在左侧对象树里点选后再试", .english: "This command needs a selected table or view — pick one in the object tree first"],
        .queryParameterTitle: [.simplifiedChinese: "填参数后执行", .english: "Fill parameters, then run"],
        .queryParameterHint: [.simplifiedChinese: "值会做**类型化转义**（文本自动加引号并转义单引号，数字不加引号，避免索引失效）；**编辑器里的占位符不会被改写**", .english: "Values are escaped by type (text is quoted and single quotes doubled; numbers stay unquoted so indexes still apply); the placeholders in the editor are left untouched"],
        .queryParameterName: [.simplifiedChinese: "参数", .english: "Parameter"],
        .queryParameterValue: [.simplifiedChinese: "值", .english: "Value"],
        .queryParameterType: [.simplifiedChinese: "类型", .english: "Type"],
        .queryParameterRun: [.simplifiedChinese: "绑定并执行", .english: "Bind and run"],
        .queryParameterMissing: [.simplifiedChinese: "还有参数没填", .english: "Some parameters are still empty"],
        .queryParameterUnused: [.simplifiedChinese: "这些参数没有在语句里用到：%@", .english: "These parameters were not used in the statement: %@"],
        .queryParameterEmpty: [.simplifiedChinese: "该语句没有参数", .english: "This statement has no parameters"],
        .syntheticTitle: [.simplifiedChinese: "生成测试数据：%@", .english: "Generate test data: %@"],
        .syntheticRows: [.simplifiedChinese: "行数", .english: "Rows"],
        .syntheticSeed: [.simplifiedChinese: "随机种子", .english: "Seed"],
        .syntheticColumns: [.simplifiedChinese: "列与生成规则", .english: "Columns and rules"],
        .syntheticPreview: [.simplifiedChinese: "预览（前几行）", .english: "Preview (first rows)"],
        .syntheticGenerate: [.simplifiedChinese: "生成预览", .english: "Generate preview"],
        .syntheticExport: [.simplifiedChinese: "导出 INSERT 到编辑器", .english: "Export INSERT to editor"],
        .syntheticWrite: [.simplifiedChinese: "写入目标表…", .english: "Write to table…"],
        .syntheticWritePending: [.simplifiedChinese: "已提交审批：请在审批单上批准后才会写入（关掉审批单不等于批准）", .english: "Submitted for approval: nothing is written until you approve it on the sheet (closing the sheet is not approval)"],
        .syntheticWriteDenied: [.simplifiedChinese: "写入被拒绝：%@", .english: "Write refused: %@"],
        .syntheticWriteDone: [.simplifiedChinese: "写入完成：影响 %d 行", .english: "Written: %d rows affected"],
        .syntheticExported: [.simplifiedChinese: "已把 INSERT 语句放进新页签（未执行）", .english: "INSERT statements were opened in a new tab (not executed)"],
        .syntheticInsertFailed: [.simplifiedChinese: "生成 INSERT 语句失败（检查列与行数）", .english: "Could not build INSERT statements (check columns and row count)"],
        .syntheticSpecIssue: [.simplifiedChinese: "规格问题：%@", .english: "Spec issue: %@"],
        .syntheticAutoSpecNote: [.simplifiedChinese: "规则按表结构自动推断：主键用序列、非空列不给 NULL —— 生成的数据应当能直接插入", .english: "Rules are inferred from the table: primary keys use a sequence and NOT NULL columns never get NULL, so the rows should insert cleanly"],
        .syntheticOverwrite: [.simplifiedChinese: "先清空目标表（TRUNCATE）", .english: "Truncate the target table first"],
        .sessionTitle: [.simplifiedChinese: "服务器会话", .english: "Server Sessions"],
        .sessionRefresh: [.simplifiedChinese: "刷新", .english: "Refresh"],
        .sessionPermissionNote: [.simplifiedChinese: "普通用户只能操作自己的会话（PostgreSQL 需同用户或 pg_signal_backend 权限）；「终止会话」会掐断整条连接，不可恢复", .english: "You can only act on your own sessions (PostgreSQL requires the same user or pg_signal_backend); terminating drops the whole connection and cannot be undone"],
        .sessionLoading: [.simplifiedChinese: "正在读取会话列表…", .english: "Loading sessions…"],
        .sessionEmpty: [.simplifiedChinese: "没有读到会话（或该数据库类型不支持读取）", .english: "No sessions were read (or this database type does not support it)"],
        .sessionCount: [.simplifiedChinese: "共 %d 个会话", .english: "%d sessions"],
        .sessionWaiting: [.simplifiedChinese: "等待中", .english: "waiting"],
        .sessionElapsed: [.simplifiedChinese: "已运行 %d 秒", .english: "running %ds"],
        .sessionCancelStatement: [.simplifiedChinese: "取消当前语句", .english: "Cancel statement"],
        .sessionCancelStatementHelp: [.simplifiedChinese: "中断这条会话上正在执行的语句，连接保留", .english: "Interrupt the running statement on this session; the connection stays"],
        .sessionTerminate: [.simplifiedChinese: "终止会话…", .english: "Terminate session…"],
        .sessionTerminateHelp: [.simplifiedChinese: "掐断整条连接（不可恢复，需确认）", .english: "Drop the whole connection (irreversible, needs confirmation)"],
        .sessionTerminateConfirmTitle: [.simplifiedChinese: "终止会话 %d？", .english: "Terminate session %d?"],
        .sessionTerminateConfirm: [.simplifiedChinese: "终止会话", .english: "Terminate"],
        .sessionTerminateConfirmMessage: [.simplifiedChinese: "用户 %@ 在库 %@ 上的连接会被立刻掐断，未提交的事务会回滚。", .english: "The connection for user %@ on database %@ will be dropped immediately; uncommitted work will roll back."],
        .sessionLoadFailed: [.simplifiedChinese: "读取会话失败：%@", .english: "Could not load sessions: %@"],
        .sessionUnsupported: [.simplifiedChinese: "该数据库类型暂不支持读取服务器会话", .english: "Reading server sessions is not supported on this database type"],
        .sessionSignalUnsupported: [.simplifiedChinese: "该数据库类型暂不支持取消 / 终止会话", .english: "Cancelling or terminating sessions is not supported on this database type"],
        .sessionSignalDenied: [.simplifiedChinese: "服务端拒绝了这次操作（会话 %d）—— 通常是权限不足：只能操作自己的会话", .english: "The server refused this operation (session %d) — usually insufficient privileges: you can only act on your own sessions"],
        .sessionTerminated: [.simplifiedChinese: "已终止会话 %d", .english: "Session %d terminated"],
        .sessionStatementCancelled: [.simplifiedChinese: "已取消会话 %d 上的语句", .english: "Statement on session %d cancelled"],
        .transactionModeAuto: [.simplifiedChinese: "自动提交", .english: "Auto-commit"],
        .transactionModeManual: [.simplifiedChinese: "手工事务", .english: "Manual transaction"],
        .transactionCommit: [.simplifiedChinese: "提交", .english: "Commit"],
        .transactionRollback: [.simplifiedChinese: "回滚", .english: "Roll back"],
        .transactionOpenBadge: [.simplifiedChinese: "事务进行中 · 已执行 %d 条", .english: "Transaction open · %d statements"],
        .transactionAbortedBadge: [.simplifiedChinese: "事务已失败 —— 只能回滚", .english: "Transaction failed — roll back only"],
        .transactionCommitted: [.simplifiedChinese: "事务已提交", .english: "Transaction committed"],
        .transactionRolledBack: [.simplifiedChinese: "事务已回滚", .english: "Transaction rolled back"],
        .transactionBeginFailed: [.simplifiedChinese: "事务开启失败：%@", .english: "Could not begin transaction: %@"],
        .transactionRolledBackOnLeave: [.simplifiedChinese: "连接或数据库已切换：未提交的事务已回滚", .english: "Connection or database changed: the uncommitted transaction was rolled back"],
        .transactionRefusedNotManual: [.simplifiedChinese: "当前是自动提交模式，没有事务可提交或回滚", .english: "Auto-commit is on; there is no transaction to commit or roll back"],
        .transactionRefusedNothing: [.simplifiedChinese: "没有进行中的事务", .english: "No transaction in progress"],
        .transactionRefusedAborted: [.simplifiedChinese: "事务已失败，请先回滚", .english: "The transaction failed; roll it back first"],
        .transactionRefusedOpen: [.simplifiedChinese: "有进行中的事务，请先提交或回滚，再切回自动提交", .english: "Commit or roll back the open transaction before switching back to auto-commit"],
        .transactionHelp: [.simplifiedChinese: "事务属于当前连接：同一连接下的所有页签共用它；切换连接或数据库会回滚未提交的事务", .english: "A transaction belongs to the connection: every tab on it shares it; switching connection or database rolls back uncommitted work"],

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
        .relaunchBlocked: [.simplifiedChinese: "还有未保存的查询，已取消重启 —— 请先保存再换语言。", .english: "There are unsaved queries, so the restart was cancelled — save them first, then switch language."],        .browserRestoredTitle: [.simplifiedChinese: "已恢复的页签（尚未加载）", .english: "Restored tab (not loaded yet)"],
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
        .egressFilterAll: [.simplifiedChinese: "全部", .english: "All"],
        .egressFilterHint: [.simplifiedChinese: "（已筛选）", .english: "(filtered)"],        .egressSubtitle: [.simplifiedChinese: "本机所有出网请求都会记在这里（智能体模型调用、内嵌浏览器、外部程序、更新检查）。默认零外发的承诺，靠它可查、可导出、可清空。", .english: "Every outbound request from this machine is recorded here (agent model calls, embedded browser, external tools, update checks). This is what makes the zero-egress promise verifiable."],
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
        .connectionFormGroup: [.simplifiedChinese: "分组 / 文件夹（可留空）", .english: "Group / folder (optional)"],
        .connectionFormGroupExisting: [.simplifiedChinese: "已有分组：%@", .english: "Existing groups: %@"],
        .connectionFormURLImport: [.simplifiedChinese: "从连接 URL 导入（postgres://…）", .english: "Import from a connection URL (postgres://…)"],
        .connectionFormURLPlaceholder: [.simplifiedChinese: "粘贴 postgres://user:pass@host:5432/dbname?sslmode=require", .english: "Paste postgres://user:pass@host:5432/dbname?sslmode=require"],
        .connectionFormURLImportAction: [.simplifiedChinese: "导入并填充表单", .english: "Import and fill in"],
        .connectionFormURLImported: [.simplifiedChinese: "已按 URL 填充：%@（密码已填入，保存后写入凭据）", .english: "Filled from URL: %@ (password filled in; stored when you save)"],
        .connectionFormURLIgnored: [.simplifiedChinese: "已忽略不支持的参数：%@", .english: "Ignored unsupported parameters: %@"],
        .connectionFormURLFailed: [.simplifiedChinese: "URL 解析失败：%@", .english: "Could not parse the URL: %@"],
        .connectionSettingsTitle: [.simplifiedChinese: "连接设置", .english: "Connection settings"],
        .connectionSettingsKeepAliveSection: [.simplifiedChinese: "连接保活", .english: "Keep-alive"],
        .connectionSettingsKeepAliveToggle: [.simplifiedChinese: "空闲时发送心跳（只有确实空闲够久才发，正在用的连接不打扰）", .english: "Send a heartbeat when idle (only when genuinely idle — connections in use are left alone)"],
        .connectionSettingsKeepAliveInterval: [.simplifiedChinese: "间隔：%d 秒", .english: "Interval: %d s"],
        .connectionSettingsKeepAliveLowerBound: [.simplifiedChinese: "下限 5 秒 —— 再密就不是保活，而是刷屏", .english: "Minimum 5 s — anything tighter is spam, not keep-alive"],
        .connectionSettingsKeepAliveHint: [.simplifiedChinese: "心跳是 `SELECT 1`（只读、无副作用）；失败只如实记录，**不会**据此断开连接", .english: "The heartbeat is `SELECT 1` (read-only, no side effects); a failure is recorded and never used to drop the connection"],
        .connectionSettingsKeepAliveNever: [.simplifiedChinese: "本次运行还没有发过心跳", .english: "No heartbeat sent in this run yet"],
        .connectionSettingsKeepAliveStatus: [.simplifiedChinese: "本次运行：成功 %d 次 / 失败 %d 次", .english: "This run: %d succeeded / %d failed"],
        .connectionSettingsKeepAliveUnhealthy: [.simplifiedChinese: "最近一次心跳失败：%@", .english: "Last heartbeat failed: %@"],
        .menuConnectionSettings: [.simplifiedChinese: "连接设置…", .english: "Connection Settings…"],
        .databaseStatsTitle: [.simplifiedChinese: "数据库统计", .english: "Database statistics"],
        .databaseStatsRefresh: [.simplifiedChinese: "刷新", .english: "Refresh"],
        .databaseStatsTableSizes: [.simplifiedChinese: "表大小（降序，前 20）", .english: "Table sizes (largest 20)"],
        .databaseStatsIndexHit: [.simplifiedChinese: "索引命中（按扫描，前 20）", .english: "Index usage (by scans, top 20)"],
        .databaseStatsConnections: [.simplifiedChinese: "连接状态", .english: "Connections by state"],
        .databaseStatsCacheHit: [.simplifiedChinese: "缓存命中", .english: "Cache hit rate"],
        .databaseStatsCacheDetail: [.simplifiedChinese: "命中 %lld / 读取 %lld", .english: "%lld hits / %lld reads"],
        .databaseStatsUnsupported: [.simplifiedChinese: "%@ 方言暂不支持数据库统计", .english: "Database statistics are not supported for the %@ dialect"],
        .databaseStatsEmpty: [.simplifiedChinese: "还没有采集到任何指标", .english: "No metrics collected yet"],
        .databaseStatsEmptySection: [.simplifiedChinese: "暂无数据（可能是权限不足，或该库/该指标没有内容）", .english: "No data (insufficient privileges, or nothing to report for this database/metric)"],
        .databaseStatsNoScans: [.simplifiedChinese: "无扫描数据", .english: "No scan data"],
        .databaseStatsLoading: [.simplifiedChinese: "正在采集…", .english: "Collecting…"],
        .databaseStatsFailure: [.simplifiedChinese: "统计失败：%@", .english: "Could not collect statistics: %@"],
        .appearanceTerminalSection: [.simplifiedChinese: "终端", .english: "Terminal"],
        .terminalAppearanceFollowSystem: [.simplifiedChinese: "跟随系统", .english: "Follow system"],
        .terminalAppearanceAlwaysDark: [.simplifiedChinese: "总是深色", .english: "Always dark"],
        .terminalAppearanceAlwaysLight: [.simplifiedChinese: "总是浅色", .english: "Always light"],
        .terminalFontSizeLabel: [.simplifiedChinese: "终端字号：%d pt", .english: "Terminal font size: %d pt"],
        .terminalFontSizeHint: [.simplifiedChinese: "字号独立于界面设置；改动会重建字符网格，并让 shell 按新列数重新分栏。", .english: "Independent of the UI font size. Changing it rebuilds the character grid and tells the shell to re-wrap at the new column count."],
        .terminalPreviewHint: [.simplifiedChinese: "预览（真实色板，随上面的选择立即变化）", .english: "Preview (the real palette — updates as you choose)"],
        .terminalPreviewNormal: [.simplifiedChinese: "常规色", .english: "Normal"],
        .terminalPreviewBright: [.simplifiedChinese: "亮色", .english: "Bright"],
        .terminalPreviewDim: [.simplifiedChinese: "暗淡", .english: "Dim"],
        .terminalPreviewSelection: [.simplifiedChinese: "选中", .english: "Selected"],
        .terminalAppearanceHint: [.simplifiedChinese: "终端可以独立于界面外观：浅色界面里配深色终端是常见偏好。", .english: "The terminal can differ from the app appearance — a dark terminal inside a light UI is a common preference."],
        .menuServerObjects: [.simplifiedChinese: "服务器级对象…", .english: "Server-level Objects…"],
        .serverObjectsTitle: [.simplifiedChinese: "服务器级对象", .english: "Server-level objects"],
        .serverObjectsHint: [.simplifiedChinese: "浏览与管理服务器级对象（角色 / 表空间 / 扩展）。写操作一律先出语句、再确认。", .english: "Browse and manage server-level objects (roles, tablespaces, extensions). Every write shows its statement first."],
        .serverObjectsRefresh: [.simplifiedChinese: "刷新", .english: "Refresh"],
        .serverObjectsLoading: [.simplifiedChinese: "正在读取…", .english: "Loading…"],
        .serverObjectsEmpty: [.simplifiedChinese: "这一类没有对象", .english: "No objects in this category"],
        .serverObjectsKindRole: [.simplifiedChinese: "角色", .english: "Roles"],
        .serverObjectsKindTablespace: [.simplifiedChinese: "表空间", .english: "Tablespaces"],
        .serverObjectsKindExtension: [.simplifiedChinese: "扩展", .english: "Extensions"],
        .serverObjectsUnsupported: [.simplifiedChinese: "%@ 不支持查看%@", .english: "%@ does not support browsing %@"],
        .serverObjectsApproximation: [.simplifiedChinese: "%@ 没有完全对应的概念，下面是近似物：", .english: "%@ has no exact equivalent — the list below is an approximation:"],
        .serverObjectsTablespaceReadOnly: [.simplifiedChinese: "表空间只做只读列出：CREATE TABLESPACE 需要超级用户权限与真实磁盘目录，本面板不提供建 / 删。", .english: "Tablespaces are read-only here: CREATE TABLESPACE needs superuser rights and a real on-disk directory, so this panel does not offer create or drop."],
        .serverObjectsCreateTitle: [.simplifiedChinese: "写操作（先预览，再确认）", .english: "Write operations (preview, then confirm)"],
        .serverObjectsNamePlaceholder: [.simplifiedChinese: "名称", .english: "Name"],
        .serverObjectsPasswordPlaceholder: [.simplifiedChinese: "口令（可留空）", .english: "Password (optional)"],
        .serverObjectsHostPlaceholder: [.simplifiedChinese: "账号主机（GBase / MySQL 用，默认通配）", .english: "Account host (GBase / MySQL only; wildcard by default)"],
        .serverObjectsSchemaPlaceholder: [.simplifiedChinese: "Schema（可留空）", .english: "Schema (optional)"],
        .serverObjectsCanLogin: [.simplifiedChinese: "可登录", .english: "Can log in"],
        .serverObjectsSuperuser: [.simplifiedChinese: "超级用户", .english: "Superuser"],
        .serverObjectsPreviewCreateRole: [.simplifiedChinese: "预览新建角色", .english: "Preview new role"],
        .serverObjectsPreviewDropRole: [.simplifiedChinese: "预览删除角色", .english: "Preview drop role"],
        .serverObjectsPreviewCreateExtension: [.simplifiedChinese: "预览安装扩展", .english: "Preview install extension"],
        .serverObjectsPreviewDropExtension: [.simplifiedChinese: "预览卸载扩展", .english: "Preview uninstall extension"],
        .serverObjectsPreview: [.simplifiedChinese: "预览", .english: "Preview"],
        .serverObjectsConfirm: [.simplifiedChinese: "执行", .english: "Execute"],
        .serverObjectsDryRunHint: [.simplifiedChinese: "预览只生成语句，不会真的执行；确认后再按「执行」。", .english: "Preview only builds the statement — nothing runs until you press Execute."],
        .serverObjectsNoPreview: [.simplifiedChinese: "还没有预览任何语句", .english: "Nothing previewed yet"],
        .serverObjectsNoSelection: [.simplifiedChinese: "先在列表里选中一个对象", .english: "Select an object in the list first"],
        .serverObjectsExecuted: [.simplifiedChinese: "已执行：%@", .english: "Executed: %@"],
        .serverObjectsRejected: [.simplifiedChinese: "已拒绝：%@", .english: "Rejected: %@"],
        .serverObjectsFailure: [.simplifiedChinese: "操作失败：%@", .english: "Operation failed: %@"],
        .serverObjectsRisk: [.simplifiedChinese: "风险等级：%@", .english: "Risk level: %@"],
        .serverObjectsRiskElevated: [.simplifiedChinese: "需确认", .english: "Needs confirmation"],
        .serverObjectsRiskDestructive: [.simplifiedChinese: "不可逆（高危）", .english: "Irreversible (high risk)"],
        .serverObjectsConfirmCreate: [.simplifiedChinese: "确认执行这条语句？", .english: "Execute this statement?"],
        .serverObjectsConfirmDestructive: [.simplifiedChinese: "这是不可逆操作，确认执行？", .english: "This cannot be undone. Execute anyway?"],
        .serverObjectsWarnings: [.simplifiedChinese: "提醒", .english: "Notes"],
        .schemaDiffTitle: [.simplifiedChinese: "Schema 对比与同步", .english: "Schema diff and sync"],
        .schemaDiffHint: [.simplifiedChinese: "源 = 期望结构，目标 = 要被同步的库。默认只做加法与安全修改；删除必须显式打开。生成的脚本只会打开在编辑器里，由你确认后再执行。", .english: "Source is the desired structure, target is the database to be synced. By default only additions and safe changes are made; dropping requires an explicit opt-in. The generated script is only opened in the editor — you decide whether to run it."],
        .schemaDiffSource: [.simplifiedChinese: "期望结构（源）", .english: "Desired structure (source)"],
        .schemaDiffTarget: [.simplifiedChinese: "目标库", .english: "Target database"],
        .schemaDiffDatabase: [.simplifiedChinese: "数据库", .english: "Database"],
        .schemaDiffSchema: [.simplifiedChinese: "模式（Schema）", .english: "Schema"],
        .schemaDiffAllowDrop: [.simplifiedChinese: "允许删除（DROP，破坏性）", .english: "Allow drops (destructive)"],
        .schemaDiffCompare: [.simplifiedChinese: "对比", .english: "Compare"],
        .schemaDiffIdentical: [.simplifiedChinese: "两边结构一致，没有差异", .english: "Both sides are identical — no differences"],
        .schemaDiffMissingInTarget: [.simplifiedChinese: "目标缺这张表 → 会 CREATE", .english: "Missing in target → will be created"],
        .schemaDiffExtraInTarget: [.simplifiedChinese: "目标多这张表（默认不动）", .english: "Extra in target (left alone by default)"],
        .schemaDiffChanged: [.simplifiedChinese: "结构不同", .english: "Structure differs"],
        .schemaDiffSkipped: [.simplifiedChinese: "因未允许删除而跳过：%d 处", .english: "Skipped because drops are not allowed: %d"],
        .schemaDiffStatements: [.simplifiedChinese: "将对目标库执行的语句（%d 条）", .english: "Statements to run against the target (%d)"],
        .schemaDiffNoStatements: [.simplifiedChinese: "没有需要执行的语句", .english: "No statements to run"],
        .schemaDiffCopied: [.simplifiedChinese: "已复制", .english: "Copied"],
        .schemaDiffCopy: [.simplifiedChinese: "复制脚本", .english: "Copy script"],
        .schemaDiffOpenInTab: [.simplifiedChinese: "在新查询页签打开", .english: "Open in a new query tab"],
        .schemaDiffFailed: [.simplifiedChinese: "对比失败：%@", .english: "Comparison failed: %@"],
        .schemaDiffPickConnections: [.simplifiedChinese: "请先选好两侧连接（默认已带上当前连接）", .english: "Pick both connections first (the current connection is pre-selected)"],
        .schemaDiffLoading: [.simplifiedChinese: "正在抓取两侧结构…", .english: "Reading both structures…"],
        .resultJumpToReferencedRow: [.simplifiedChinese: "跳到被引用行…", .english: "Jump to referenced row…"],
        .fkJumpTitle: [.simplifiedChinese: "跳到被引用行", .english: "Jump to referenced row"],
        .fkJumpSource: [.simplifiedChinese: "来源：%@ 的 %@ = %@", .english: "From: %@ . %@ = %@"],
        .fkJumpPickTarget: [.simplifiedChinese: "这一列被多条外键引用，选一个目标：", .english: "This column is referenced by more than one foreign key — pick a target:"],
        .fkJumpNoForeignKey: [.simplifiedChinese: "这一列没有外键（%@），没有可跳转的目标", .english: "Column %@ has no foreign key — nothing to jump to"],
        .fkJumpUnknownTable: [.simplifiedChinese: "这张结果不是从某张表浏览出来的（手写 SQL），无法判断外键；请先用对象树的「浏览数据」打开表", .english: "This result did not come from browsing a table (it is ad-hoc SQL), so foreign keys cannot be resolved. Open the table with Browse data first"],
        .fkJumpNullValue: [.simplifiedChinese: "单元格 %@ 是 NULL，没有可跳转的值", .english: "Cell %@ is NULL — there is no value to jump with"],
        .fkJumpStatus: [.simplifiedChinese: "跳到 %@（%@ = %@）", .english: "Jumped to %@ (%@ = %@)"],
        .fkJumpFailed: [.simplifiedChinese: "读取外键失败：%@", .english: "Could not read foreign keys: %@"],
        .backupRestoreTitle: [.simplifiedChinese: "备份 / 恢复", .english: "Backup / restore"],
        .backupRestoreHint: [.simplifiedChinese: "封装 `pg_dump` / `pg_restore` / `pg_dumpall`：**执行前先比工具与服务端主版本**，不兼容就提前拦下并说明原因与办法", .english: "Wraps pg_dump / pg_restore / pg_dumpall. Tool and server major versions are compared before running; incompatible pairs are stopped early with a reason and a remedy"],
        .backupRestoreKindDump: [.simplifiedChinese: "单库备份", .english: "Dump one database"],
        .backupRestoreKindDumpAll: [.simplifiedChinese: "集群备份（含角色）", .english: "Dump the cluster"],
        .backupRestoreKindRestore: [.simplifiedChinese: "恢复到库", .english: "Restore into a database"],
        .backupRestoreFormat: [.simplifiedChinese: "格式", .english: "Format"],
        .backupRestoreArchive: [.simplifiedChinese: "归档文件", .english: "Archive file"],
        .backupRestoreChoose: [.simplifiedChinese: "选择…", .english: "Choose…"],
        .backupRestoreTool: [.simplifiedChinese: "工具路径（PATH 里常常没有 pg_dump）", .english: "Tool path (pg_dump is often not on PATH)"],
        .backupRestoreCheck: [.simplifiedChinese: "检查工具兼容性", .english: "Check tool compatibility"],
        .backupRestoreRun: [.simplifiedChinese: "执行", .english: "Run"],
        .backupRestoreCommandPreview: [.simplifiedChinese: "将执行的命令（密码写成 ***）", .english: "Command to run (password shown as ***)"],
        .backupSandboxHint: [.simplifiedChinese: "起外部程序失败：沙箱下不允许直接启动 `pg_dump` 等工具。请改用非沙箱构建（`DOYAH_NO_SANDBOX=1 ./Scripts/build-app.sh`），或用命令行 `doyah backup`。", .english: "Failed to launch the external tool: the sandbox does not allow spawning pg_dump. Use the unsandboxed build (DOYAH_NO_SANDBOX=1 ./Scripts/build-app.sh) or the CLI (doyah backup)."],
        .backupRestoreTargetDatabase: [.simplifiedChinese: "目标库（恢复到哪一个库）", .english: "Target database (where to restore)"],
        .backupRestoreTargetDatabaseHint: [.simplifiedChinese: "留空表示用当前连接的库；恢复**必须**知道目标库，不知道就不会执行。", .english: "Leave empty to use the connected database; a restore always needs an explicit target, so nothing runs without one."],
        .backupRestoreSection: [.simplifiedChinese: "分段（失败可从没做完的那一段续跑）", .english: "Sections (a failure can resume at the unfinished one)"],
        .backupRestoreSectionAll: [.simplifiedChinese: "一次完成（不分段）", .english: "All at once (no sections)"],
        .backupRestoreSectionPreData: [.simplifiedChinese: "仅结构（pre-data）", .english: "Structure only (pre-data)"],
        .backupRestoreSectionData: [.simplifiedChinese: "仅数据（data）", .english: "Data only (data)"],
        .backupRestoreSectionPostData: [.simplifiedChinese: "仅索引与约束（post-data）", .english: "Indexes and constraints only (post-data)"],
        .backupRestoreClean: [.simplifiedChinese: "先清理同名对象（--clean）", .english: "Drop same-named objects first (--clean)"],
        .backupRestoreJobsLabel: [.simplifiedChinese: "并行数（--jobs）：%d", .english: "Parallel jobs (--jobs): %d"],
        .backupRestoreJobsLabelOff: [.simplifiedChinese: "并行数（--jobs）：不并行", .english: "Parallel jobs (--jobs): none"],
        .backupRestoreRunRestore: [.simplifiedChinese: "开始恢复", .english: "Start restore"],
        .backupRestoreSectionStarting: [.simplifiedChinese: "==> 正在恢复：%@", .english: "==> Restoring: %@"],
        .backupRestoreSectionsDone: [.simplifiedChinese: "三段全部完成（结构 → 数据 → 索引与约束）。", .english: "All three sections finished (structure → data → indexes and constraints)."],
        .backupRestoreSectionFailed: [.simplifiedChinese: "第 %@ 段失败（退出码 %d）。", .english: "The %@ section failed (exit code %d)."],
        .backupRestoreStopped: [.simplifiedChinese: "已停在 %@ 段：后续段**没有**执行。", .english: "Stopped at the %@ section; later sections did **not** run."],
        .backupRestoreResumeLead: [.simplifiedChinese: "恢复失败不必从头再来 —— 按下面的建议从没做完的那一段接着做：", .english: "A failed restore does not start over — resume at the unfinished section as suggested below:"],
        .backupRestoreModeSectioned: [.simplifiedChinese: "逐段（结构 → 数据 → 索引与约束，失败可续跑）", .english: "Section by section (structure → data → indexes, resumable)"],
        .backupRestoreFailedUnknownSection: [.simplifiedChinese: "恢复失败，但这次没有分段，无法确定停在哪一段。", .english: "The restore failed and this run was not sectioned, so the stopping point is unknown."],
        .backupRestoreLogCommand: [.simplifiedChinese: "命令：%@", .english: "Command: %@"],
        .backupRestoreLogReason: [.simplifiedChinese: "原因：%@", .english: "Reason: %@"],
        .backupRestoreIncomplete: [.simplifiedChinese: "（还缺归档路径 / 目标库，先补齐）", .english: "(archive path / target database still missing — fill them in first)"],
        .connectionFormReadOnly: [.simplifiedChinese: "只读连接（客户端拒绝写语句）", .english: "Read-only connection (client refuses writes)"],
        .connectionFormReadOnlyHint: [.simplifiedChinese: "这是**本机保护**，不替代数据库权限；关闭 Safe Mode 也不会放开它", .english: "This is local protection, not a database privilege; turning Safe Mode off will not lift it"],
        .connectionFormStartupSQL: [.simplifiedChinese: "连接后自动执行（启动 SQL，分号分隔）", .english: "Run after connecting (startup SQL, semicolon separated)"],
        .connectionFormStartupSQLHint: [.simplifiedChinese: "例：`SET search_path TO public; SET statement_timeout = '5s'` —— 逐条执行，一条失败不影响其它条", .english: "e.g. `SET search_path TO public; SET statement_timeout = '5s'` — executed one by one; a failure does not stop the rest"],
        .startupSQLFailed: [.simplifiedChinese: "启动 SQL 有语句失败：%@（%@）", .english: "A startup statement failed: %@ (%@)"],
        .startupSQLRefused: [.simplifiedChinese: "启动 SQL 里有 %@ 条写语句，而该连接是只读的 —— 已整体跳过", .english: "%@ startup statement(s) write data but this connection is read-only — all skipped"],
        .safetyReadOnlyRefused: [.simplifiedChinese: "该连接是只读的，已拒绝执行写语句", .english: "This connection is read-only; the write statement was refused"],
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
        .statePasswordSearched: [.simplifiedChinese: "已查找口令文件：%@", .english: "Looked for the secret file at: %@"],

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

        .treeActionBrowseWithCondition: [.simplifiedChinese: "按条件浏览…", .english: "Browse with Condition…"],
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
        .exportStreamProgress: [.simplifiedChinese: "正在流式导出…已取 %d 行（%d 页）", .english: "Streaming export… %d row(s) fetched in %d page(s)"],
        .exportStreamSucceeded: [.simplifiedChinese: "已流式导出 %d 行（%d 页）到 %@", .english: "Streamed %d row(s) in %d page(s) to %@"],
        .exportStreamNoRows: [.simplifiedChinese: "流式导出没有取到任何行（查询可能已经失效或不返回结果集）。", .english: "The streaming export fetched no rows (the query may be stale or return no result set)."],
        .exportStreamNotPossible: [.simplifiedChinese: "这次导出走的是一次性方式，没有流式（原因：%1$@）。大结果集下内存会随行数增长。", .english: "This export used the one-shot path instead of streaming (reason: %1$@). Memory grows with the row count on large results."],
        .exportStreamReasonMultiStatement: [.simplifiedChinese: "页签里的 SQL 不止一条语句，服务端游标只能用于单条查询", .english: "the tab holds more than one statement, and a server cursor works on a single query only"],
        .exportStreamReasonNotQuery: [.simplifiedChinese: "语句不是查询（游标只能用于 SELECT / WITH 这类查询）", .english: "the statement is not a query (a cursor only works for SELECT / WITH and the like)"],
        .exportStreamReasonManualTransaction: [.simplifiedChinese: "当前连接处在手工事务里，而游标导出会自己开一个事务", .english: "the connection is inside a manual transaction, and a cursor export opens its own transaction"],
        .inlineEditNoSourceTable: [.simplifiedChinese: "这个结果来自手写 SQL，无法确定来源表；改 / 删 / 加行都需要知道是哪张表。请用对象树里的「浏览数据」打开表，或在 SQL 里显式写出表名后重跑。", .english: "This result came from hand-written SQL, so its source table is unknown; editing, deleting and inserting all need to know the table. Open the table via Browse rows in the object tree, or re-run a query that names the table explicitly."],
        .inlineEditActive: [.simplifiedChinese: "编辑中：%d 处改动未提交", .english: "Editing: %d uncommitted change(s)"],
        .inlineEditAppendRow: [.simplifiedChinese: "追加一行…", .english: "Append row…"],
        .inlineEditDiscard: [.simplifiedChinese: "放弃改动", .english: "Discard changes"],
        .inlineEditPreview: [.simplifiedChinese: "预览并执行…", .english: "Preview and run…"],
        .inlineEditMarkDelete: [.simplifiedChinese: "标记删除此行", .english: "Mark this row for deletion"],
        .inlineEditUnmarkDelete: [.simplifiedChinese: "取消删除标记", .english: "Unmark deletion"],
        .inlineEditDeletedTag: [.simplifiedChinese: "待删除", .english: "to delete"],
        .inlineEditPendingCell: [.simplifiedChinese: "待提交（还没有写库）", .english: "Pending (not written yet)"],
        .inlineEditPreviewTitle: [.simplifiedChinese: "将要执行的改动（预览）", .english: "Changes that will run (preview)"],
        .inlineEditPreviewHint: [.simplifiedChinese: "下面是**真正会执行**的那几条语句，包在单个事务里；任何一条失败就整批回滚，预览本身不改任何数据。", .english: "These are the exact statements that will run, wrapped in one transaction; any failure rolls the whole batch back, and the preview itself changes nothing."],
        .inlineEditRefused: [.simplifiedChinese: "这批改动无法执行，理由如下：", .english: "This batch cannot run, for these reasons:"],
        .inlineEditCommit: [.simplifiedChinese: "执行", .english: "Run"],
        .inlineEditSucceeded: [.simplifiedChinese: "已提交 %d 条语句（单个事务）。结果表里仍是旧值，重跑查询即可看到最新数据。", .english: "Committed %d statement(s) in one transaction. The grid still shows the old values; re-run the query to see the new data."],
        .inlineEditRolledBack: [.simplifiedChinese: "有语句失败，整批已回滚，数据库没有被改动：%@", .english: "A statement failed, so the whole batch was rolled back and nothing was changed: %@"],
        .inlineEditPlanFailed: [.simplifiedChinese: "无法生成改动计划：%@", .english: "Could not build the change plan: %@"],
        .inlineEditManualTransaction: [.simplifiedChinese: "当前连接处在手工事务里，内联编辑需要自己的事务（否则会把你的手工事务一起提交）。请先提交或回滚手工事务。", .english: "This connection is inside a manual transaction, and an inline edit needs its own transaction (otherwise it would commit yours too). Commit or roll back the manual transaction first."],
        .inlineEditInsertTitle: [.simplifiedChinese: "追加一行", .english: "Append a row"],
        .inlineEditUnsupportedDialect: [.simplifiedChinese: "当前方言不支持读取表结构，无法安全生成 DML（主键判定拿不到）。", .english: "This dialect cannot read the table structure, so DML cannot be generated safely (primary keys are unknown)."],
        .inlineEditDiscardedOnViewChange: [.simplifiedChinese: "结果表的显示内容变了（翻页 / 排序 / 筛选）：行号的含义跟着变了，未提交的改动已放弃，以免把改动标到别的行上。", .english: "The grid now shows different rows (paging, sorting or filtering), so row numbers no longer mean the same rows; the uncommitted changes were discarded rather than shown against the wrong rows."],
        .inlineEditStatementCount: [.simplifiedChinese: "将执行 %d 条语句：", .english: "Will run %d statement(s):"],
        .inlineEditDiscarded: [.simplifiedChinese: "已退出编辑：未提交的改动已放弃，数据库没有被改动。", .english: "Left edit mode: the uncommitted changes were discarded and nothing was written."],
        .inlineEditCellHint: [.simplifiedChinese: "双击单元格改值；写 NULL（不分大小写）表示空值，清空文本写的是空串。右键可标记删除行。", .english: "Double-click a cell to edit it; NULL (any case) writes a null, while clearing the text writes an empty string. Right-click marks a row for deletion."],
        .inlineEditInsertHint: [.simplifiedChinese: "留空 = 不写这一列（交给数据库默认值）；写 NULL = 空值；写 '' = 空串。", .english: "Leave a field empty to omit the column (database default); write NULL for a null; write '' for an empty string."],
        .inlineEditInsertConfirm: [.simplifiedChinese: "加入待提交", .english: "Add to pending changes"],
        .inlineEditInsertEmpty: [.simplifiedChinese: "一行都没有填：追加行至少要写一列。", .english: "Nothing was filled in: an appended row needs at least one column."],
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

        // 版本历史与回滚（FR-AI-11 的界面入口）
        .dataTaskVersionsOpen: [.simplifiedChinese: "版本历史…", .english: "Version history…"],
        .dataTaskVersionsTitle: [.simplifiedChinese: "版本历史", .english: "Version history"],
        .dataTaskVersionsHint: [.simplifiedChinese: "历史只追加：回滚不删除任何版本，而是把旧内容作为新版本再记一次。", .english: "History is append-only: rolling back deletes nothing — the old content is recorded again as a new version."],
        .dataTaskVersionsEmpty: [.simplifiedChinese: "这个任务还没有版本记录（保存任务时自动记下第一条）。", .english: "No versions yet for this task (the first save records v1)."],
        .dataTaskVersionsColumnNumber: [.simplifiedChinese: "版本", .english: "Version"],
        .dataTaskVersionsColumnTime: [.simplifiedChinese: "时间", .english: "Time"],
        .dataTaskVersionsColumnNote: [.simplifiedChinese: "备注", .english: "Note"],
        .dataTaskVersionsColumnCurrent: [.simplifiedChinese: "与当前定义", .english: "vs. current"],
        .dataTaskVersionsSameCurrent: [.simplifiedChinese: "相同", .english: "Same"],
        .dataTaskVersionsDifferentCurrent: [.simplifiedChinese: "不同", .english: "Different"],
        .dataTaskVersionsUnknownCurrent: [.simplifiedChinese: "尚未保存", .english: "Not saved yet"],
        .dataTaskVersionsCompareTitle: [.simplifiedChinese: "对比两个版本（字段级）", .english: "Compare two versions (field level)"],
        .dataTaskVersionsCompareLeft: [.simplifiedChinese: "基准", .english: "Base"],
        .dataTaskVersionsCompareRight: [.simplifiedChinese: "对比", .english: "Compare"],
        .dataTaskVersionsDiffTitle: [.simplifiedChinese: "字段级差异", .english: "Field-level differences"],
        .dataTaskVersionsDiffEmpty: [.simplifiedChinese: "这两个版本没有差异。", .english: "These two versions are identical."],
        .dataTaskVersionsDiffCount: [.simplifiedChinese: "共 %d 处改动", .english: "%d changes"],
        .dataTaskVersionsDiffNoSelection: [.simplifiedChinese: "选两个版本看差异。", .english: "Pick two versions to see the differences."],
        .dataTaskVersionsRollback: [.simplifiedChinese: "回滚到此版本", .english: "Roll back to this version"],
        .dataTaskVersionsRollbackConfirmTitle: [.simplifiedChinese: "确认回滚", .english: "Confirm rollback"],
        .dataTaskVersionsRollbackConfirmMessage: [.simplifiedChinese: "回滚到 v%d：该版本的内容会被重新保存为一个新版本，现有历史不会被删除。", .english: "Roll back to v%d: that version's content is saved again as a new version; existing history is not deleted."],
        .dataTaskVersionsRolledBack: [.simplifiedChinese: "已回滚到 v%d（以新版本留痕，旧版本仍可查）", .english: "Rolled back to v%d (recorded as a new version; earlier versions stay readable)"],
        .dataTaskVersionsRollbackNote: [.simplifiedChinese: "回滚到 v%d", .english: "Roll back to v%d"],
        .dataTaskVersionsRollbackFailed: [.simplifiedChinese: "回滚失败：%@", .english: "Rollback failed: %@"],
        .dataTaskVersionsLoadFailed: [.simplifiedChinese: "读取版本历史失败：%@", .english: "Failed to read version history: %@"],
        .dataTaskVersionsAppendOnlyNote: [.simplifiedChinese: "回滚不是删历史：版本记录只追加，旧版本始终可查。", .english: "Rollback is not deletion: the version log is append-only, so earlier versions stay readable."],
        .dataTaskVersionsNoSelection: [.simplifiedChinese: "先选一个已保存的任务（未保存的新任务还没有历史）。", .english: "Select a saved task first (a new unsaved task has no history yet)."],

        // 记忆治理（FR-AI-15 的界面入口）
        .memoryGovernanceTabCandidates: [.simplifiedChinese: "例行候选", .english: "Routine candidates"],
        .memoryGovernanceTabMemory: [.simplifiedChinese: "记忆治理", .english: "Memory governance"],
        .memoryGovernanceHint: [.simplifiedChinese: "记忆的事实源是查询归档：这里只做浏览与治理（来源解释 / 单条删除 / 整层清空 / 本次执行不记录），每条判定都由 Core 的纯函数给出。", .english: "Query memory derives from the SQL archive. This tab only browses and governs it — provenance, single-entry delete, whole-layer clear, and a per-session recording switch — with every verdict computed by Core's pure functions."],
        .memoryGovernanceEmpty: [.simplifiedChinese: "记忆层是空的：还没有归档记录，或者归档未开启。", .english: "The memory layer is empty: no archive records yet, or archiving is off."],
        .memoryGovernanceArchiveDisabled: [.simplifiedChinese: "归档功能未开启：记忆层不会再有新内容。请先在「归档」面板里指定目录并开启。", .english: "Archiving is off, so the memory layer will not gain new entries. Set a directory in the Archive panel and enable it first."],
        .memoryGovernanceIndexNote: [.simplifiedChinese: "从 %d 条归档记录派生出 %d 条记忆。", .english: "%d archive records yield %d memories."],
        .memoryGovernanceExplain: [.simplifiedChinese: "来源解释", .english: "Provenance"],
        .memoryGovernanceRetentionForget: [.simplifiedChinese: "会被遗忘", .english: "Will be forgotten"],
        .memoryGovernanceRetentionKeep: [.simplifiedChinese: "会保留", .english: "Will be kept"],
        .memoryGovernanceKindLabel: [.simplifiedChinese: "类别", .english: "Kind"],
        .memoryGovernanceDelete: [.simplifiedChinese: "删除这条", .english: "Delete this entry"],
        .memoryGovernanceDeleteConfirmTitle: [.simplifiedChinese: "确认删除", .english: "Confirm delete"],
        .memoryGovernanceDeleteConfirmMessage: [.simplifiedChinese: "删除会改写归档文件（记忆的事实源），该骨架下的所有取值变体都会被删掉：%@", .english: "Deleting rewrites the archive files (the source of truth) and removes every value variant under this fingerprint: %@"],
        .memoryGovernanceDeleted: [.simplifiedChinese: "已删除 %d 条归档记录（改动 %d 个文件）", .english: "Deleted %d archive records (%d files changed)"],
        .memoryGovernanceDeleteFailed: [.simplifiedChinese: "删除失败：%@", .english: "Delete failed: %@"],
        .memoryGovernanceClearLayer: [.simplifiedChinese: "清空环境层…", .english: "Clear environment layer…"],
        .memoryGovernanceClearConfirmTitle: [.simplifiedChinese: "确认清空环境层", .english: "Confirm clearing the environment layer"],
        .memoryGovernanceClearConfirmMessage: [.simplifiedChinese: "整层清空不可逆：会删掉归档目录下的全部归档文件（共 %d 条记录）。确定继续？", .english: "Clearing the whole layer is irreversible: every archive file under the archive directory (with %d records) will be deleted. Continue?"],
        .memoryGovernanceCleared: [.simplifiedChinese: "已清空环境层：删除 %d 条记录 / %d 个文件", .english: "Environment layer cleared: %d records deleted / %d files"],
        .memoryGovernanceClearFailed: [.simplifiedChinese: "清空失败：%@", .english: "Clear failed: %@"],
        .memoryGovernanceLayerNote: [.simplifiedChinese: "环境层 = 归档（按连接隔离）；通用层目前只做脱敏判定、不落盘，所以这里没有可清空的通用层内容。", .english: "The environment layer is the archive (isolated per connection). The general layer is only checked for de-identification and is not persisted yet, so there is nothing general to clear here."],
        .memoryGovernanceRecordingTitle: [.simplifiedChinese: "「本次执行不记录」", .english: "\"Do not record\" switch"],
        .memoryGovernanceRecordingToggle: [.simplifiedChinese: "本次执行不记录（本会话内后续执行也不归档）", .english: "Do not record (later runs in this session are not archived either)"],
        .memoryGovernanceRecordingOn: [.simplifiedChinese: "判定：%@；这次执行不会被记入记忆。", .english: "Decision: %@; this run will not be remembered."],
        .memoryGovernanceRecordingOff: [.simplifiedChinese: "判定：%@；执行会正常记入记忆。", .english: "Decision: %@; runs are recorded normally."],
        .memoryGovernanceLoadFailed: [.simplifiedChinese: "读取记忆失败：%@", .english: "Failed to read memory: %@"],

        // 导入（FR-IO-03 的整套界面）
        .menuImportData: [.simplifiedChinese: "导入数据…", .english: "Import Data…"],
        .importTitle: [.simplifiedChinese: "导入数据（CSV / TSV / JSON）", .english: "Import data (CSV / TSV / JSON)"],
        .importHint: [.simplifiedChinese: "选文件 → 选目标表 → 列映射预览 → 写入通道 → 执行。列映射直接用 Core 的匹配规则；COPY 优先，取不到时如实说明理由再退回批量 INSERT。", .english: "Pick a file, pick a target table, review the column mapping, choose the write channel, then run. Mapping uses Core's rules directly; COPY is preferred, and when it is unavailable the reason is stated before falling back to batched INSERT."],
        .importFile: [.simplifiedChinese: "文件", .english: "File"],
        .importChooseFile: [.simplifiedChinese: "选择文件…", .english: "Choose file…"],
        .importNoFile: [.simplifiedChinese: "还没有选文件。", .english: "No file chosen yet."],
        .importFormat: [.simplifiedChinese: "格式", .english: "Format"],
        .importHasHeader: [.simplifiedChinese: "首行是表头", .english: "First row is a header"],
        .importTargetTable: [.simplifiedChinese: "目标表", .english: "Target table"],
        .importTargetTableHint: [.simplifiedChinese: "填 schema.table 或只填表名；默认取对象树当前选中的表。", .english: "Use schema.table or just the table name; defaults to the table selected in the object tree."],
        .importParse: [.simplifiedChinese: "解析并预览", .english: "Parse and preview"],
        .importParseFailed: [.simplifiedChinese: "解析失败：%@", .english: "Parse failed: %@"],
        .importReadFailed: [.simplifiedChinese: "读取文件失败：%@", .english: "Failed to read file: %@"],
        .importSourceSummary: [.simplifiedChinese: "文件：%@（%d 行数据 · %d 列）", .english: "File: %@ (%d rows · %d columns)"],
        .importWarnings: [.simplifiedChinese: "解析告警（前 %d 条）", .english: "Parse warnings (first %d)"],
        .importColumnMapping: [.simplifiedChinese: "列映射（文件 → 目标列）", .english: "Column mapping (file → target)"],
        .importMappingMissing: [.simplifiedChinese: "文件里没有，走默认值 / NULL", .english: "Absent in the file — default value / NULL"],
        .importMappingUnknown: [.simplifiedChinese: "文件里有、目标表没有的列（会被忽略）：%@", .english: "Columns in the file but not in the target table (ignored): %@"],
        .importMappingMissingRequired: [.simplifiedChinese: "这些必填列在文件里没有对应列：%@（继续导入一定失败，已阻止）", .english: "Required columns with no matching file column: %@ (the import would fail, so it is blocked)"],
        .importMappingEmpty: [.simplifiedChinese: "没有任何列能映射到目标表。", .english: "No column maps to the target table."],
        .importPrecheckInvalid: [.simplifiedChinese: "这些值无法按目标列类型转换（前 %d 条）—— INSERT 路径会写成 NULL，COPY 路径会被服务端直接拒绝：", .english: "Values that cannot convert to the target column types (first %d) — the INSERT path writes NULL, while the COPY path is rejected by the server:"],
        .importWriteMode: [.simplifiedChinese: "写入通道", .english: "Write channel"],
        .importWriteModeCopy: [.simplifiedChinese: "COPY（快路径）", .english: "COPY (fast path)"],
        .importWriteModeBatchInsert: [.simplifiedChinese: "批量 INSERT（回退）", .english: "Batched INSERT (fallback)"],
        .importCopyStatement: [.simplifiedChinese: "将下发的 COPY 语句（预览用；数据由驱动按 COPY text 格式编码）", .english: "COPY statement to be issued (preview only; the driver encodes the data in COPY text format)"],
        .importPreviewTitle: [.simplifiedChinese: "前 %d 行预览", .english: "Preview of the first %d rows"],
        .importPreviewEmpty: [.simplifiedChinese: "没有可预览的数据行。", .english: "No data rows to preview."],
        .importExecute: [.simplifiedChinese: "执行导入", .english: "Run import"],
        .importStop: [.simplifiedChinese: "停止", .english: "Stop"],
        .importConfirmTitle: [.simplifiedChinese: "确认导入", .english: "Confirm import"],
        .importConfirmMessage: [.simplifiedChinese: "安全检查要求二次确认：%@", .english: "The safety check requires confirmation: %@"],
        .importRunning: [.simplifiedChinese: "正在执行…", .english: "Running…"],
        .importProgress: [.simplifiedChinese: "进度：第 %d / %d 批（已写 %d 行）", .english: "Progress: batch %d of %d (%d rows written)"],
        .importCopyStarted: [.simplifiedChinese: "开始 COPY：%d 行 / %d 列（%d 字节，text 格式）", .english: "Starting COPY: %d rows / %d columns (%d bytes, text format)"],
        .importDone: [.simplifiedChinese: "导入完成：写入 %d 行（%d 批）", .english: "Import complete: %d rows written (%d batches)"],
        .importDoneCopy: [.simplifiedChinese: "COPY 写入完成：%d 行，用时 %.2f 秒", .english: "COPY finished: %d rows in %.2f s"],
        .importFailed: [.simplifiedChinese: "导入失败：%@", .english: "Import failed: %@"],
        .importPartial: [.simplifiedChinese: "已写入 %d 行（前面的批次已生效，请按需清理）", .english: "%d rows were written (earlier batches are committed; clean up as needed)"],
        .importCancelled: [.simplifiedChinese: "已停止：已写入 %d 行（前面的批次已生效）", .english: "Stopped: %d rows written (earlier batches are committed)"],
        .importLog: [.simplifiedChinese: "逐批日志", .english: "Batch log"],
        .importNeedsConnection: [.simplifiedChinese: "先选择一个连接。", .english: "Select a connection first."],
        .importNeedsParsedFile: [.simplifiedChinese: "先选文件并点「解析并预览」。", .english: "Choose a file and click Parse and preview first."],
        .importStructureFailed: [.simplifiedChinese: "读取目标表结构失败：%@", .english: "Failed to read the target table structure: %@"],
        .importStructureEmpty: [.simplifiedChinese: "读不到目标表的列结构（表名写对了吗？）。", .english: "Could not read the target table's columns (is the table name right?)"],
        .importNothingMapped: [.simplifiedChinese: "没有任何列能映射到目标表，已中止。", .english: "No column maps to the target table; aborted."],
        .importSampleNote: [.simplifiedChinese: "预览只取前若干行；执行时按批处理全部行。", .english: "The preview shows only the first rows; the run processes every row in batches."],
        .importCopyAtomicNote: [.simplifiedChinese: "COPY 在单条语句内是原子的：失败即整批未写入，不会留下半截。", .english: "COPY is atomic within a single statement: on failure nothing is written, so no half-import remains."],
    ]
}
