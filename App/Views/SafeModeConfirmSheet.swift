import SwiftUI
import PostgresClientCore

/// 高危语句保护确认弹窗（FR-EXEC-16）。
///
/// 刻意把风险原因和涉事语句并排摊开：只说「有风险」等于什么都没说，
/// 用户会养成闭眼点「继续」的习惯；能一眼看到「是这条 DELETE 没有条件」才有意义。
struct SafeModeConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let pending: PendingExecution

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L(.safetyConfirmTitle), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(L(.safetyConfirmMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(pending.reasons, id: \.self) { reason in
                    Text("· \(reason)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if case .needsConfirmation(_, _, let statements) = pending.decision, !statements.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(statements, id: \.self) { statement in
                            Text(statement)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()

                Button(L(.safetyConfirmCancel)) {
                    appState.cancelPendingExecution()
                    dismiss()
                }

                Button(L(.safetyConfirmRun), role: .destructive) {
                    Task { await appState.confirmPendingExecution() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
