import Foundation

/// SSH 隧道的运行时（FR-CONN-18）：起 `ssh -N -L …`、等它就绪、退出时收干净。
///
/// **进程在 Core（`Foundation.Process` 两平台都有），但端口探测是注入的**：
/// 「这个端口通不通」「哪个端口空着」要用各平台的 socket API，而 Core 不许 `import Darwin/Glibc`
/// （平台中立性闸门守着）。所以这两件事由调用方注入：
///   · App：用它自己的实现（macOS 的 socket / Network 都行）；
///   · CLI：POSIX（`#if canImport(Darwin) … #else Glibc …`）；
///   · 单测/脚本：假实现或真的探测。
///
/// **口令怎么交给 `ssh`**：`ssh` 只在"没有终端"时走 `SSH_ASKPASS`，所以这里：
/// 建一个 0700 的临时目录，放 `askpass.sh`（0700，内容是 `cat` 同目录下的 `secret`）与 `secret`（0600，口令），
/// 然后设 `SSH_ASKPASS` / `SSH_ASKPASS_REQUIRE=force` 起进程；**握手一结束（成功或失败）立刻删掉这两个文件**。
/// 威胁模型如实写在文档里：这是"防别的进程顺手看见"，不是"防同一用户"。
public final class SSHTunnelProcess: @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case idle
        case starting(localPort: Int)
        case ready(localPort: Int)
        case failed(String)
        case stopped
    }

    /// 探测某个本机端口上有没有人在监听。
    public typealias PortProbe = @Sendable (_ host: String, _ port: Int) -> Bool

    private let config: SSHTunnelConfig
    private let target: SSHTunnelTarget
    private let localPort: Int
    private let executable: String
    private let knownHostsPath: String
    private let password: String?
    private let isPortOpen: PortProbe?

    private let lock = NSLock()
    private var state: State = .idle
    private var process: Process?
    private var stderrBuffer = Data()
    private var temporaryDirectory: URL?

    public init(
        config: SSHTunnelConfig,
        target: SSHTunnelTarget,
        localPort: Int,
        knownHostsPath: String,
        password: String? = nil,
        executable: String = "/usr/bin/ssh",
        isPortOpen: PortProbe? = nil
    ) {
        self.config = config
        self.target = target
        self.localPort = localPort
        self.knownHostsPath = knownHostsPath
        self.password = password
        self.executable = executable
        self.isPortOpen = isPortOpen
    }

    public var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// `ssh` 的 stderr 尾巴（出错时说人话的依据）；口令若意外出现会被抹掉。
    public var diagnosticText: String {
        lock.lock()
        let text = String(decoding: stderrBuffer, as: UTF8.self)
        let secret = password
        lock.unlock()
        var redacted = text
        if let secret, !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "***")
        }
        let lines = redacted.split(separator: "\n").suffix(6)
        return lines.joined(separator: "\n")
    }

    /// 建隧道并等它就绪；返回本地监听端口。
    ///
    /// - Parameter isPortOpen: 就绪判定；传 `nil` 时退化为"进程活着就算就绪"
    ///   （弱一些，仅在没有探测能力的调用方使用 —— 脚本里一律传真的探测）。
    @discardableResult
    public func start(timeout: TimeInterval? = nil) async throws -> Int {
        setState(.starting(localPort: localPort))
        // **先确认端口是空的**：否则"端口通"这件事会被别人占着的监听误导 ——
        // 我们自己的 ssh 建转发失败退出、探测却看到别人的端口，于是报"就绪"（实测踩到）。
        if let isPortOpen, isPortOpen("127.0.0.1", localPort) {
            setState(.failed(SSHTunnelError.portInUse(localPort).localizedDescription))
            throw SSHTunnelError.portInUse(localPort)
        }
        try prepareKnownHostsDirectory()

        let arguments = SSHTunnelArguments.make(
            config: config,
            localPort: localPort,
            target: target,
            knownHostsPath: knownHostsPath,
            passwordMode: password != nil
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let password, !password.isEmpty {
            // 口令只经 `SSH_ASKPASS` 走，不进 argv、不进环境变量本体。
            environment["SSH_ASKPASS"] = try makeAskPass(for: password).path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "doyah:0"      // 老版本 ssh 要求有 DISPLAY 才用 askpass
        }
        process.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.appendStderr(chunk)
        }

        do {
            try process.run()
        } catch {
            cleanUpTemporaryFiles()
            let reason = LocalizedStrings.format(.sshTunnelLaunchFailed, language: .simplifiedChinese, error.localizedDescription)
            setState(.failed(reason))
            throw SSHTunnelError.launchFailed(reason)
        }
        lock.lock(); self.process = process; lock.unlock()

        // 给 ssh 一点"沉降时间"：刚 fork 出来的进程 isRunning 还是 true，
        // 而它可能马上因为转发建不起来而退出 —— 这段时间里先不急着判就绪。
        try? await Task.sleep(nanoseconds: 200_000_000)

        let deadline = Date().addingTimeInterval(timeout ?? TimeInterval(config.connectTimeoutSeconds))
        while Date() < deadline {
            if !process.isRunning {
                cleanUpTemporaryFiles()
                let reason = diagnosticText.isEmpty
                    ? LocalizedStrings.text(.sshTunnelProcessExitedSilently, language: .simplifiedChinese)
                    : LocalizedStrings.format(.sshTunnelProcessExited, language: .simplifiedChinese, diagnosticText)
                setState(.failed(reason))
                throw SSHTunnelError.processExited(reason)
            }
            if let isPortOpen {
                if isPortOpen("127.0.0.1", localPort) {
                    cleanUpTemporaryFiles()
                    setState(.ready(localPort: localPort))
                    return localPort
                }
            } else {
                // 没有探测能力：给它一点时间把转发建起来（`ExitOnForwardFailure=yes` 保证失败会退出）
                try? await Task.sleep(nanoseconds: 400_000_000)
                if process.isRunning {
                    cleanUpTemporaryFiles()
                    setState(.ready(localPort: localPort))
                    return localPort
                }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        cleanUpTemporaryFiles()
        stop()
        let seconds = Int(timeout ?? TimeInterval(config.connectTimeoutSeconds))
        let reason = LocalizedStrings.format(.sshTunnelTimedOut, language: .simplifiedChinese, String(seconds))
        setState(.failed(reason))
        throw SSHTunnelError.timedOut(reason)
    }

    /// 收干净：先 SIGTERM，1 秒后还在就 SIGKILL（不留孤儿 ssh 进程占着端口）。
    public func stop() {
        lock.lock()
        let process = self.process
        self.process = nil
        lock.unlock()
        guard let process, process.isRunning else {
            cleanUpTemporaryFiles()
            setState(.stopped)
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        cleanUpTemporaryFiles()
        setState(.stopped)
    }

    /// 结束隧道（deinit 兜底：进程没停就走 stop，避免留下孤儿）。
    deinit {
        lock.lock()
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    // MARK: 内部

    private func appendStderr(_ chunk: Data) {
        lock.lock()
        stderrBuffer.append(chunk)
        if stderrBuffer.count > 16 * 1024 {
            stderrBuffer = stderrBuffer.suffix(8 * 1024)
        }
        lock.unlock()
    }

    private func setState(_ newState: State) {
        lock.lock(); state = newState; lock.unlock()
    }

    private func prepareKnownHostsDirectory() throws {
        let directory = URL(fileURLWithPath: knownHostsPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: knownHostsPath) {
            FileManager.default.createFile(atPath: knownHostsPath, contents: nil)
            // 只给本人读写：里面是"我们信任哪些主机指纹"，被别人改写就等于中间人。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsPath)
        }
    }

    /// 写 askpass 脚本与口令文件（0700 目录 / 0700 脚本 / 0600 口令），用完即删。
    private func makeAskPass(for password: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doyah-tunnel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let secretURL = directory.appendingPathComponent("secret")
        try Data(password.utf8).write(to: secretURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)

        let scriptURL = directory.appendingPathComponent("askpass.sh")
        let script = "#!/bin/sh\ncat \"$(dirname \"$0\")/secret\"\n"
        try Data(script.utf8).write(to: scriptURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        lock.lock(); temporaryDirectory = directory; lock.unlock()
        return scriptURL
    }

    private func cleanUpTemporaryFiles() {
        lock.lock()
        let directory = temporaryDirectory
        temporaryDirectory = nil
        lock.unlock()
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 隧道起不来时的原因（分类清楚，界面/脚本据此说人话）。
public enum SSHTunnelError: Error, Equatable, LocalizedError {
    case portInUse(Int)
    case launchFailed(String)
    case processExited(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .portInUse(let port):
            return LocalizedStrings.format(.sshTunnelPortInUse, language: .simplifiedChinese, String(port))
        case .launchFailed(let reason): return reason
        case .processExited(let reason): return reason
        case .timedOut(let reason): return reason
        }
    }
}
