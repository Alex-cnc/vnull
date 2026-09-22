import SwiftUI
import DoyahCore

/// 「由规格说明生成任务定义」子面板（FR-AI-05 的自然语言入口）。
///
/// 与「自然语言 → SQL」面板同一套做法，三条边界照搬：
/// 1. **先看再发**：把将要外发的提示词全文摊在这里，用户点生成之前就知道会发什么（NFR-AI-01）；
/// 2. **不执行、不保存**：生成结果只回填到任务编辑器，保存与执行仍由人决定；
/// 3. **护栏可见**：写语句的 `AgentGuardrail` 判定与定义校验问题都摆出来（NFR-AI-12）。
struct DataTaskSpecSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    /// 生成并「应用」后的定义（由父面板放进编辑器）。
    var onApply: (DataTaskDefinition) -> Void

    @State private var specs = ""
    @State private var hints = ""
    @State private var includeTables = true
    @State private var isGenerating = false
    @State private var errorText: String?
    @State private var schema = AgentSQLGenerator.SchemaSummary()
    @State private var payloadPreview = ""
    @State private var payloadNote: String?
    @State private var result: DataTaskSpecGenerator.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L(.dataTaskSpecTitle))
                    .font(.headline)
                Spacer()
                Button(L(.commonClose)) { dismiss() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L(.dataTaskSpecInput))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $specs)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                TextField(L(.dataTaskSpecHints), text: $hints)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Toggle(L(.agentSQLIncludeTables), isOn: $includeTables)
                    .font(.caption)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L(.dataTaskSpecPayload))
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

            resultSection

            HStack {
                Text(L(.dataTaskSpecNotExecuted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if result != nil {
                    Button(L(.dataTaskSpecApply)) {
                        if let definition = result?.definition {
                            onApply(definition)
                            dismiss()
                        }
                    }
                }
                Button(L(.dataTaskSpecGenerate)) {
                    Task { await generate() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isGenerating || specs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 820, height: 720)
        .task { await loadSchema() }
        // 只有「要不要带表清单」需要重新查一次 schema；specs / 额外约束只是本地文本，
        // 直接重建预览文本即可 —— 否则每敲一个字都会去数据库查一遍。
        .onChange(of: includeTables) { _, _ in Task { await loadSchema() } }
        .onChange(of: specs) { _, _ in rebuildPayload() }
        .onChange(of: hints) { _, _ in rebuildPayload() }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let result {
            VStack(alignment: .leading, spacing: 4) {
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(L(.dataTaskSpecHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // 定义校验问题：生成的草案哪里不能用，逐条列出。
                ForEach(result.issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if result.issues.isEmpty {
                    Label(L(.dataTaskNoIssues), systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                if let assessment = result.guardAssessment {
                    Label(
                        L(.dataTaskGuardVerdict) + "：" + assessment.message,
                        systemImage: assessment.verdict.isAllowed ? "checkmark.shield" : "exclamationmark.shield.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(assessment.verdict.isAllowed ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let explanation = result.explanation {
                    Text(explanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        } else if let errorText {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 取一次 schema 摘要（只有「要不要带表清单」变化时才需要）。
    private func loadSchema() async {
        do {
            schema = try await appState.agentSchemaSummary(includeTableList: includeTables)
            payloadNote = (includeTables && schema.tables.isEmpty) ? L(.agentSQLNoTables) : nil
        } catch {
            schema = .init()
            payloadNote = L(.agentSQLNoTables)
        }
        rebuildPayload()
    }

    /// 组装「将要外发的内容」——与实际请求共用同一套提示词函数（预览即实发）。
    private func rebuildPayload() {
        let prompts = DataTaskSpecGenerator.prompts(
            for: .init(
                specs: specs.isEmpty ? L(.dataTaskSpecInput) : specs,
                schema: schema,
                hints: hints.isEmpty ? nil : hints
            )
        )
        payloadPreview = prompts.system + "\n\n———\n\n" + prompts.user
    }

    private func generate() async {
        let trimmed = specs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = L(.dataTaskSpecNoInput)
            return
        }

        isGenerating = true
        errorText = nil
        defer { isGenerating = false }

        do {
            result = try await appState.generateDataTaskSpec(
                specs: trimmed,
                schema: schema,
                hints: hints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hints
            )
        } catch let error as LLMError {
            if case .disabled = error {
                errorText = L(.dataTaskSpecDisabled)
            } else {
                errorText = L(.dataTaskSpecFailed, ErrorPresenter.message(for: error))
            }
        } catch {
            errorText = L(.dataTaskSpecFailed, ErrorPresenter.message(for: error))
        }
    }
}
