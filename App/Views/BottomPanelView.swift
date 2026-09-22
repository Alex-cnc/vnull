import SwiftUI
import DoyahCore

/// 主窗口底部的终端面板。
///
/// `@StateObject` 持有 `TerminalModel`：语言切换会让根视图按 `.id(language)` 整树重建，
/// 但 `@StateObject` 的生命周期跟着视图身份走——所以切换语言会把 shell 重启一次。
/// 这是可接受的（会话本来也不跨重启），但别把它当成"持久会话"。
struct BottomPanelView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = TerminalModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minHeight: 120, idealHeight: 220)
        .background(.background)
        .onAppear {
            model.startIfNeeded(columns: model.screen.columns, rows: model.screen.rows)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(L(.bottomPanelTerminal))
                .font(.caption)
                .bold()

            if !model.isRunning {
                Text(L(.terminalStopped))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if let errorText = model.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Button {
                model.restart(columns: model.screen.columns, rows: model.screen.rows)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L(.terminalRestart))

            Button {
                appState.isBottomPanelVisible = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help(L(.bottomPanelHide))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var content: some View {
        TerminalView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
