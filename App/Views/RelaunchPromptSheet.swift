import SwiftUI
import DoyahCore

/// 切换语言后提示「系统菜单需要重启才跟随」（NFR-I18N-03）。
///
/// 措辞只说清两件事：界面已经切了；系统菜单为什么没切、怎么才能切。
/// 有未保存页签时额外醒目提示——不能让人为了换个语言丢查询。
struct RelaunchPromptSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L(.relaunchTitle))
                .font(.headline)

            Text(L(.relaunchMessage))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            if appState.dirtyTabCount > 0 {
                Label(
                    L(.relaunchMessageUnsaved, appState.dirtyTabCount),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L(.relaunchLater)) {
                    localization.isRestartPromptPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(L(.relaunchNow)) {
                    Task {
                        do {
                            try await AppRelauncher.relaunch()
                        } catch {
                            // 起不来就别退：把原因说清楚，用户还能继续用当前实例。
                            appState.errorMessage = ErrorPresenter.message(for: error)
                            localization.isRestartPromptPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
