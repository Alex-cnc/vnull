import Foundation
import Combine
import DoyahCore

/// 语言管理：读取 / 保存用户选择，并在切换时通知界面重建。
///
/// 视图通过全局函数 `L(...)` 取文案；语言切换时根视图会按 `.id(language)` 整体重建，
/// 因此无需每个视图单独订阅。
///
/// **切换是「就地」的，不重启进程**（2026-09-24 需求提出者要求：换语言不该把界面上的东西全丢掉）。
/// 系统菜单（文件 / 编辑 / 显示 / 窗口 / 帮助）由 `MainMenuLocalizer` 在运行时逐项改写标题；
/// 只有"用的时候才创建"的系统界面（打开 / 保存面板的按钮、别的应用提供的服务项）跟着**系统语言**走，
/// 那部分要等下一次启动才一致 —— 这件事写在文档里，不用弹窗拦人。
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private static let storageKey = "app.language"

    @Published private(set) var language: AppLanguage

    /// 进程启动时的语言——也就是 AppKit 当前用来渲染系统级菜单的那一种。
    private let launchLanguage: AppLanguage

    /// 系统界面（**用的时候才创建**的那些）是否还停在启动语言。
    ///
    /// 它不再是"要不要重启"的判据（换语言已经就地完成），只是留给「重启应用」那条命令
    /// 与文档一个可以问的事实。跟 `launchLanguage` 比而不是简单置 true：切回启动语言就是一致了。
    var systemUIStillOnLaunchLanguage: Bool { language != launchLanguage }

    /// 「重启应用」确认框是否正在显示（R-36：显式重启，带上未保存提醒）。
    @Published var isRelaunchPromptPresented = false

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

        // **不再提示重启**：系统菜单由 `MainMenuLocalizer` 运行时改写标题（按 action selector 认项），
        // 所以"换语言 = 关掉重开"这条代价已经去掉。`syncAppleLanguages` 仍然写 ——
        // 它管的是**用的时候才创建**的系统界面（打开 / 保存面板按钮、服务子菜单），
        // 那部分跟着系统语言走，下次启动才一致（如实写在 NFR-I18N-03，不弹窗拦人）。

        // 菜单栏要走两条路才能全变（详见 `Core/MenuLocalization.swift` 的实测记录）：
        // 标题由 SwiftUI 重建命令图时刷新；叶子项 SwiftUI 不管，得自己改 NSMenuItem.title。
        // 先立刻改一次（用户马上拉开菜单也不会看到旧文案），再等 SwiftUI 重建落定后兜一次。
        // 为什么不是"改一次就够"：`setLanguage` 之后 SwiftUI 会**重建命令图**，
        // 那次重建会把系统菜单项（文件 / 编辑 / 显示 / 窗口 / 帮助）恢复成**启动语言**的标题 ——
        // 实测：切换后立刻是对的，0.1~3 秒之间又被改回去（每台机器/每次重建的快慢不一样）。
        // 所以在一小段时间里连做几次；每次都很便宜（只有真不一样才写 `title`，
        // 见 `MainMenuLocalizer.retitle` 的比较），而且菜单每次展开前还会再自愈一次。
        MainMenuLocalizer.refresh(to: newLanguage)
        // 再开一个 3 秒的"补刷窗口"：那段时间里窗口每次刷新都会顺手对齐一次菜单栏
        // （见 `MainMenuLocalizer.beginHealing`）—— 这样就只有一帧的误差，不是几百毫秒。
        MainMenuLocalizer.beginHealing()
    }

    /// **当前该用哪种语言**：宿主语境优先，其次用户选择。
    ///
    /// 凡是"要**显式把语言传下去**"的地方（Core 那些 `summary(language:)` / `title(language:)`
    /// / `describe(…, language:)`），一律取这个而不是 `language` —— 只查 `L(...)` 的话，
    /// 宿主语境管不到那条路。第 13 轮读图抓到的英文残留就是这么来的：中文界面的行详情侧栏
    /// 上写着 `Text · 12 characters`（`RowDetailPanel` 传的是**用户选择**，而快照的宿主语言是中文，
    /// 两者不一致时，图里就混着两种语言）。
    ///
    /// **系统菜单那条路是例外**（`MainMenuLocalizer` 按 `language` 改写 `NSMenuItem.title`）：
    /// 菜单栏属于"进程级系统界面"，跟的是用户选择 / 启动语言，不跟渲染语境。
    var effectiveLanguage: AppLanguage { Self.currentHostScope?.language ?? language }

    func text(_ key: LKey, arguments: [CVarArg]) -> String {
        // 「用哪种语言」这件事有两层：**宿主语境**（界面快照取证，见下）优先于**用户选择**。
        // 生产路径永远没有宿主语境 ⇒ 与从前逐字同一条路。
        let scope = Self.currentHostScope
        let resolved = scope?.language ?? language
        let template = LocalizedStrings.text(key, language: resolved)
        let result = arguments.isEmpty
            ? template
            : String(format: template, locale: resolved.locale, arguments: arguments)
        scope?.note(result)
        return result
    }

    // MARK: - 宿主语境（界面快照取证用，队列 L-13）

    /// 一遍渲染里 `L(...)` 的**观测窗口**：记下这一遍实际取到的文案。
    ///
    /// 为什么要记：语言快照只有「两张图不一样」还不够 —— 得说清**差在哪**。
    /// 观测到的文案集合与像素的两个方向都给判据（见 `UISnapshot.writeBothLanguages` 与
    /// `Scripts/check-ui-snapshot-languages.py`）：
    ///   · 两遍文案**不同** ⇒ 两张 PNG 必须不同（否则语言没到像素上，图是假的）；
    ///   · 两遍文案相同而像素不同 ⇒ 说明有**非文案**的语言敏感输出，清单里会被点名。
    final class HostScope {
        let language: AppLanguage
        private var seen: Set<String> = []
        private let lock = NSLock()

        init(language: AppLanguage) {
            self.language = language
        }

        fileprivate func note(_ text: String) {
            lock.lock()
            defer { lock.unlock() }
            seen.insert(text)
        }

        /// 这一遍取到的文案（去重；顺序由调用方排序后落清单）。
        var observed: Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }

    private static let hostLock = NSLock()
    /// 宿主语境栈：支持嵌套（虽然目前只有一层），退出时恢复上一层。
    private static var hostScopes: [HostScope] = []

    private static var currentHostScope: HostScope? {
        hostLock.lock()
        defer { hostLock.unlock() }
        return hostScopes.last
    }

    /// 进入宿主语境：此后（直到 `endHostLanguage()`）`L(...)` 按 `language` 出文案，
    /// 并把文案记进返回的窗口。
    ///
    /// **只覆盖，不落盘**：它**不写** `UserDefaults`、**不**动 `AppleLanguages`、**不**改
    /// `language`（用户选择）—— 所以界面快照可以在一轮里把两种语言各拍一遍，
    /// 而**不会**把助理机器上的语言偏好改掉。生产路径从不调用它（行为逐字不变）。
    @discardableResult
    static func beginHostLanguage(_ language: AppLanguage) -> HostScope {
        let scope = HostScope(language: language)
        hostLock.lock()
        hostScopes.append(scope)
        hostLock.unlock()
        return scope
    }

    static func endHostLanguage() {
        hostLock.lock()
        if !hostScopes.isEmpty { hostScopes.removeLast() }
        hostLock.unlock()
    }

    /// 当前是否有宿主语境（用来如实标注快照记录里的语言来源）。
    static var isHostLanguageActive: Bool { currentHostScope != nil }
}

/// 取当前语言文案；带参数时按当前语言格式化。
func L(_ key: LKey, _ arguments: CVarArg...) -> String {
    LocalizationManager.shared.text(key, arguments: arguments)
}
