import SwiftUI
import DoyahCore

/// 智能体动作的**逐次审批单**（FR-AI-09）。
///
/// 为什么不复用 `SafeModeConfirmSheet`：那个拦的是「用户自己在编辑器里写的 SQL」，
/// 确认结果只影响本次执行；这个拦的是「**智能体发起的**动作」，无论批准还是拒绝
/// 都必须留下审计记录，而且必须能逐次拒绝。两者的语义与留痕要求不同，
/// 硬塞进一个弹窗会让「谁批准的、批了哪条」变得说不清。
///
/// 面板上把「为什么需要批准」摊开：风险等级、语句类别、护栏风险点、
/// 完整语句、将要使用的连接与库 —— 只说「有风险」等于什么都没说。
struct AgentApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    /// 待决策的审批单（由 `AppState.agentApprovalRequest` 驱动呈现）。
    let approval: AgentApproval

    @State private var note = ""
    @State private var isWorking = false

    private var record: AgentActionRecord { approval.record }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L(.agentApprovalTitle), systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(record.risk.tint)

            Text(L(.agentApprovalMessage))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            contextSection
            findingsSection
            statementSection

            TextField(L(.agentApprovalNote), text: $note)
                .textFieldStyle(.roundedBorder)

            Text(L(.agentApprovalDismissHint))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()

                Button(L(.agentApprovalReject), role: .destructive) {
                    decide(approve: false)
                }
                .disabled(isWorking)

                Button(L(.agentApprovalApprove)) {
                    decide(approve: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    // MARK: - 上下文

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(L(.agentAuditColumnConnection), AgentAuditPresentation.connectionText(record))
            row(L(.agentAuditColumnModel), AgentAuditPresentation.modelText(record))
            row(L(.agentAuditColumnStatement), "\(record.statementKind.text) · \(record.risk.text)")
        }
        .font(.caption)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 护栏结论（NFR-AI-12：为什么需要批准）

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.agentAuditColumnGuard))
                .font(.caption)
                .foregroundStyle(.secondary)

            if record.findings.isEmpty {
                Label(L(.agentAuditGuardNone), systemImage: "checkmark.shield")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(record.findings, id: \.self) { finding in
                    Label(finding.message, systemImage: "exclamationmark.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(finding.risk.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 语句

    private var statementSection: some View {
        ScrollView {
            Text(record.sql)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(height: 150)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 决策

    /// 决策交给 `AppState`：状态机流转 + 执行 + 留痕都在那一处完成，
    /// 界面只负责收集「批准 / 拒绝」与备注。
    private func decide(approve: Bool) {
        guard !isWorking else { return }
        isWorking = true
        let id = approval.id
        let decisionNote = note

        Task {
            if approve {
                await appState.approveAgentAction(id: id, note: decisionNote)
            } else {
                await appState.rejectAgentAction(id: id, note: decisionNote)
            }
            isWorking = false
            // 只有这条审批单真的离开待审批队列才关窗：流转失败时留在原处，
            // 让用户看到错误（而不是「点了没反应、窗口却关了」）。
            if !appState.pendingAgentApprovals.contains(where: { $0.id == id }) {
                dismiss()
            }
        }
    }
}
