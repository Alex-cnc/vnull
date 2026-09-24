import SwiftUI
import DoyahCore

/// 菜单栏命令（NFR-I18N-03）。
///
/// **为什么单独抽成一个 `Commands` 结构体，而不是直接写在 `DoyahStudioApp.commands {}` 里**
///
/// SwiftUI 的 `.commands {}` 闭包**只在场景建立时求值一次**，闭包内读取 `ObservableObject`
/// 不会与它建立观察关系（Apple 开发者论坛 667768 / 671721 记载的已知限制）。
/// 这正是 ADR-09 的盲区：根视图 `.id(language)` 只管视图树，**管不到菜单栏**。
/// 后果：切换语言后窗口内容立刻变，菜单栏却停在启动时的语言。
///
/// 解法分两层：
/// 1. 本结构体自己持有 `@ObservedObject`，成为观察根 —— 菜单**标题**（`CommandMenu`）
///    随之重建。实测：切换后 `智能体` → `Agent`、`语言` → `Language` 会立即变。
/// 2. 菜单里的**叶子项**（`Button` / `CommandGroup` 项）SwiftUI 不会重建，会停在旧语言。
///    这一半由 `MainMenuLocalizer` 在语言切换后直接改 `NSMenuItem.title` 补齐
///    （见 `Core/MenuLocalization.swift` 的说明与实测记录）。
struct DoyahStudioCommands: Commands {
    /// App 侧的共享状态（`App` 持有 `@StateObject`，这里只借用同一个实例）。
    ///
    /// 刻意用 `let` 而不是 `@ObservedObject`：菜单项目前只**调用**方法、
    /// 不根据 `appState` 派生文案或可用性；订阅它只会让结果集流式刷新
    /// 顺带把菜单图反复置脏，得不偿失。将来若要按状态禁用菜单项，再改成 `@ObservedObject`。
    let appState: AppState

    /// 语言：**必须由命令结构体自己观察**，菜单标题才会跟着切换。
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L(.menuNewQuery)) {
                appState.newQueryTab()
            }
            .keyboardShortcut("t", modifiers: [.command])

            // 浏览器页签与 SQL 页签同级（FR-EDIT-34），所以入口也该在「文件 · 新建」这一组里，
            // 而不是躲在「智能体」菜单下 —— 它跟智能体没有任何关系。
            Button(L(.menuNewBrowserTab)) {
                appState.openBrowserTab()
            }
            .keyboardShortcut(AppShortcut.newBrowserTab.key, modifiers: AppShortcut.newBrowserTab.modifiers)
        }

        CommandGroup(after: .newItem) {
            Button(L(.archiveTitle)) {
                appState.isSQLArchivePresented = true
            }
            .keyboardShortcut(AppShortcut.archive.key, modifiers: AppShortcut.archive.modifiers)
        }

        CommandMenu(L(.menuAgent)) {
            Button(L(.menuAgentSettings)) {
                appState.isAgentSettingsPresented = true
            }
            .keyboardShortcut(",", modifiers: [.command, .shift])

            Divider()

            Button(L(.menuAgentGenerateSQL)) {
                appState.isAgentSQLPresented = true
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button(L(.menuDataTask)) {
                appState.isDataTaskPresented = true
            }
            .keyboardShortcut(AppShortcut.dataTask.key, modifiers: AppShortcut.dataTask.modifiers)

            Divider()

            Button(L(.menuAgentAudit)) {
                appState.isAgentAuditPresented = true
            }
            .keyboardShortcut(AppShortcut.agentAudit.key, modifiers: AppShortcut.agentAudit.modifiers)

            Button(L(.menuEgressLog)) {
                appState.isEgressLogPresented = true
            }
            .keyboardShortcut(AppShortcut.egressLog.key, modifiers: AppShortcut.egressLog.modifiers)
        }

        // 「显示」菜单：下方面板（结果 / 问题 / 输出 / 终端 / 调试控制台）。
        CommandGroup(after: .sidebar) {
            // 与活动栏一一对应：切换右侧面板看哪个视图（⌘1 / ⌘2 是通用习惯）
            ForEach(ActivityBarItem.allCases) { item in
                Button(L(item.menuKey)) {
                    appState.selectedActivityItem = item
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(item.shortcutIndex)")),
                    modifiers: [.command]
                )
            }

            Divider()

            Button(L(.menuAppearance)) {
                appState.isAppearancePresented = true
            }

            Button(L(.menuConnectionSettings)) {
                appState.isConnectionSettingsPresented = true
            }

            Divider()

            Button(L(.lowerPaneToggle)) {
                appState.isLowerPaneVisible.toggle()
            }
            .keyboardShortcut(AppShortcut.terminal.key, modifiers: AppShortcut.terminal.modifiers)
        }

        CommandMenu(L(.menuLanguage)) {
            // 用 `Toggle` 而不是 `Picker`：在 macOS 菜单里 `Toggle` 就是标准的「勾选项」，
            // 勾选状态由观察根驱动重建，不依赖 `Picker` 在命令菜单里的选择态刷新。
            ForEach(AppLanguage.allCases, id: \.self) { language in
                Toggle(language.displayName, isOn: isCurrent(language))
            }
        }
    }

    /// 「当前语言」这个勾选项的绑定。
    ///
    /// 取消勾选（`set(false)`）是无意义的：点了已选中的那项不该把语言清空，
    /// 所以只在 `true` 时才真正切换。
    private func isCurrent(_ language: AppLanguage) -> Binding<Bool> {
        Binding(
            get: { localization.language == language },
            set: { isOn in
                if isOn { localization.setLanguage(language) }
            }
        )
    }
}
