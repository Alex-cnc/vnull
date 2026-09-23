import AppKit
import DoyahCore

/// 重启应用（NFR-I18N-03）。
///
/// 为什么需要重启：系统级菜单（文件 / 编辑 / 显示 / 窗口 / 帮助…）由 AppKit 渲染，
/// 而 AppKit 用哪种语言是在**进程启动时**由 `Bundle.main.preferredLocalizations` 定下的，
/// 运行时改 `AppleLanguages` 对它无效（实测）。所以「切换语言的那一刻」系统菜单不会变，
/// 只能重启进程让它跟随。
///
/// **这里有三次踩坑，全记下来（需求书 R-36）**：
///
/// 1. 「先 open 再 terminate」→ 两个实例并存；一旦 `terminate` 被否决（模态面板 / 未保存内容），
///    旧实例就永远留着 —— 用户看到「弹出新的、旧的还在」，每重启多一个。
/// 2. 「起守望者 → 等旧进程退出 → 再 open」→ **点重启没反应**：守望者是 `Process` 起的子进程，
///    它用 `kill -0` 探测旧进程；沙箱里这个探测会失败，于是它以为旧进程没了、立刻 `open`，
///    而此时旧实例还活着，新实例的单实例保护就把新实例撤掉去激活旧的，旧的随后也退出 → 什么都不剩。
/// 3. 「用 `NSWorkspace.OpenConfiguration.arguments` 告诉新实例『来接替谁』」→ **参数根本没到**：
///    实测新实例的 `ProcessInfo.arguments` 里只有可执行文件路径（`args=[]`），
///    于是新实例认不出接替关系，又走了第 2 条的老路。
///
/// **现在这版不依赖任何跨进程通信方式**：旧实例退出前在磁盘上留一张「交接单」，
/// 新实例启动时先看有没有它 —— 只用到文件系统，两个上下文都确定可用。
@MainActor
enum AppRelauncher {

    /// 交接单：旧实例写的「我正要退出，来接替我」。
    struct Handoff: Codable {
        var pid: pid_t
        var createdAt: Date
    }

    /// 交接单的有效期：超过它就当陈旧文件忽略（避免上次失败留下的文件影响以后的启动）。
    static let handoffLifetime: TimeInterval = 60

    static var handoffURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("relaunch-handoff.json", isDirectory: false)
    }

    /// 退出被否决（例如还有没关的模态面板）时抛这个。
    struct TerminationBlocked: Error, LocalizedError {
        var errorDescription: String? { L(.relaunchBlocked) }
    }

    /// 拉新实例并留下交接单，然后退出自己。
    ///
    /// - Parameter dirtyTabCount: 有未保存内容的页签数。**`terminate` 被否决且还有未保存内容时，
    ///   宁可重启不成功也不硬退** —— 不能为了换个语言丢掉别人写的东西。
    static func relaunch(dirtyTabCount: Int = 0) async throws {
        try writeHandoff()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        )

        NSApp.terminate(nil)

        // 只有「退出被否决」才会执行到这里（正常情况下进程已经没了）。
        guard dirtyTabCount == 0 else {
            throw TerminationBlocked()
        }
        // 没有未保存内容：直接退，保证"点了重启就真的重启"。
        // 这是对"沙箱下新实例无法强制关掉旧实例"（跨应用 AppleEvent 被禁，实测 `terminate()` 无效）
        // 的兜底 —— 否则就会剩下两个窗口，正是用户最初报的现象。
        exit(0)
    }

    /// 新实例启动时调用：若存在**有效的**交接单，就等交接单上那个进程退出，然后继续启动。
    ///
    /// - Returns: `true` = 这次启动是「接替启动」（不要再走"激活已有实例并退出"那条路）。
    static func claimHandoffIfPresent() -> Bool {
        guard let handoff = readHandoff() else { return false }

        guard Date().timeIntervalSince(handoff.createdAt) < handoffLifetime else {
            clearHandoff()
            return false
        }
        guard handoff.pid != ProcessInfo.processInfo.processIdentifier else {
            clearHandoff()
            return false
        }

        // **不在这里等**：`init()` 里阻塞几秒会让应用在启动阶段被系统的启动看门狗干掉
        // （实测：等了 5 秒的那个新实例直接消失，用户看到的现象还是"点重启没反应"）。
        // 改成「请旧实例退出」—— `NSRunningApplication.terminate()` 是应用级的干净请求，
        // 不发信号、也不需要等；它已经在退出时这一步就是 no-op。
        if let previous = NSRunningApplication(processIdentifier: handoff.pid), !previous.isTerminated {
            previous.terminate()
        }
        clearHandoff()
        return true
    }

    // MARK: - 交接单读写

    private static func writeHandoff() throws {
        let handoff = Handoff(pid: ProcessInfo.processInfo.processIdentifier, createdAt: Date())
        let data = try JSONEncoder().encode(handoff)
        try FileManager.default.createDirectory(
            at: handoffURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: handoffURL, options: .atomic)
    }

    private static func readHandoff() -> Handoff? {
        guard let data = try? Data(contentsOf: handoffURL) else { return nil }
        return try? JSONDecoder().decode(Handoff.self, from: data)
    }

    private static func clearHandoff() {
        try? FileManager.default.removeItem(at: handoffURL)
    }

}
