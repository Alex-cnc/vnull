import SwiftUI
import DoyahCore

@main
struct DoyahStudioApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var localization = LocalizationManager.shared
    /// 终端会话放在 App 层而不是面板里：最大化 / 恢复、以及切换语言导致的整树重建
    /// 都不该把正在跑的 shell（比如一个 dsh 会话）杀掉。
    @StateObject private var terminal = TerminalModel()
    /// 强调色（FR-EDIT-33）：可配置，通过根视图 `.tint` 下发到所有系统控件。
    @StateObject private var accent = AccentManager.shared
    /// 工作区（FR-EDIT-32）：终端启动目录等既有占位都以它为准。
    @StateObject private var workspace = WorkspaceStore.shared

    init() {
        MainMenuLocalizer.start()
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appState)
                .environmentObject(localization)
                .environmentObject(terminal)
                .environmentObject(accent)
                .environmentObject(workspace)
                .task {
                    // 工作区 → 终端启动目录：把工作区路径交给终端（它只在启动那一刻读）。
                    workspace.onWorkspaceChanged = { [terminal] path in
                        terminal.workspacePath = path
                    }
                    await workspace.load()
                }
                .tint(accent.accentColor)
                .frame(minWidth: 1_100, minHeight: 700)
                // 语言切换时整棵视图树重建，保证所有文案立即刷新。
                .id(localization.language)
        }
        .windowStyle(.titleBar)
        // 菜单栏命令放进 `DoyahStudioCommands`：`.commands {}` 闭包只在场景建立时求值一次，
        // 直接写在这里会让语言切换后**菜单栏不刷新**（见该文件注释与 NFR-I18N-03）。
        .commands {
            DoyahStudioCommands(appState: appState)
        }
    }
}
