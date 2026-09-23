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

    /// PTY 主端与子进程号的**互斥保护**。
    ///
    /// 它们会被三个执行域碰：主线程（`terminate`）、读队列（`drainOutput`）、写队列（`write`）。
    /// 原先是无保护的裸属性（R-34）：`terminate` 把 fd 置 -1 并关闭，而写队列可能刚好读到
    /// 同一个整数 —— 那个号可能已被系统分配给别的文件，于是"往自己的终端写"变成
    /// "往别人的 fd 写"。用一把锁把「检查 + 使用」收进临界区。
    private let stateLock = NSLock()
    private var storedMasterFD: Int32 = -1
    private var storedChildPID: pid_t = -1

    private var masterFD: Int32 {
        get { stateLock.lock(); defer { stateLock.unlock() }; return storedMasterFD }
        set { stateLock.lock(); storedMasterFD = newValue; stateLock.unlock() }
    }

    private var childPID: pid_t {
        get { stateLock.lock(); defer { stateLock.unlock() }; return storedChildPID }
        set { stateLock.lock(); storedChildPID = newValue; stateLock.unlock() }
    }

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
    func start(
        columns: Int,
        rows: Int,
        shell: String? = nil,
        loginShell: Bool = true,
        workingDirectory: String? = nil
    ) -> Bool {
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
            // ---- 子进程：fork 之后到 exec 之间只用异步信号安全的调用 ----
            // 不 chdir 的话会继承父进程 cwd —— 而应用被 LaunchServices 拉起时那是 `/`，
            // 终端一进去就是根目录。启动目录由调用方按三级回退算好传进来。
            if let workingDirectory, !workingDirectory.isEmpty {
                _ = chdir(workingDirectory)
                setenv("PWD", workingDirectory, 1)
            }
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

        let pid = childPID
        childPID = -1

        if pid > 0 {
            // ① 向**整个进程组**发挂断（R-34）。
            //
            // `forkpty` 让子进程成为新会话的首进程，它的进程组号就等于 pid，
            // 所以 `killpg(pid, …)` 能连它的子孙一起通知。
            // 原来只 `kill(childPID, SIGHUP)`：直接子进程收到，正在跑 `psql` 的**孙进程**
            // 收不到 —— 它继续握着 PTY 不放，成了看不见的孤儿。
            if killpg(pid, SIGHUP) != 0 {
                // 极少数情况（组已不存在）退回直接发信号。
                _ = kill(pid, SIGHUP)
            }

            // ② 宽限期后仍活着就强杀整组，并**回收子进程**。
            //
            // 原实现从不 `waitpid`：shell 退出后留下僵尸项（父进程还在，僵尸就会一直挂着）。
            // 这里在专用的后台队列上做（`terminate` 可能在主线程被调用，不能阻塞它）。
            let reaper = DispatchQueue(label: "studio.doyah.terminal.reaper")
            reaper.async {
                var status: Int32 = 0
                // 先等 1 秒：多数 shell 收到 SIGHUP 就退了。
                for _ in 0..<10 {
                    let result = waitpid(pid, &status, WNOHANG)
                    if result == pid || result == -1 {
                        return          // 已回收（或已经不是我们的子进程）
                    }
                    usleep(100_000)
                }
                // 还不退：整组强杀，再阻塞回收，确保不留僵尸。
                killpg(pid, SIGKILL)
                _ = kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
            }
        }

        // 关闭放在最后：cancel 之后事件不会再触发，避免与 cancel handler 双关闭。
        stateLock.lock()
        let descriptor = storedMasterFD
        storedMasterFD = -1
        stateLock.unlock()
        if descriptor >= 0 {
            ioQueue.async { close(descriptor) }
        }
        isRunning = false
    }

    // MARK: 读写

    /// 把按键 / 粘贴内容写进 PTY。
    func write(_ bytes: [UInt8]) {
        guard isRunning, !bytes.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            // 整个写循环都握着锁：fd 一旦被 terminate 置为 -1 并关闭，
            // 必须保证**没有线程正拿着旧号在写**（旧号可能已被复用）。
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            guard self.storedMasterFD >= 0 else { return }
            var remaining = bytes
            while !remaining.isEmpty, self.storedMasterFD >= 0 {
                let written = remaining.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.write(self.storedMasterFD, base, raw.count)
                }
                if written > 0 {
                    remaining.removeFirst(written)
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    // PTY 缓冲满：等可写（最多 100ms）再试，别忙等
                    var descriptor = pollfd(fd: self.storedMasterFD, events: Int16(POLLOUT), revents: 0)
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
