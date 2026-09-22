import SwiftUI
import DoyahCore

/// 主窗口底部的面板（目前只承载「终端」，也是后续诊断 / 日志的落点）。
///
/// **当前状态：骨架**。终端**内容**刻意留空，因为「沙箱内跑什么」是本工程
/// 尚未定稿的高风险决策（SRS R-18 / T-38）：实测沙箱版 App 能起 `/bin/zsh`，
/// 但子进程继承沙箱——`$HOME` 变成 App 容器、`ls /Users` 直接
/// `Operation not permitted`，`psql` / `pg_dump` 也不在 PATH 里。
/// 所以在选型定下来之前不写死内容，免得做错方向。
struct BottomPanelView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            placeholder
        }
        .frame(minHeight: 120, idealHeight: 200)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(L(.bottomPanelTerminal))
                .font(.caption)
                .bold()
            Spacer()
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

    private var placeholder: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(L(.bottomPanelPending))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(12)
    }
}
