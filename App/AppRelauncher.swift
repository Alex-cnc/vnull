import AppKit

/// 重启应用（NFR-I18N-03）。
///
/// 为什么需要重启：系统级菜单（文件 / 编辑 / 显示 / 窗口 / 帮助…）由 AppKit 渲染，
/// 而 AppKit 用哪种语言是在**进程启动时**由 `Bundle.main.preferredLocalizations` 定下的，
/// 运行时改 `AppleLanguages` 对它无效（实测）。所以「切换语言的那一刻」系统菜单不会变，
/// 只能重启进程让它跟随。
///
/// **顺序很关键**：起一个「守望者」子进程 → 它等本进程真的退出 → 它才拉起新实例；本进程随后退出。
///
/// 为什么不是「先 open 再 terminate」（原实现）：
///   · `createsNewApplicationInstance = true` 必然让**两个实例并存一段时间**；
///   · 而 `NSApp.terminate` 是**可能被否决**的（有模态面板 / 未保存内容时）。
/// 两者叠加就是用户看到的现象：「弹出一个新的，原来旧的还在」，而且**每重启一次多一个**。
/// 反过来做就没有这个窗口期 —— 旧进程先消失，新进程才出现。
@MainActor
enum AppRelauncher {

    /// 起守望者并退出当前实例；起不来时抛错，由调用方把可读原因显示给用户。
    static func relaunch() async throws {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        // 守望者：等本进程退出（最多约 10 秒）。**等不到就不拉新实例** ——
        // 那说明退出被否决了，此时再拉一个只会又变成两个窗口。
        let script = """
        for _ in $(seq 1 50); do
            if ! kill -0 \(pid) 2>/dev/null; then
                /usr/bin/open "\(bundlePath)"
                exit 0
            fi
            sleep 0.2
        done
        exit 0
        """

        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", script]
        try watcher.run()

        // 走到这里之后本进程会退出（若退出被否决，`terminate` 返回，守望者也会超时不动手）。
        NSApp.terminate(nil)
    }
}
