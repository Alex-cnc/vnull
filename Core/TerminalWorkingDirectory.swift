import Foundation

/// 决定内嵌终端启动时落在哪个目录。
///
/// 背景（实测）：`forkpty` 起的 shell 继承父进程的 cwd，而应用被 LaunchServices
/// （`open` / Finder 双击）拉起时 **cwd 是 `/`** —— 于是终端一进去就是根目录，很不专业。
/// 只有从命令行直接跑可执行文件时，cwd 才是"启动目录"。
///
/// 所以按三级回退，而不是简单继承：
/// 1. **工作区目录**（将来左侧 Explorer 里设置的，优先级最高）；
/// 2. **启动目录** —— 但 `/` 不算（那是"没有启动目录"，不是"启动目录是根"）；
/// 3. **家目录**。
///
/// 判定"可用"由调用方注入（`FileManager.isReadableFile` + 目录判断），
/// 这样这段规则是纯函数、可单测。
public enum TerminalWorkingDirectory {

    public static func resolve(
        workspace: String?,
        launchDirectory: String,
        home: String,
        isUsableDirectory: (String) -> Bool
    ) -> String {
        if let workspace {
            let trimmed = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, isUsableDirectory(trimmed) { return trimmed }
        }

        // `/` 是"被 LaunchServices 拉起"的特征，不是有意义的启动目录。
        let launch = launchDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !launch.isEmpty, launch != "/", isUsableDirectory(launch) { return launch }

        if isUsableDirectory(home) { return home }

        // 都不行就原样返回启动目录，让 shell 自己报错 —— 不吞掉信息。
        return launch.isEmpty ? home : launch
    }
}
