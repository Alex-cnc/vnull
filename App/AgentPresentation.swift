import SwiftUI
import PostgresClientCore

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
