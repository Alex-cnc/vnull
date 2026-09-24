import SwiftUI
import DoyahCore

/// 高危语句保护确认弹窗（FR-EXEC-16）。
///
/// 刻意把风险原因和涉事语句并排摊开：只说「有风险」等于什么都没说，
/// 用户会养成闭眼点「继续」的习惯；能一眼看到「是这条 DELETE 没有条件」才有意义。
struct SafeModeConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 确认弹窗的**唯一内容来源**：风险原因 + 涉事语句。
    ///
    /// 参数化（而不是直接吃 `PendingExecution`）是为了让**同一条闸门**服务所有入口：
    /// 编辑器里的执行走 `AppState.pendingExecution`，服务器级对象写操作走面板自己的
    /// 待确认项 —— 两边弹的是同一张弹窗、说的是同一批理由，不各写一套 UI。
    let reasons: [String]
    let statements: [String]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L(.safetyConfirmTitle), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(L(.safetyConfirmMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(reasons, id: \.self) { reason in
                    Text("· \(reason)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !statements.isEmpty {
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
                    onCancel()
                    dismiss()
                }

                Button(L(.safetyConfirmRun), role: .destructive) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
