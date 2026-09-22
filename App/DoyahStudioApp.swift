import SwiftUI
import DoyahCore

@main
struct DoyahStudioApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var localization = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appState)
                .environmentObject(localization)
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
