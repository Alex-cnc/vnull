import AppKit
import DoyahCore

/// 菜单栏的语言自愈（NFR-I18N-03）。
///
/// **为什么需要「自愈」而不是只在切换时改一次**
///
/// SwiftUI 只重建 `.commands` 里的菜单标题，菜单里的叶子项不会随语言刷新
/// （实测记录见 `DoyahCore.MenuLocalization` 的注释）。既然 SwiftUI 不会把它刷新，
/// 我们就只能自己改 `NSMenuItem.title`；但只在「切换语言」那一刻改是不可靠的：
/// 之后任何一次 SwiftUI 重建菜单图、系统重新加载 NIB/菜单、或上一次改动没落到全部条目，
/// 都会留下中英混排的菜单——而用户看到的正是这个。
///
/// 所以除了切换时改，还在**菜单每次展开前**再自愈一次：
/// 用户唯一能看见菜单的时刻就是它被展开时，在那里保证正确，
/// 就不依赖于"之前某次改动有没有生效"。收起时再兜一次，避免残留到下一次。
///
/// 为什么不干脆整棵菜单自己用 AppKit 建：那样要放弃 SwiftUI 的
/// `.keyboardShortcut` / `CommandGroup(replacing:)` 等系统集成，
/// 还要自己重造「文件 / 编辑 / 窗口」这些系统菜单，代价远大于收益。
enum MainMenuLocalizer {

    @MainActor private static var observing = false

    /// 在 App 启动时调用一次：挂上「展开 / 收起 / 启动完成」三个时点的自愈。
    nonisolated static func start() {
        DispatchQueue.main.async { MainActor.assumeIsolated { install() } }
    }

    @MainActor
    private static func install() {
        guard !observing else { return }
        observing = true
        let names: [Notification.Name] = [
            NSMenu.didBeginTrackingNotification,
            NSMenu.didEndTrackingNotification,
            NSApplication.didFinishLaunchingNotification
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    refresh(to: LocalizationManager.shared.language)
                }
            }
        }
        // 启动完成前 `NSApp.mainMenu` 可能还没建好，所以顺便立刻试一次。
        refresh(to: LocalizationManager.shared.language)
    }

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
            // 只在真的不一致时才写：避免对着已经正确的菜单反复置脏、白刷一次界面。
            if let retitled = MenuLocalization.retitled(item.title, to: language),
               retitled != item.title {
                item.title = retitled
            }
            if let submenu = item.submenu {
                retitle(submenu, to: language)
            }
        }
    }
}
