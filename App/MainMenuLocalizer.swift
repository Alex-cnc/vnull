import AppKit
import DoyahCore

/// 语言切换后把**菜单栏**改成目标语言（NFR-I18N-03）。
///
/// SwiftUI 只重建 `.commands` 里的菜单标题，菜单里的叶子项不会刷新
/// （实测记录见 `DoyahCore.MenuLocalization` 的注释）。这里遍历 `NSApp.mainMenu`，
/// 把自有菜单项的标题逐个改成目标语言。
///
/// 为什么不干脆整棵菜单自己用 AppKit 建：那样要放弃 SwiftUI 的
/// `.keyboardShortcut` / `CommandGroup(replacing:)` 等系统集成，
/// 还要自己重造「文件 / 编辑 / 窗口」这些系统菜单，代价远大于收益。
enum MainMenuLocalizer {

    /// 按目标语言刷新菜单栏。
    ///
    /// 入口刻意保持 `nonisolated`：调用方 `LocalizationManager` 是个普通 `ObservableObject`，
    /// 不该为了改菜单栏被强制成主 actor；AppKit 那一段在 `MainActor` 上执行。
    nonisolated static func refresh(to language: AppLanguage) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { apply(language) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { apply(language) } }
        }
    }

    @MainActor
    private static func apply(_ language: AppLanguage) {
        guard let mainMenu = NSApp.mainMenu else { return }
        retitle(mainMenu, to: language)
    }

    @MainActor
    private static func retitle(_ menu: NSMenu, to language: AppLanguage) {
        for item in menu.items {
            if let retitled = MenuLocalization.retitled(item.title, to: language) {
                item.title = retitled
            }
            if let submenu = item.submenu {
                retitle(submenu, to: language)
            }
        }
    }
}
