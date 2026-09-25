import DoyahCore
import SwiftUI

/// 「诊断这条查询」面板（FR-AI-03 的界面入口）。
///
/// 这个面板的形状直接来自需求原文的两条硬约束：
///   · 「结论须引用真实计划 / 统计 / 锁数据，不允许无依据断言」→ 面板**必须先展示证据**（带编号、
///     带取证 SQL、带"没取到"的原因），模型回答里没引用证据的结论会被**拒绝并显示在下面**；
///   · 「建议可转成 SQL 但须走审批」→ 每条建议显示安全裁决（可直接执行 / 需确认 / 被拒绝），
///     并且「放进编辑器」这个动作**只写文本、不执行** —— 执行仍然走用户自己那一步与那道闸门。
///
/// **没有模型端点怎么用**（本机现状）：面板把组装好的资料块显示出来，用户复制去问任意模型，
/// 再把回答粘回来解读。这不是权宜之计 —— 它让这条功能在"没有端点"的环境下**立刻可用**，
/// 而自动发问只是把这中间的两次复制替换成一个按钮（端点接上以后）。
struct DiagnosisPanel: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var sql = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    questionSection
                    evidenceSection
                    promptSection
                    replySection
                    if let report = appState.diagnosisReport {
                        adviceSection(report)
                        if report.hasRejections {
                            rejectionSection(report)
                        }
                    }
                }
                .padding(Spacing.l)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 700)
        .onAppear {
            if sql.isEmpty { sql = appState.diagnosisTargetSQL }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(L(.diagnosisTitle))
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

    private var footer: some View {
        HStack(spacing: Spacing.m) {
            Text(L(.diagnosisRunHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            Spacer()
            if let message = appState.diagnosisMessage {
                Text(message)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.danger))
            }
        }
        .padding(Spacing.l)
    }

    // MARK: 问题与语句

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.diagnosisQuestionField))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            TextField("", text: $appState.diagnosisQuestion)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $sql)
                .font(Theme.font(.mono))
                .frame(height: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.surface(.panel), lineWidth: 1)
                )
            HStack {
                Button(appState.diagnosisIsGathering ? L(.diagnosisGathering) : L(.diagnosisGather)) {
                    Task { await appState.gatherDiagnosisEvidence(sql: sql) }
                }
                .disabled(appState.diagnosisIsGathering || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
        }
    }

    // MARK: 证据

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.diagnosisEvidenceSection))
                .font(Theme.font(.title))
            if appState.diagnosisEvidence.isEmpty {
                Text(L(.diagnosisEmpty))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            } else {
                ForEach(appState.diagnosisEvidence, id: \.id) { evidence in
                    evidenceRow(evidence)
                }
            }
        }
    }

    private func evidenceRow(_ evidence: DiagnosisEvidence) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(evidence.id)
                    .font(Theme.font(.mono))
                    .foregroundStyle(Theme.text(.secondary))
                Text(evidence.kind.displayName)
                    .font(Theme.font(.caption))
                if evidence.isAvailable {
                    Text(evidence.note)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                } else {
                    // 取不到的证据**显式标红**：它不能作为依据，用户要一眼看出来。
                    Text(evidence.note)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.danger))
                }
                Spacer()
            }
            if !evidence.rows.isEmpty {
                Text(evidence.rows.prefix(6).map { row in
                    row.map { $0 ?? "NULL" }.joined(separator: "  ")
                }.joined(separator: "\n"))
                .font(Theme.font(.mono))
                .foregroundStyle(Theme.text(.secondary))
                .lineLimit(6)
            }
        }
        .padding(Spacing.s)
        .background(Theme.surface(.raised))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 资料块（复制去问模型）

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.diagnosisPromptSection))
                .font(Theme.font(.title))
            Text(L(.diagnosisPromptHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L(.commonCopy)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.diagnosisContext.boundedPromptText(), forType: .string)
                }
                .disabled(appState.diagnosisEvidence.isEmpty)
                Spacer()
            }
            Text(appState.diagnosisContext.boundedPromptText())
                .font(Theme.font(.mono))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
                .background(Theme.surface(.raised))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: 回答与解读

    private var replySection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.diagnosisReplySection))
                .font(Theme.font(.title))
            Text(L(.diagnosisNoEndpoint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            TextEditor(text: $appState.diagnosisReply)
                .font(Theme.font(.mono))
                .frame(height: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.surface(.panel), lineWidth: 1)
                )
            HStack {
                Button(L(.diagnosisParse)) { appState.parseDiagnosisReply() }
                    .disabled(appState.diagnosisReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // 存进笔记（DOYAH-10）：只存**采纳的结论 + 可复跑取证**，不含结果行数据。
                Button(L(.diagnosisSaveNote)) {
                    Task { await appState.saveDiagnosisNote() }
                }
                .disabled((appState.diagnosisReport?.items.isEmpty ?? true))
                Spacer()
            }
        }
    }

    private func adviceSection(_ report: DiagnosisAdviceReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.diagnosisAdviceSection))
                .font(Theme.font(.title))
            if report.items.isEmpty {
                Text(L(.diagnosisRejectionsSection))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
            ForEach(Array(report.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.s) {
                        Text("●")
                            .foregroundStyle(decisionTone(item.decision))
                        Text(item.conclusion)
                            .font(Theme.font(.body))
                        Spacer()
                        Text(decisionLabel(item.decision))
                            .font(Theme.font(.caption))
                            .foregroundStyle(decisionTone(item.decision))
                    }
                    Text(L(.diagnosisEvidenceSection) + "：" + item.citations.joined(separator: ", "))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                    if let suggested = item.suggestedSQL {
                        Text(suggested)
                            .font(Theme.font(.mono))
                            .textSelection(.enabled)
                        HStack {
                            Button(L(.diagnosisInsertSQL)) {
                                appState.putDiagnosisSQLInEditor(suggested)
                            }
                        }
                    }
                }
                .padding(Spacing.s)
                .background(Theme.surface(.raised))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func rejectionSection(_ report: DiagnosisAdviceReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.diagnosisRejectionsSection))
                .font(Theme.font(.title))
            ForEach(Array(report.rejections.enumerated()), id: \.offset) { _, rejection in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rejection.line)
                        .font(Theme.font(.body))
                    Text(reasonText(rejection.reason))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.danger))
                }
            }
        }
    }

    private func reasonText(_ reason: DiagnosisAdviceReport.Rejection.Reason) -> String {
        switch reason {
        case .missingCitations: return L(.diagnosisRejectedMissing)
        case .unknownCitation(let id): return L(.diagnosisRejectedUnknown, id)
        case .unparsable: return L(.diagnosisRejectedUnparsable)
        }
    }

    private func decisionLabel(_ decision: ExecutionSafety.Decision?) -> String {
        switch decision {
        case .allow: return L(.diagnosisDecisionAllow)
        case .needsConfirmation: return L(.diagnosisDecisionConfirm)
        case .refused: return L(.diagnosisDecisionRefused)
        case nil: return ""
        }
    }

    private func decisionTone(_ decision: ExecutionSafety.Decision?) -> Color {
        switch decision {
        case .allow: return Theme.status(.success)
        case .needsConfirmation: return Theme.status(.warning)
        case .refused: return Theme.status(.danger)
        case nil: return Theme.text(.secondary)
        }
    }
}
