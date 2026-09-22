import SwiftUI
import DoyahCore

/// 执行计划面板（FR-DIAG-01）。
///
/// 三件事按需求来：
/// 1. **计划树**：按解析出的层级缩进展示节点、代价、估算行数、实际耗时与循环次数，
///    全表扫描（sequential scan）高亮 —— 一眼看出瓶颈在哪；
/// 2. **摘要**：节点数、规划 / 执行耗时、全表扫描处数、最慢节点（复用 Core 的 `summaryLines`）；
/// 3. **ANALYZE 的醒目提示**：它会**真正执行**语句（含写操作），所以开关旁边常驻警告，
///    而且默认关闭 —— 不能让人以为"看一眼计划"是只读操作。
struct ExecutionPlanPanel: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let tabID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            options
            if appState.planRunAnalyze {
                Label(L(.planAnalyzeWarning), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(20)
        .frame(width: 720, height: 620)
    }

    // MARK: - 头部与选项

    private var header: some View {
        HStack(spacing: 8) {
            Text(L(.planTitle))
                .font(.headline)

            if appState.executionPlanIsLoading {
                ProgressView().controlSize(.small)
            }

            Spacer()

            Button(L(.planRun)) {
                Task { await appState.runExecutionPlan(for: tabID) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(appState.executionPlanIsLoading)

            Button(L(.commonClose)) { dismiss() }
        }
    }

    private var options: some View {
        HStack(spacing: 16) {
            Toggle(L(.planAnalyze), isOn: $appState.planRunAnalyze)
                .font(.caption)
            Toggle(L(.planBuffers), isOn: $appState.planIncludeBuffers)
                .font(.caption)
            Toggle(L(.planFormatJSON), isOn: $appState.planUseJSON)
                .font(.caption)
                .disabled(appState.selectedConnection?.dbType != .postgresql)
            Spacer()
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let error = appState.executionPlanError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let plan = appState.executionPlan, !plan.isEmpty {
            summarySection(plan)
            treeSection(plan)
            rawSection(plan)
        } else if !appState.executionPlanIsLoading && appState.executionPlanError == nil {
            Text(L(.planEmpty))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func summarySection(_ plan: ExplainPlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L(.planSummary))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(plan.summaryLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func treeSection(_ plan: ExplainPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.planTree))
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(plan.nodes) { node in
                        nodeRow(node)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func nodeRow(_ node: ExplainPlanNode) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(node.label)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(node.depth == 0 ? .semibold : .regular)
                .foregroundStyle(node.isSequentialScan ? .orange : .primary)

            if node.isSequentialScan {
                Text(L(.planSequentialScan))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text(node.displayDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.leading, CGFloat(node.depth) * 14)
    }

    private func rawSection(_ plan: ExplainPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.planRaw))
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(plan.rawText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
