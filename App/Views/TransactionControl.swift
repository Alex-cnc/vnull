import SwiftUI
import DoyahCore

/// 事务控件（FR-EXEC-15）：自动提交 / 手工事务开关 + 提交 / 回滚 + **进行中状态**。
///
/// 为什么要常显状态而不是只放两个按钮：手工事务最危险的状态是「有一个开着的事务，
/// 而用户已经忘了」。因此只要事务开着，这里就出现一枚带条数的徽标（失败时是红色警示），
/// 且**提交 / 回滚按钮一直可见** —— 忘了它就意味着忘了一次未提交的写入。
struct TransactionControl: View {
    @EnvironmentObject private var appState: AppState
    let tab: QueryTab

    private var session: TransactionSession? { appState.activeTransactionSession }

    var body: some View {
        if let session {
            HStack(spacing: Spacing.xs) {
                Picker("", selection: Binding(
                    get: { session.mode },
                    set: { newMode in
                        Task { await appState.setTransactionMode(newMode, for: tab.id) }
                    }
                )) {
                    Text(L(.transactionModeAuto)).tag(TransactionMode.autoCommit)
                    Text(L(.transactionModeManual)).tag(TransactionMode.manual)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 168)
                .help(L(.transactionHelp))

                if session.mode.isManual {
                    Button(L(.transactionCommit)) {
                        Task { await appState.commitTransaction(for: tab.id) }
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.font(.caption))
                    // 只有「事务开着且没失败」才谈得上提交。
                    .disabled(!isCommitAvailable(session.phase))

                    Button(L(.transactionRollback)) {
                        Task { await appState.rollbackTransaction(for: tab.id) }
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.font(.caption))
                    .disabled(!session.phase.isOpen)

                    phaseBadge(session.phase)
                }
            }
        }
    }

    private func isCommitAvailable(_ phase: TransactionPhase) -> Bool {
        if case .open = phase { return true }
        return false
    }

    @ViewBuilder
    private func phaseBadge(_ phase: TransactionPhase) -> some View {
        switch phase {
        case .idle:
            EmptyView()

        case .open(let statementCount):
            badge(
                text: L(.transactionOpenBadge, statementCount),
                tone: Theme.status(.warning),
                symbol: "arrow.triangle.2.circlepath"
            )

        case .aborted:
            // 失败的事务只接受回滚 —— 徽标直接这么写，用户不必去翻日志。
            badge(
                text: L(.transactionAbortedBadge),
                tone: Theme.status(.danger),
                symbol: "exclamationmark.triangle"
            )
        }
    }

    private func badge(text: String, tone: Color, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(Theme.font(.caption))
            .foregroundStyle(tone)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.hair)
            .background(
                RoundedRectangle(cornerRadius: Radius.badge)
                    .fill(tone.opacity(Theme.isDarkAppearance ? Overlay.Zebra.darkAlpha : Overlay.Zebra.lightAlpha))
            )
            .fixedSize()
    }
}
