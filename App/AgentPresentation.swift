import SwiftUI
import DoyahCore

/// Core 的审计 / 护栏枚举 → 界面文案与配色。
///
/// 为什么不直接用 Core 的 `displayName`：那些是给日志与单测用的**固定中文**串，
/// 而界面必须跟随语言切换（本工程约定：界面文案一律走 `Core/Localization.swift`）。
/// 映射集中在这一处，避免面板与审批单各写一份 switch。
extension AgentStatementKind {
    var textKey: LKey {
        switch self {
        case .readQuery: return .agentKindReadQuery
        case .dataChange: return .agentKindDataChange
        case .schemaChange: return .agentKindSchemaChange
        case .privilegeChange: return .agentKindPrivilegeChange
        case .sessionControl: return .agentKindSessionControl
        case .unknown: return .agentKindUnknown
        }
    }

    var text: String { L(textKey) }
}

extension AgentActionRecord.Outcome {
    var textKey: LKey {
        switch self {
        case .generated: return .agentOutcomeGenerated
        case .denied: return .agentOutcomeDenied
        case .pendingApproval: return .agentOutcomePendingApproval
        case .approved: return .agentOutcomeApproved
        case .rejected: return .agentOutcomeRejected
        case .expired: return .agentOutcomeExpired
        case .executed: return .agentOutcomeExecuted
        case .failed: return .agentOutcomeFailed
        }
    }

    var text: String { L(textKey) }

    /// 列表里的状态配色：危险 / 等待 / 成功 / 中性。
    var tint: Color {
        switch self {
        case .denied, .rejected, .failed: return .red
        case .pendingApproval: return .orange
        case .approved, .executed: return .green
        case .generated, .expired: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .generated: return "doc.text"
        case .denied: return "hand.raised.fill"
        case .pendingApproval: return "hourglass"
        case .approved: return "checkmark.seal"
        case .rejected: return "xmark.octagon.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .executed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

extension AgentRiskLevel {
    var textKey: LKey {
        switch self {
        case .low: return .agentRiskLow
        case .elevated: return .agentRiskElevated
        case .destructive: return .agentRiskDestructive
        }
    }

    var text: String { L(textKey) }

    var tint: Color {
        switch self {
        case .low: return .secondary
        case .elevated: return .orange
        case .destructive: return .red
        }
    }
}

extension AgentAuditExportFormat {
    var textKey: LKey {
        switch self {
        case .json: return .agentAuditExportJSON
        case .csv: return .agentAuditExportCSV
        }
    }

    var text: String { L(textKey) }
}

// MARK: - 数据任务（FR-AI-05 / FR-AI-06 / FR-AI-08）

/// 任务定义的各个枚举 → 界面文案与配色。
///
/// 与上面同一理由：Core 里的 `displayName` 是给日志与单测用的固定中文，
/// 界面必须能跟随语言切换，所以映射集中在这里，不在视图里散写 switch。
extension DataTaskDefinition.Transformation.Kind {
    var textKey: LKey {
        switch self {
        case .rename: return .dataTaskTransformKindRename
        case .cast: return .dataTaskTransformKindCast
        case .derive: return .dataTaskTransformKindDerive
        case .drop: return .dataTaskTransformKindDrop
        case .mask: return .dataTaskTransformKindMask
        }
    }

    var text: String { L(textKey) }
}

extension DataTaskDefinition.Target.WriteMode {
    var textKey: LKey {
        switch self {
        case .append: return .dataTaskWriteModeAppend
        case .overwrite: return .dataTaskWriteModeOverwrite
        case .upsert: return .dataTaskWriteModeUpsert
        }
    }

    var text: String { L(textKey) }
}

extension TaskSchedule.Kind {
    var textKey: LKey {
        switch self {
        case .manual: return .dataTaskScheduleKindManual
        case .once: return .dataTaskScheduleKindOnce
        case .recurring: return .dataTaskScheduleKindRecurring
        }
    }

    var text: String { L(textKey) }
}

extension DataTaskPresentation.ScheduleStatus {
    var textKey: LKey {
        switch self {
        case .notScheduled: return .dataTaskStatusNotScheduled
        case .disabled: return .dataTaskStatusDisabled
        case .waiting: return .dataTaskStatusWaiting
        case .due: return .dataTaskStatusDue
        case .missed: return .dataTaskStatusMissed
        }
    }

    var text: String { L(textKey) }

    /// 状态配色：错过与到点要一眼能分辨。
    var tint: Color {
        switch self {
        case .notScheduled: return .secondary
        case .disabled: return .secondary
        case .waiting: return .blue
        case .due: return .green
        case .missed: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .notScheduled: return "calendar.badge.minus"
        case .disabled: return "pause.circle"
        case .waiting: return "clock"
        case .due: return "clock.badge.checkmark"
        case .missed: return "clock.badge.exclamationmark"
        }
    }
}

extension TaskRunRecord.Status {
    var textKey: LKey {
        switch self {
        case .running: return .dataTaskRunStatusRunning
        case .succeeded: return .dataTaskRunStatusSucceeded
        case .failed: return .dataTaskRunStatusFailed
        case .skipped: return .dataTaskRunStatusSkipped
        }
    }

    var text: String { L(textKey) }

    var tint: Color {
        switch self {
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .skipped: return "forward.circle"
        }
    }
}

extension DirectoryAccessStatus {
    /// 可读状态文案的键。
    ///
    /// 刻意不用 Core 的 `message`：那是给日志与单测用的**固定中文**串；
    /// 界面必须跟随语言，所以只借用它判定的**语义**（六个状态），文案在这里重新取。
    var textKey: LKey {
        switch self {
        case .granted(_, let isStale):
            return isStale ? .dataTaskDirectoryGrantedStale : .dataTaskDirectoryGranted
        case .notAuthorized: return .dataTaskDirectoryNotAuthorized
        case .missing: return .dataTaskDirectoryMissing
        case .denied: return .dataTaskDirectoryDenied
        case .resolutionFailed: return .dataTaskDirectoryResolutionFailed
        }
    }

    /// 补救建议的键（可用时为 `nil`）。
    var hintKey: LKey? {
        switch self {
        case .granted: return nil
        case .notAuthorized: return .dataTaskDirectoryHintNotAuthorized
        case .missing: return .dataTaskDirectoryHintMissing
        case .denied: return .dataTaskDirectoryHintDenied
        case .resolutionFailed: return .dataTaskDirectoryHintResolutionFailed
        }
    }

    /// 需要拼进文案的参数（只有带路径 / 原因的状态才有）。
    var textArgument: String? {
        switch self {
        case .granted(let path, _), .missing(let path), .denied(let path):
            return path
        case .resolutionFailed(let reason):
            return reason
        case .notAuthorized:
            return nil
        }
    }

    /// 直接可显示的整句。
    var text: String {
        guard let argument = textArgument else { return L(textKey) }
        return L(textKey, argument)
    }

    var tint: Color {
        switch self {
        case .granted(_, let isStale): return isStale ? .orange : .green
        case .notAuthorized: return .secondary
        case .missing, .denied, .resolutionFailed: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .granted(_, let isStale): return isStale ? "folder.badge.questionmark" : "folder.fill"
        case .notAuthorized: return "folder.badge.plus"
        case .missing: return "folder.badge.minus"
        case .denied: return "lock.circle"
        case .resolutionFailed: return "questionmark.folder"
        }
    }
}
