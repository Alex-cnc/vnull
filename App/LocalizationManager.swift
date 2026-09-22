import Foundation
import Combine
import DoyahCore

/// 语言管理：读取 / 保存用户选择，并在切换时通知界面重建。
///
/// 视图通过全局函数 `L(...)` 取文案；语言切换时根视图会按 `.id(language)` 整体重建，
/// 因此无需每个视图单独订阅。
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private static let storageKey = "app.language"

    @Published private(set) var language: AppLanguage

    /// 进程启动时的语言——也就是 AppKit 当前用来渲染系统级菜单的那一种。
    private let launchLanguage: AppLanguage

    /// 系统菜单现在是否需要重启才能跟随当前语言。
    ///
    /// 跟 `launchLanguage` 比而不是简单置 true：切走再切回来就不需要重启了。
    var systemMenusNeedRestart: Bool { language != launchLanguage }

    /// 重启提示是否正在显示（用户点「稍后」收起它，`systemMenusNeedRestart` 仍为真）。
    @Published var isRestartPromptPresented = false

    private init() {
        let resolved: AppLanguage
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let stored = AppLanguage(rawValue: raw) {
            resolved = stored
        } else {
            resolved = .systemDefault
        }
        language = resolved
        launchLanguage = resolved
        // 让 AppKit 自带的系统级菜单（文件 / 编辑 / 显示 / 窗口 / 帮助…）跟随同一语言。
        // 注意：这个键**在进程启动时**才被读取，运行时改它对当前进程无效
        // （实测 `Bundle.main.preferredLocalizations` 不会变）——只对下一次启动生效。
        Self.syncAppleLanguages(resolved)
    }

    /// 同步 `AppleLanguages`：它控制 AppKit 自带的本地化（系统菜单 / 文件对话框 / 关于面板…）。
    ///
    /// 必须配合 `Info.plist` 的 `CFBundleLocalizations`（`Scripts/build-app.sh` 里声明了
    /// en 与 zh-Hans）：不声明时 macOS 会忽略这个键、回退到系统区域，系统菜单就永远是系统语言。
    private static func syncAppleLanguages(_ language: AppLanguage) {
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        UserDefaults.standard.set(newLanguage.rawValue, forKey: Self.storageKey)
        Self.syncAppleLanguages(newLanguage)

        // 系统级菜单只在下次启动时才能跟随，所以切换后提示一次重启；
        // 切回启动时的语言则不需要重启，提示也随之收起。
        isRestartPromptPresented = systemMenusNeedRestart

        // 菜单栏要走两条路才能全变（详见 `Core/MenuLocalization.swift` 的实测记录）：
        // 标题由 SwiftUI 重建命令图时刷新；叶子项 SwiftUI 不管，得自己改 NSMenuItem.title。
        // 先立刻改一次（用户马上拉开菜单也不会看到旧文案），再等 SwiftUI 重建落定后兜一次。
        MainMenuLocalizer.refresh(to: newLanguage)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainMenuLocalizer.refresh(to: newLanguage)
        }
    }

    func text(_ key: LKey, arguments: [CVarArg]) -> String {
        let template = LocalizedStrings.text(key, language: language)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: language.locale, arguments: arguments)
    }
}

/// 取当前语言文案；带参数时按当前语言格式化。
func L(_ key: LKey, _ arguments: CVarArg...) -> String {
    LocalizationManager.shared.text(key, arguments: arguments)
}
