import Foundation

/// 外部程序执行层（FR-IO-04 的「执行」那一半）。
///
/// 与 `BackupCommand`（只生成 argv）配套：**argv 直接交给进程，永不经过 shell** ——
/// 库名里的 `;`、空格、引号都只是普通参数，命令注入在结构上不可能发生。
///
/// 为什么抽协议：执行层要能单测（失败退出码、日志逐行、取消、环境变量），
/// 而"真的起进程"这件事没法在单测里验；用一个假实现把逻辑钉住，真实现只在脚本里跑。
public protocol ExternalProcessRunner: Sendable {
    /// 执行一个程序，逐行回调输出，返回退出码。
    ///
    /// - `environment` 里的值**合并**进当前环境（备份用它传 `PGPASSWORD`，避免密码出现在进程列表里）。
    /// - `onOutput` 会拿到 stdout 与 stderr 的每一行（合并流，保持到达顺序）——
    ///   备份日志的价值就在顺序里，"先把错误抽出来再打印"会打乱因果。
    /// - 取消语义：调用方取消 Task 时应尽量终止子进程（实现负责优雅终止 → 超时强杀）。
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32
}

public enum ExternalProcessError: Error, Equatable, LocalizedError {
    /// 程序不存在 / 不可执行 —— 要说清是哪个程序，否则用户只能猜。
    case launchFailed(executable: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let reason):
            return "无法启动 \(executable)：\(reason)"
        }
    }
}

/// 用 `Foundation.Process` 的实现。
public struct FoundationProcessRunner: ExternalProcessRunner {

    /// 取消后等待优雅终止的时间（秒）；超时再强杀。
    public var terminationGraceSeconds: Double

    public init(terminationGraceSeconds: Double = 3) {
        self.terminationGraceSeconds = terminationGraceSeconds
    }

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        // 直接执行 argv；不经过 `/bin/sh -c`，因此参数里的任何字符都不会被解释。
        process.executableURL = try Self.resolveExecutable(executable)
        process.arguments = arguments

        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // 也关掉 stdin：备份类工具不该在等用户输入时挂住。
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ExternalProcessError.launchFailed(executable: executable, reason: error.localizedDescription)
        }

        // 读输出与等待退出并行：先读完再 wait 会在缓冲区满时**死锁**（子进程写不进去、我们也读不到）。
        let handle = pipe.fileHandleForReading
        let reader = Task.detached(priority: .utility) {
            var buffer = Data()
            while let chunk = try? handle.read(upToCount: 8 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                // 按行切分，最后一段可能不完整，留在 buffer 里等下一块。
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let line = String(data: lineData, encoding: .utf8) {
                        onOutput(line)
                    }
                }
            }
            if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) {
                onOutput(tail)
            }
        }

        // 取消要能传到子进程：否则"停止备份"只是不再等了，进程还在写磁盘。
        let waiter = Task.detached(priority: .utility) {
            process.waitUntilExit()
        }
        let exitCode = await withTaskCancellationHandler {
            await waiter.value
            return process.terminationStatus
        } onCancel: {
            process.terminate()
            let deadline = Date().addingTimeInterval(terminationGraceSeconds)
            while process.isRunning, Date() < deadline {
                usleep(100_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        _ = await reader.value
        return exitCode
    }

    /// 解析可执行文件：支持绝对路径，也支持在 `PATH` 里查找（`pg_dump` 常不在默认 PATH 里）。
    static func resolveExecutable(_ name: String) throws -> URL {
        if name.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: name) else {
                throw ExternalProcessError.launchFailed(executable: name, reason: "文件不存在或不可执行")
            }
            return URL(fileURLWithPath: name)
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw ExternalProcessError.launchFailed(executable: name, reason: "在 PATH 里找不到（可用 --tool-path 指定绝对路径）")
    }
}
