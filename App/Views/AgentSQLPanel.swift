import SwiftUI
import PostgresClientCore

/// 「自然语言 → SQL」面板（FR-AI-02）。
///
/// 三条设计原则直接对应需求与验收要点：
/// 1. **结果不自动执行**：产物只进新页签的编辑器，面板底部也写明这一点；
/// 2. **外发可复核**（NFR-AI-01 / NFR-AI-05）：把「将要外发的全文」摊在面板上，
///    包括被包成 `<untrusted-data>` 的对象注释，用户点生成之前就知道会发什么；
/// 3. **不黑箱**：同时展示模型原文说明与 `AgentGuardrail` 的判定（只读模式下写操作会被拒）。
struct AgentSQLPanel: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var instruction = ""
    @State private var includeTables = true
    @State private var includeStatement = true
    @State private var isGenerating = false
    @State private var errorText: String?
    @State private var result: AgentSQLGenerator.Result?
    @State private var editableSQL = ""
    @State private var payloadPreview = ""
    @State private var payloadNote: String?
    /// 已经提交过的语句：同一条不重复入队（改了内容就能再提交）。
    @State private var submittedSQL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L(.agentSQLTitle))
                    .font(.headline)
                Spacer()
                Button(L(.commonClose)) { dismiss() }
            }

            instructionSection
            payloadSection
            resultSection

            HStack {
                Text(L(.agentSQLNotExecuted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()

                if result != nil {
                    Button(L(.agentSQLCopy)) {
                        copyToPasteboard(editableSQL)
                        appState.statusMessage = L(.agentSQLCopied)
                    }
                    Button(L(.agentSQLInsertNewTab)) {
                        appState.openGeneratedSQLInNewTab(editableSQL)
                        dismiss()
                    }
                    // 提交审批（FR-AI-09）：写操作 / DDL 必须逐次批准；只读查询无需审批，
                    // 但也**不会被自动执行** —— 依旧只放进新页签。
                    Button(L(.agentSQLSubmit)) {
                        Task { await submitForApproval() }
                    }
                    .disabled(submittedSQL == editableSQL)
                }

                Button(L(.agentSQLGenerate)) {
                    Task { await generate() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isGenerating || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760, height: 640)
        .task { await refreshPayload() }
        .onChange(of: includeTables) { _, _ in Task { await refreshPayload() } }
        .onChange(of: includeStatement) { _, _ in Task { await refreshPayload() } }
        // 审批单作为本面板的子 sheet 弹出：面板**不关闭**，用户决定后再自己关，
        // 免得「父面板一关，子审批单被一起撕掉」。
        .sheet(item: $appState.agentApprovalRequest) { approval in
            AgentApprovalSheet(approval: approval)
        }
    }

    // MARK: - 需求输入

    private var instructionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.agentSQLInstruction))
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(L(.agentSQLInstructionPlaceholder), text: $instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            HStack(spacing: 16) {
                Toggle(L(.agentSQLIncludeTables), isOn: $includeTables)
                Toggle(L(.agentSQLIncludeStatement), isOn: $includeStatement)
            }
            .font(.caption)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 外发内容

    private var payloadSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L(.agentSQLPayload))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let payloadNote {
                    Text(payloadNote)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            ScrollView {
                Text(payloadPreview)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(L(.agentSQLPayloadNote))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private var resultSection: some View {
        if let result {
            VStack(alignment: .leading, spacing: 6) {
                Text(L(.agentSQLResult))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $editableSQL)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: result.guardAssessment.verdict.isAllowed ? "checkmark.shield" : "exclamationmark.shield.fill")
                        .foregroundStyle(result.guardAssessment.verdict.isAllowed ? .green : .orange)
                    Text("\(L(.agentSQLGuard))：\(result.guardAssessment.message)")
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let explanation = result.explanation {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(.agentSQLExplanation))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(explanation)
                            .font(.caption2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - 行为

    /// 组装「将要外发的内容」预览 —— 与实际请求走同一套提示词函数，避免预览与实发不一致。
    private func refreshPayload() async {
        payloadNote = nil
        do {
            let schema = try await appState.agentSchemaSummary(includeTableList: includeTables)
            if includeTables, schema.tables.isEmpty {
                payloadNote = L(.agentSQLNoTables)
            }
            let prompts = AgentSQLGenerator.prompts(
                for: .init(
                    instruction: instruction.isEmpty ? L(.agentSQLInstructionPlaceholder) : instruction,
                    schema: schema,
                    currentStatement: includeStatement ? appState.selectedTab?.sql : nil
                )
            )
            payloadPreview = prompts.system + "\n\n———\n\n" + prompts.user
        } catch {
            payloadPreview = ErrorPresenter.message(for: error)
            payloadNote = L(.agentSQLNoTables)
        }
    }

    private func generate() async {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = L(.agentSQLNoInstruction)
            return
        }

        isGenerating = true
        errorText = nil
        defer { isGenerating = false }

        do {
            let schema = try await appState.agentSchemaSummary(includeTableList: includeTables)
            let generated = try await appState.generateAgentSQL(
                instruction: trimmed,
                schema: schema,
                currentStatement: includeStatement ? appState.selectedTab?.sql : nil
            )
            result = generated
            editableSQL = generated.sql
        } catch {
            errorText = L(.agentSQLFailed, ErrorPresenter.message(for: error))
        }
    }

    /// 把生成结果提交给审批闸门（FR-AI-09）。
    ///
    /// 三种去向都由 `AppState` 的判定决定，面板不做二次判断：
    /// - 被护栏拒绝（只读模式下的写操作）：留在面板上给出可读原因，不入队、不执行；
    /// - 需要审批：入待审批队列并弹出审批单，**批准之前不会执行**；
    /// - 无需审批（只读查询 / 白名单类别）：放进新页签，**不自动执行**。
    private func submitForApproval() async {
        let sql = editableSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }

        let submission = await appState.submitAgentAction(sql)
        switch submission {
        case .denied:
            errorText = L(.agentSQLDenied, submission.message)
        case .awaitingApproval:
            // 面板保持打开，审批单会叠在上面弹出（见 body 上的 `.sheet(item:)`）。
            submittedSQL = sql
            errorText = nil
            appState.statusMessage = L(.agentSQLSubmittedPending)
        case .approved:
            submittedSQL = sql
            errorText = nil
            appState.openGeneratedSQLInNewTab(sql)
            appState.statusMessage = L(.agentSQLSubmittedAuto)
            dismiss()
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
