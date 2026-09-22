import AppKit

/// 重启应用（NFR-I18N-03）。
///
/// 为什么需要重启：系统级菜单（文件 / 编辑 / 显示 / 窗口 / 帮助…）由 AppKit 渲染，
/// 而 AppKit 用哪种语言是在**进程启动时**由 `Bundle.main.preferredLocalizations` 定下的，
/// 运行时改 `AppleLanguages` 对它无效（实测）。所以「切换语言的那一刻」系统菜单不会变，
/// 只能重启进程让它跟随。
///
/// 先拉起新实例、成功后再退出自己：万一新实例起不来，旧实例还在，
/// 不会出现「应用退出了但什么都没起来」。
@MainActor
enum AppRelauncher {

    /// 拉新实例并退出当前实例；失败时抛错，由调用方把可读原因显示给用户。
    static func relaunch() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        )
        NSApp.terminate(nil)
    }
}
