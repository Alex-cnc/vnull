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
                    // **先把面板收起来再重启**：模态面板还开着时 `NSApp.terminate` 可能被挡住，
                    // 而"旧的没退、新的已经起来"正是用户报的那个现象。留一拍让面板真的收起。
                    localization.isRestartPromptPresented = false
                    Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        do {
                            try await AppRelauncher.relaunch(dirtyTabCount: appState.dirtyTabCount)
                        } catch {
                            // 退不掉（还有未保存内容）就别硬退：把原因说清楚，用户还能继续用当前实例。
                            appState.errorMessage = ErrorPresenter.message(for: error)
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
