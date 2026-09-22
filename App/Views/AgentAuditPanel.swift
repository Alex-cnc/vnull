import SwiftUI
import PostgresClientCore

/// 「审批与审计…」面板（FR-AI-09、NFR-AI-03、NFR-AI-12 联动）。
///
/// 一屏回答四个问题：
/// 1. **有没有等着我批的**：待审批列表（批准只能进审批单里做，避免在列表上闭眼点批准）；
/// 2. **现在放开了多少**：只读模式与白名单可配置，保存走同一份配置持久化；
/// 3. **智能体都干过什么**：审计记录（时间 / 连接 / 语句 / 模型 / 结果状态）可筛选、可清空（二次确认）、可导出；
/// 4. **为什么被拦**：选中记录后展示完整语句与 `AgentGuardrail` 的风险点结论（NFR-AI-12）。
///
/// 导出刻意只保留「选路径」这一件事：内容由 `AgentAuditLog` 生成（导出前已脱敏），
/// 界面不拼一份自己的导出，免得脱敏成了君子协定。
struct AgentAuditPanel: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var filter = AgentAuditFilter.all
    @State private var isClearConfirmPresented = false
    @State private var guardPolicy = AgentGuardPolicy.readOnlyDefault
    @State private var isPolicyLoaded = false
    @State private var isSavingPolicy = false
    @State private var selectedRecordID: UUID?

    /// 应用筛选后的记录；**新的在上**（审计是追加式的，最近的写在最后）。
    private var visibleRecords: [AgentActionRecord] {
        filter.apply(to: appState.agentAuditRecords).reversed()
    }

    private var selectedRecord: AgentActionRecord? {
        guard let selectedRecordID else { return nil }
        return appState.agentAuditRecords.first { $0.id == selectedRecordID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            pendingSection
            policySection
            Divider()
            recordsSection
            detailSection
            footer
        }
        .padding(20)
        .frame(width: 940, height: 790)
        .task {
            // 打开面板时把策略读进来（与配置同源，不在面板里另存一份）。
            if !isPolicyLoaded {
                isPolicyLoaded = true
                guardPolicy = appState.agentGuardPolicy
            }
            await appState.refreshAgentAudit()
        }
        .alert(L(.agentAuditClearConfirmTitle), isPresented: $isClearConfirmPresented) {
            Button(L(.commonCancel), role: .cancel) {}
            Button(L(.agentAuditClear), role: .destructive) {
                Task { await appState.clearAgentAudit() }
            }
        } message: {
            Text(L(.agentAuditClearConfirmMessage))
        }
        // 审批单作为**本面板的子 sheet**弹出：审批只能从「有上下文的面板」里发起
        // （本面板或自然语言面板），因此不挂在 `MainWindow` 上 —— 同一时刻向同一个视图
        // 请求两个 sheet 属于未定义行为，宁可各面板各挂一份。
        .sheet(item: $appState.agentApprovalRequest) { approval in
            AgentApprovalSheet(approval: approval)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            Text(L(.agentAuditTitle))
                .font(.headline)

            Spacer()

            Button(L(.agentAuditRefresh)) {
                Task { await appState.refreshAgentAudit() }
            }
            .disabled(appState.isAgentAuditLoading)

            Button(L(.agentAuditClear)) {
                isClearConfirmPresented = true
            }
            .disabled(appState.agentAuditRecords.isEmpty)

            Menu {
                // 导出格式只有一处清单（`AgentAuditExportFormat.allCases`），
                // 加一种格式不必再改一遍菜单。
                ForEach(AgentAuditExportFormat.allCases, id: \.self) { format in
                    Button(format.text) {
                        Task { await appState.exportAgentAudit(format: format) }
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L(.agentAuditExport))
            .disabled(appState.agentAuditRecords.isEmpty)

            Button(L(.commonClose)) { dismiss() }
        }
    }

    // MARK: - 待审批（FR-AI-09）

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L(.agentApprovalSection))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !appState.pendingAgentApprovals.isEmpty {
                    Text(L(.agentApprovalPendingCount, appState.pendingAgentApprovals.count))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            if appState.pendingAgentApprovals.isEmpty {
                Text(L(.agentApprovalEmpty))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 84, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.pendingAgentApprovals) { approval in
                            pendingRow(approval)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 84)
            }
        }
    }

    /// 待审批行：**只给「查看…」与「拒绝」**。
    ///
    /// 批准必须进审批单里做 —— 那里才摊开了完整语句与风险点；
    /// 在列表上直接放「批准」按钮，等于鼓励不看内容就点。
    private func pendingRow(_ approval: AgentApproval) -> some View {
        HStack(spacing: 8) {
            Image(systemName: approval.record.outcome.symbolName)
                .foregroundStyle(approval.record.risk.tint)

            Text("\(approval.record.statementKind.text) · \(approval.record.risk.text)")
                .font(.caption)

            Text(AgentAuditPresentation.statementSummary(approval.record.sql))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button(L(.agentApprovalReview)) {
                appState.presentAgentApproval(approval)
            }
            .font(.caption)

            Button(L(.agentApprovalReject), role: .destructive) {
                Task { await appState.rejectAgentAction(id: approval.id) }
            }
            .font(.caption)
        }
    }

    // MARK: - 只读模式与白名单（FR-AI-09）

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.agentGuardSection))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(L(.agentReadOnlyMode), isOn: $guardPolicy.readOnly)

            Text(L(.agentReadOnlyHint))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(L(.agentAllowlist))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            HStack(spacing: 14) {
                // 只列「可以进白名单」的类别：`unknown` 永远需要审批（见 Core 的 allowlistableKinds）。
                ForEach(AgentGuardPolicy.allowlistableKinds, id: \.self) { kind in
                    Toggle(kind.text, isOn: binding(for: kind))
                        .font(.caption)
                }
            }

            Text(L(.agentAllowlistHint))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !guardPolicy.readOnly {
                Label(L(.agentGuardWritesWarning), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L(.agentGuardSave)) { savePolicy() }
                    .disabled(isSavingPolicy)
            }
        }
    }

    private func binding(for kind: AgentStatementKind) -> Binding<Bool> {
        Binding(
            get: { guardPolicy.effectiveAllowedKinds.contains(kind) },
            set: { isOn in
                var kinds = guardPolicy.effectiveAllowedKinds
                if isOn {
                    kinds.insert(kind)
                } else {
                    kinds.remove(kind)
                }
                guardPolicy.allowedKinds = kinds
            }
        )
    }

    private func savePolicy() {
        isSavingPolicy = true
        Task {
            await appState.saveAgentGuardPolicy(guardPolicy)
            isSavingPolicy = false
        }
    }

    // MARK: - 审计记录（NFR-AI-03）

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L(.agentAuditRecords))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(L(.agentAuditRecordsCount, visibleRecords.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("", selection: $filter.outcome) {
                    Text(L(.agentAuditFilterAll)).tag(AgentActionRecord.Outcome?.none)
                    ForEach(AgentActionRecord.Outcome.allCases, id: \.self) { outcome in
                        Text(outcome.text).tag(AgentActionRecord.Outcome?.some(outcome))
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Picker("", selection: $filter.connectionName) {
                    Text(L(.agentAuditFilterAll)).tag(String?.none)
                    ForEach(AgentAuditFilter.connectionNames(in: appState.agentAuditRecords), id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                TextField(
                    L(.agentAuditFilterSearch),
                    text: $filter.searchText,
                    prompt: Text(L(.agentAuditFilterSearch))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }

            columnHeader
            recordsList
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(L(.agentAuditColumnTime)).frame(width: 140, alignment: .leading)
            Text(L(.agentAuditColumnConnection)).frame(width: 150, alignment: .leading)
            Text(L(.agentAuditColumnStatement)).frame(maxWidth: .infinity, alignment: .leading)
            Text(L(.agentAuditColumnModel)).frame(width: 110, alignment: .leading)
            Text(L(.agentAuditColumnOutcome)).frame(width: 120, alignment: .leading)
            Text("").frame(width: 18)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var recordsList: some View {
        if appState.agentAuditRecords.isEmpty {
            emptyHint(L(.agentAuditEmpty))
        } else if visibleRecords.isEmpty {
            emptyHint(L(.agentAuditFilteredEmpty))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleRecords) { record in
                        recordRow(record)
                    }
                }
            }
            .frame(minHeight: 150)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
    }

    private func recordRow(_ record: AgentActionRecord) -> some View {
        let isSelected = record.id == selectedRecordID
        return Button {
            selectedRecordID = record.id
        } label: {
            HStack(spacing: 8) {
                Text(AgentAuditPresentation.timestampText(record.timestamp))
                    .frame(width: 140, alignment: .leading)

                Text(AgentAuditPresentation.connectionText(record))
                    .frame(width: 150, alignment: .leading)
                    .lineLimit(1)

                Text("\(record.statementKind.text) · \(AgentAuditPresentation.statementSummary(record.sql))")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(AgentAuditPresentation.modelText(record))
                    .frame(width: 110, alignment: .leading)
                    .lineLimit(1)

                Label(record.outcome.text, systemImage: record.outcome.symbolName)
                    .foregroundStyle(record.outcome.tint)
                    .frame(width: 120, alignment: .leading)
                    .lineLimit(1)

                // 高危动作标红：一眼能看出「这条是被护栏拦下的」。
                Image(systemName: AgentAuditPresentation.isHighRisk(record) ? "exclamationmark.shield.fill" : "")
                    .foregroundStyle(record.risk.tint)
                    .frame(width: 18)
            }
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AgentAuditPresentation.findingsText(record).isEmpty
              ? L(.agentAuditGuardNone)
              : AgentAuditPresentation.findingsText(record))
    }

    // MARK: - 选中记录详情（NFR-AI-12：为什么被拦）

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.agentAuditColumnGuard))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let record = selectedRecord {
                // 护栏结论：让「为什么被拦」在界面上看得见，而不是只有一条「失败了」。
                let findings = AgentAuditPresentation.findingsText(record)
                Label(
                    findings.isEmpty ? L(.agentAuditGuardNone) : findings,
                    systemImage: findings.isEmpty ? "checkmark.shield" : "exclamationmark.shield.fill"
                )
                .font(.caption2)
                .foregroundStyle(findings.isEmpty ? .secondary : record.risk.tint)
                .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.sql)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let detail = record.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 96)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(L(.agentAuditSelectHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 96, alignment: .topLeading)
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = appState.agentAuditError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = appState.agentAuditMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(L(.agentAuditRedactedHint))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
