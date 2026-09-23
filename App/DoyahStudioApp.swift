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
        // **单实例保护**：同一个 bundle 通常只允许一个进程在跑。
        //
        // 但有一个例外必须放行：**重启时被旧实例主动拉起来的那一个**。
        // 否则就会变成"新实例把旧的激活、自己退出，旧的随后也退出" —— 用户点重启后
        // 什么都不会发生（这正是 R-36 第二版踩的坑）。
        // 接替启动优先判断：它会等旧实例真的退出，并把交接单消费掉。
        let isTakeover = AppRelauncher.claimHandoffIfPresent()
        if !isTakeover, let existing = Self.otherRunningInstance() {
            existing.activate()
            exit(0)
        }
        MainMenuLocalizer.start()
    }

    /// 找出**已经在本机运行的另一个自己**（不含当前进程）。
    private static func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != currentPID }
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
                        // 归档目录跟随工作区（未单独指定时）—— 变了就重新判定一次状态
                        Task { await appState.refreshSQLArchiveStatus() }
                    }
                    appState.workspacePathProvider = { [workspace] in workspace.rootPath }
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


