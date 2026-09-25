import DoyahCore
import SwiftUI

/// 「维护任务编排」面板（FR-AI-04 的界面入口）。
///
/// 排版的依据就是需求原文那三条：**逐次审批**（每条任务一个批准 / 拒绝按钮，没有"全部批准并执行"这种一键）、
/// **可预览、可编辑、可拒绝**（计划是文本，改完重新审阅；拒绝的任务**留在列表里**并写明理由）、
/// **高开销限流**（默认一次一条，要跑多条得**显式勾选"我知情"**）。
///
/// 两条边界直接在面板上写清楚（而不是等用户点了才发现）：
///   · 只读连接：写任务连批准都不允许（与 `ExecutionSafety` 同口径，不可绕过）；
///   · 沙箱构建：备份 / 恢复这类要起外部程序的任务不可执行（R-18）。
struct MaintenancePanel: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    planSection
                    boundaryNotes
                    taskSection
                    if let message = appState.maintenanceMessage {
                        Text(message)
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                    }
                }
                .padding(Spacing.l)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 680)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(L(.maintenanceTitle))
                    .font(Theme.font(.title))
                if let connection = appState.selectedConnection {
                    Text(connection.endpointDescription)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                }
            }
            Spacer()
            Button(L(.commonClose)) { dismiss() }
        }
        .padding(Spacing.l)
    }

    // MARK: 计划

    private var planSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.maintenancePlanLabel))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            TextEditor(text: $appState.maintenancePlanText)
                .font(Theme.font(.mono))
                .frame(height: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.surface(.panel), lineWidth: 1)
                )
            Text(L(.maintenancePlanHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L(.maintenanceAllowMultiple), isOn: $appState.maintenanceAllowMultipleHighCost)
                .font(Theme.font(.caption))
        }
    }

    private var boundaryNotes: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if appState.selectedConnection?.isReadOnly == true {
                Text(L(.maintenanceReadOnlyBadge))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.danger))
            }
            if appState.isSandboxedBuild {
                Text(L(.maintenanceSandboxedConnection))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
            }
        }
    }

    // MARK: 任务列表

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let review = appState.maintenanceReview {
                if review.tasks.isEmpty {
                    Text(L(.maintenanceNoPlan))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                }
                ForEach(review.tasks, id: \.id) { task in
                    taskRow(task)
                }
                if !review.unparsableLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(review.unparsableLines, id: \.self) { line in
                            Text("✗ " + L(.diagnosisRejectedUnparsable) + "：" + line)
                                .font(Theme.font(.caption))
                                .foregroundStyle(Theme.status(.danger))
                        }
                    }
                }
            } else {
                Text(L(.maintenanceNoPlan))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
        }
    }

    private func taskRow(_ task: MaintenanceTask) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(task.id)
                    .font(Theme.font(.mono))
                    .foregroundStyle(Theme.text(.secondary))
                Text(task.kind.displayName)
                    .font(Theme.font(.caption))
                Text(stateLabel(task.state))
                    .font(Theme.font(.caption))
                    .foregroundStyle(stateTone(task.state))
                if task.risk != .low {
                    Text(task.risk.rawValue)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.warning))
                }
                Spacer()
                if !task.state.isFinished, task.requiresApproval {
                    Button(L(.maintenanceApproveAction)) { appState.approveMaintenanceTask(id: task.id) }
                        .disabled(task.state == .rejected)
                    Button(L(.maintenanceRejectAction)) { appState.rejectMaintenanceTask(id: task.id) }
                        .disabled(task.state == .rejected)
                }
            }
            Text(task.summary)
                .font(Theme.font(.body))
            if let sql = task.sql {
                Text(sql)
                    .font(Theme.font(.mono))
                    .textSelection(.enabled)
            }
            if let command = task.command {
                Text(command)
                    .font(Theme.font(.mono))
                    .textSelection(.enabled)
            }
            ForEach(task.reviewNotes, id: \.self) { note in
                Text("· " + note)
                    .font(Theme.font(.caption))
                    .foregroundStyle(task.state == .rejected ? Theme.status(.danger) : Theme.text(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.s)
        .background(Theme.surface(.raised))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func stateLabel(_ state: MaintenanceTask.State) -> String {
        switch state {
        case .pending: return L(.maintenanceStatePending)
        case .approved: return L(.maintenanceStateApproved)
        case .rejected: return L(.maintenanceStateRejected)
        case .executed: return L(.maintenanceStateExecuted)
        case .failed: return L(.maintenanceStateFailed)
        }
    }

    private func stateTone(_ state: MaintenanceTask.State) -> Color {
        switch state {
        case .executed: return Theme.status(.success)
        case .failed, .rejected: return Theme.status(.danger)
        case .approved: return Theme.status(.warning)
        case .pending: return Theme.text(.secondary)
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: Spacing.m) {
            Button(L(.maintenanceReviewAction)) { appState.reviewMaintenancePlan() }
            // 存进笔记：计划 + 逐条状态与理由（含被拒绝的条目与"没看懂的行"）。
            Button(L(.maintenanceSaveNote)) {
                Task { await appState.saveMaintenanceNote() }
            }
            .disabled(appState.maintenanceReview?.tasks.isEmpty ?? true)
            Spacer()
            Button(appState.maintenanceIsRunning ? L(.diagnosisGathering) : L(.maintenanceExecuteAction)) {
                Task { await appState.executeApprovedMaintenanceTasks() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(appState.maintenanceIsRunning)
        }
        .padding(Spacing.l)
    }
}
