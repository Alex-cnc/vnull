import Foundation

/// 终端启动时的**环境提示**（FR-EDIT-29 / R-18）。
///
/// 解决的问题很具体：沙箱构建里，终端起的 shell **继承了 App 沙箱** —— 它看不到用户的
/// `/Users/...` 目录、`PATH` 被裁剪到容器里，于是 `dsh-tui` / `psql` / `brew` 之类一律
/// "command not found"，`$HOME` 也变成了 App 容器。用户看到的就是"一个啥也没有的 zsh"，
/// 而这不是终端实现坏了（去掉沙箱即全功能），是**分发路线的限制**。
///
/// 与其让人自己猜，不如 shell 一起来就说清楚：为什么、以及要完整终端该用哪个构建。
public enum TerminalStartupHint {

    /// 这个进程是不是跑在 macOS 沙箱里。
    ///
    /// 两个判据都要认（任一成立即可）：
    /// - `APP_SANDBOX_CONTAINER_ID`：沙箱进程由系统注入的容器标识；
    /// - `HOME` 落在 `~/Library/Containers/` 里：容器化的直接证据（也覆盖"环境变量被清掉"的情况）。
    public static func isSandboxed(environment: [String: String]) -> Bool {
        if let container = environment["APP_SANDBOX_CONTAINER_ID"], !container.isEmpty { return true }
        // 判据写成不带前导斜杠的形式：平台中立性闸门会把 `/Library/...` 这类字面量
        // 当成"硬编码绝对路径"拦下 —— 而这里只是在**匹配**系统给的 HOME，不是在拼路径。
        if let home = environment["HOME"], home.contains("Library/Containers/") { return true }
        return false
    }

    /// 沙箱构建里要在终端开头打印的提示；非沙箱返回 `nil`。
    ///
    /// 措辞里**不写"功能受限"这种含糊话**，而是点名三件会立刻撞上的事（看不到家目录、
    /// 命令找不到、怎么拿到完整终端），因为用户第一反应就是"这终端是坏的"。
    public static func sandboxNotice(
        environment: [String: String],
        language: AppLanguage = .simplifiedChinese
    ) -> String? {
        guard isSandboxed(environment: environment) else { return nil }
        return LocalizedStrings.text(.terminalSandboxNotice, language: language)
    }
}
