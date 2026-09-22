import Foundation
import Darwin

/// 跑在本机 PTY 上的交互式 shell 会话。
///
/// 用 `forkpty` 而不是 `posix_spawn`：只有它会把子进程放进**新会话**并把 PTY 设成它的
/// **控制终端**，作业控制与 `^C`（前台进程组收 SIGINT）才正常。`posix_spawn` 要凑齐
/// 这两件事得靠 `POSIX_SPAWN_SETSID` 加子进程自己 open 从设备，语义还不保证。
/// 子进程里只做 `setenv` + `execv`（fork 到 exec 之间只能用异步信号安全的调用）。
///
/// **沙箱影响（实测，见 SRS R-18）**：子进程继承 App 沙箱 —— shell 能跑，但 `$HOME`
/// 是 App 容器、读不到 `/Users/...`、也看不到用户 PATH 里的 `psql` / `pg_dump`。
/// 本类与沙箱无关，去掉沙箱即可全功能。
final class TerminalSession {

    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?

    /// 读事件用（也用于收尾）。
    private let ioQueue = DispatchQueue(label: "studio.doyah.terminal.io")
    /// 写用单独队列：写可能因 PTY 缓冲满而等待，绝不能拖住读。
    private let writeQueue = DispatchQueue(label: "studio.doyah.terminal.write")

    /// 收到 shell 输出（已在主线程）。
    var onOutput: ((Data) -> Void)?
    /// shell 退出（已在主线程），参数是退出码。
    var onExit: ((Int32) -> Void)?

    private(set) var isRunning = false
    /// 启动失败的原因（可读中文，界面直接显示）。
    private(set) var lastError: String?

    deinit { terminate() }

    // MARK: 生命周期

    @discardableResult
    func start(columns: Int, rows: Int, shell: String? = nil, loginShell: Bool = true) -> Bool {
        guard !isRunning else { return true }
        lastError = nil

        var window = winsize(
            ws_row: UInt16(clamping: max(1, rows)),
            ws_col: UInt16(clamping: max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        var master: Int32 = -1
        let executable = shell ?? Self.defaultShell()
        let pid = forkpty(&master, nil, nil, &window)

        if pid == 0 {
            // ---- 子进程：fork 之后到 exec 之间只能用异步信号安全的调用 ----
            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            setenv("TERM_PROGRAM", "DoyahStudio", 1)
            if ProcessInfo.processInfo.environment["LANG"] == nil {
                setenv("LANG", "en_US.UTF-8", 1)
            }
            let arguments = loginShell ? [executable, "-l"] : [executable]
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
            argv.append(nil)
            execv(executable, argv)
            _exit(127) // exec 失败
        }

        guard pid > 0, master >= 0 else {
            if master >= 0 { close(master) }
            lastError = "无法启动 shell（\(executable)）：forkpty 失败"
            return false
        }

        masterFD = master
        childPID = pid
        isRunning = true
        _ = fcntl(masterFD, F_SETFL, O_NONBLOCK)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ioQueue)
        readSource.setEventHandler { [weak self] in self?.drainOutput() }
        readSource.resume()
        self.readSource = readSource

        let processSource = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: ioQueue
        )
        processSource.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : (status & 0x7F)
            DispatchQueue.main.async {
                self.isRunning = false
                self.onExit?(code)
            }
        }
        processSource.resume()
        self.processSource = processSource

        return true
    }

    func terminate() {
        readSource?.cancel()
        readSource = nil
        processSource?.cancel()
        processSource = nil

        if childPID > 0 {
            kill(childPID, SIGHUP)
            childPID = -1
        }
        // 关闭放在最后：cancel 之后事件不会再触发，避免与 cancel handler 双关闭。
        if masterFD >= 0 {
            let descriptor = masterFD
            masterFD = -1
            ioQueue.async { close(descriptor) }
        }
        isRunning = false
    }

    // MARK: 读写

    /// 把按键 / 粘贴内容写进 PTY。
    func write(_ bytes: [UInt8]) {
        guard isRunning, !bytes.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var remaining = bytes
            while !remaining.isEmpty, self.masterFD >= 0 {
                let written = remaining.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.write(self.masterFD, base, raw.count)
                }
                if written > 0 {
                    remaining.removeFirst(written)
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    // PTY 缓冲满：等可写（最多 100ms）再试，别忙等
                    var descriptor = pollfd(fd: self.masterFD, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 100)
                } else {
                    return // 从设备已关闭
                }
            }
        }
    }

    func write(text: String) {
        write(Array(text.utf8))
    }

    /// 把窗口尺寸告诉 PTY，shell 与全屏程序（vim / htop）才会按新宽度重排。
    func resize(columns: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var window = winsize(
            ws_row: UInt16(clamping: max(1, rows)),
            ws_col: UInt16(clamping: max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &window)
    }

    // MARK: 内部

    private func drainOutput() {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while masterFD >= 0 {
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                DispatchQueue.main.async { [weak self] in self?.onOutput?(chunk) }
                if count < buffer.count { break }
            } else {
                // 0 / EAGAIN / EIO（从设备关闭）都到此为止
                break
            }
        }
    }

    private static func defaultShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }
}
