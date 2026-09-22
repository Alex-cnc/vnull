import SwiftUI
import DoyahCore

/// 主窗口底部的终端面板。
///
/// 终端会话（`TerminalModel`）挂在 **App 层**（`@StateObject` 在 `DoyahStudioApp`），
/// 这里只通过 environment 取用。原因：最大化 / 恢复、以及切换语言导致的整树重建
/// 都会重建这个视图，若会话挂在这里，正在跑的 shell（比如一个 dsh 会话）就会被杀掉。
struct BottomPanelView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var terminal: TerminalModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minHeight: 120, idealHeight: 220)
        .background(.background)
        .onAppear {
            terminal.startIfNeeded(columns: terminal.screen.columns, rows: terminal.screen.rows)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(L(.bottomPanelTerminal))
                .font(.caption)
                .bold()

            if !terminal.isRunning {
                Text(L(.terminalStopped))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if let errorText = terminal.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Button {
                terminal.restart(columns: terminal.screen.columns, rows: terminal.screen.rows)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L(.terminalRestart))

            Button {
                appState.isBottomPanelMaximized.toggle()
            } label: {
                Image(systemName: appState.isBottomPanelMaximized
                      ? "rectangle.compress.vertical"
                      : "rectangle.expand.vertical")
            }
            .buttonStyle(.borderless)
            .help(appState.isBottomPanelMaximized ? L(.bottomPanelRestore) : L(.bottomPanelMaximize))

            Button {
                // 收起时同时取消最大化：下次打开回到常规分栏，而不是又占满整屏。
                appState.isBottomPanelMaximized = false
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
        TerminalView(model: terminal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
