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

    /// 「补刷窗口」的截止时刻：语言切换后的头几秒里，**窗口每次刷新都顺手把菜单栏对齐一次**。
    ///
    /// 为什么需要这么密：`setLanguage` 之后 SwiftUI 会重建命令图，那次重建把系统菜单标题恢复成
    /// **启动语言**（实测重建落在切换后 0.2~0.5 秒之间）—— 只在掐好的时间点补刷，
    /// 总有一小段窗口对不上（菜单栏会「新语言 → 启动语言 → 新语言」闪一下）。
    /// 挂到窗口刷新上，这段窗口就缩到一帧以内；代价是走一遍菜单、**不一样才写 title**。
    @MainActor private static var healUntil: Date = .distantPast

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
            NSApplication.didFinishLaunchingNotification,
            // 命令图被重建时菜单项会被换掉（标题也跟着回到启动语言）——补一个**因果**时点，
            // 比只靠"切换后掐几个时间点补刷"可靠（那条仍然留着，见 `LocalizationManager.setLanguage`）。
            NSMenu.didAddItemNotification,
            // 语言切换后的头几秒：窗口每次刷新都对齐一次（见 `healUntil` 的说明）。
            NSWindow.didUpdateNotification
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // 窗口刷新很频繁：只在语言切换后的补刷窗口里动手，平时一次都不做。
                    if name == NSWindow.didUpdateNotification, Date() >= healUntil { return }
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

    /// 语言切换时调用：在接下来几秒里把「窗口刷新」当成补刷时机（见 `healUntil`）。
    ///
    /// 入口与 `refresh` 一样保持 `nonisolated`（调用方是普通 `ObservableObject`）。
    nonisolated static func beginHealing() {
        DispatchQueue.main.async { MainActor.assumeIsolated { healUntil = Date().addingTimeInterval(3) } }
    }

    /// 应用显示名（系统菜单里"关于 / 隐藏 / 退出 / 帮助"都带它，不该写死在文案表里）。
    @MainActor
    private static var appDisplayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? "DoyahStudio"
    }

    @MainActor
    private static func retitle(_ menu: NSMenu, to language: AppLanguage) {
        let appName = appDisplayName
        for item in menu.items {
            // 先按 **action selector** 认（系统菜单项走这条，与启动语言无关），
            // 认不出再按标题认（自有菜单项、以及没有 action 的顶层菜单标题）。
            let byAction = item.action.map {
                MenuLocalization.retitled(action: NSStringFromSelector($0), appName: appName, to: language)
            } ?? nil
            // 只在真的不一致时才写：避免对着已经正确的菜单反复置脏、白刷一次界面。
            if let retitled = byAction ?? MenuLocalization.retitled(item.title, to: language),
               retitled != item.title {
                item.title = retitled
                // **菜单栏顶层项还要改 `NSMenu.title`**：AppKit 显示的是子菜单自己的 title，
                // 只写 `item.title` 在菜单栏上看不出来（2026-09-24 实测：File/Edit/View 不动，
                // 它们下面的子项却都变了）。子菜单标题不是用户可见文案时改它无副作用。
                if item.submenu?.title != retitled { item.submenu?.title = retitled }
            }
            if let submenu = item.submenu {
                retitle(submenu, to: language)
            }
        }
    }
}
