import SwiftUI
import PostgresClientCore

@main
struct PostgresClientApp: App {
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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L(.menuNewQuery)) {
                    appState.newQueryTab()
                }
                .keyboardShortcut("t", modifiers: [.command])
            }

            CommandMenu(L(.menuLanguage)) {
                Picker(L(.menuLanguage), selection: Binding(
                    get: { localization.language },
                    set: { localization.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }
        }
    }
}
