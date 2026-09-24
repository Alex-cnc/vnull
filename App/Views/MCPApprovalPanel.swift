import DoyahCore
import SwiftUI

/// 「外部调用审批」面板（FR-AI-10 的界面那一半）。
///
/// 为什么需要它：MCP server 跑在 CLI 的 stdin/stdout 上（那是协议通道，借不来弹窗），
/// 而"批准这一次外部调用"必须由**界面上的人**来点。两边共用一个文件队列：
/// server 入队并等 → 这里显示待审批项 → 人点允许 / 拒绝 → server 读决定再执行。
///
/// 三条刻意的口径写在面板上：
///   · 批准只对**这一次**有效（不是给某个工具开总开关）；
///   · **没人确认时默认不放行**（超时 = 拒绝，不是默认同意）；
///   · 队列位置显示出来 —— 出问题时用户知道去哪儿看。
struct MCPApprovalPanel: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text(L(.mcpApprovalHint))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    if appState.mcpApprovalBadLines > 0 {
                        Text(L(.mcpApprovalBadLines, appState.mcpApprovalBadLines))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.status(.warning))
                    }
                    if appState.mcpPendingApprovals.isEmpty {
                        Text(L(.mcpApprovalEmpty))
                            .font(Theme.font(.body))
                            .foregroundStyle(Theme.text(.secondary))
                    } else {
                        ForEach(appState.mcpPendingApprovals, id: \.id) { request in
                            requestRow(request)
                        }
                    }
                    if let message = appState.mcpApprovalMessage {
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
        .frame(width: 720, height: 600)
        .onDisappear { appState.closeMCPApprovals() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(L(.mcpApprovalTitle))
                    .font(Theme.font(.title))
                Text(L(.mcpApprovalPending, appState.mcpPendingApprovals.count))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
            Spacer()
            Button(L(.commonClose)) { dismiss() }
        }
        .padding(Spacing.l)
    }

    private func requestRow(_ request: MCPApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text(request.tool)
                    .font(Theme.font(.mono))
                Text("· " + request.client)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                Spacer()
                Button(L(.mcpApprovalAllow)) {
                    appState.decideMCPApproval(requestID: request.id, approved: true)
                }
                .keyboardShortcut(.defaultAction)
                Button(L(.mcpApprovalDeny)) {
                    appState.decideMCPApproval(requestID: request.id, approved: false)
                }
            }
            if let sql = request.sql {
                // 人要看的就是这条语句 —— 放在最显眼的位置。
                Text(sql)
                    .font(Theme.font(.mono))
                    .textSelection(.enabled)
                    .padding(Spacing.s)
                    .background(Theme.surface(.panel))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(request.argumentsSummary)
                    .font(Theme.font(.monoSmall))
                    .foregroundStyle(Theme.text(.secondary))
                    .textSelection(.enabled)
            }
            Text(request.reason)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.status(.warning))
        }
        .padding(Spacing.s)
        .background(Theme.surface(.raised))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(spacing: Spacing.m) {
            Button(L(.mcpApprovalRefresh)) { appState.refreshMCPApprovals() }
            Spacer()
            Text(L(.mcpApprovalQueuePath, appState.mcpApprovalStore.directory.path))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(Spacing.l)
    }
}
