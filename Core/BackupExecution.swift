import Foundation

/// 备份 / 恢复的**执行计划**（FR-IO-04 的执行半边）。
///
/// `BackupCommand` 负责"参数怎么拼"，这里负责"这一件事是什么 + 交给哪个程序 + 怎么展示给用户看"。
/// 分两层的好处：argv 生成可以纯单测（已有的 11 项），执行编排也能用假执行器单测。
public struct BackupPlan: Equatable, Sendable {

    public enum Kind: String, Sendable {
        case dump
        case dumpAll
        case restore
    }

    public var kind: Kind
    public var target: BackupCommand.Target
    public var format: BackupCommand.Format
    /// 备份输出路径（dump / dumpAll）或归档路径（restore）。
    public var filePath: String?
    public var jobs: Int?
    public var noOwner: Bool
    public var clean: Bool
    /// 集群级备份的互斥选项。
    public var rolesOnly: Bool
    public var globalsOnly: Bool
    public var noRolePasswords: Bool
    /// 可执行文件名或绝对路径 —— 允许指定路径是必须的：**`pg_dump` 常常不在 GUI 应用的 `PATH` 里**
    /// （本机实测：它在 `~/tools/pgserver/pgserver/pginstall/bin/` 下，不在默认 PATH）。
    public var executableName: String

    public init(
        kind: Kind,
        target: BackupCommand.Target,
        format: BackupCommand.Format = .plain,
        filePath: String? = nil,
        jobs: Int? = nil,
        noOwner: Bool = false,
        clean: Bool = false,
        rolesOnly: Bool = false,
        globalsOnly: Bool = false,
        noRolePasswords: Bool = false,
        executableName: String? = nil
    ) {
        self.kind = kind
        self.target = target
        self.format = format
        self.filePath = filePath
        self.jobs = jobs
        self.noOwner = noOwner
        self.clean = clean
        self.rolesOnly = rolesOnly
        self.globalsOnly = globalsOnly
        self.noRolePasswords = noRolePasswords
        self.executableName = executableName ?? Self.defaultExecutable(for: kind)
    }

    public static func defaultExecutable(for kind: Kind) -> String {
        switch kind {
        case .dump: return "pg_dump"
        case .dumpAll: return "pg_dumpall"
        case .restore: return "pg_restore"
        }
    }

    /// 要执行的 argv（首元素是可执行文件）；参数不合法返回 nil。
    public var arguments: [String]? {
        let generated: [String]?
        switch kind {
        case .dump:
            generated = BackupCommand.dump(
                target: target,
                format: format,
                filePath: filePath,
                jobs: jobs,
                noOwner: noOwner,
                clean: clean
            )
        case .dumpAll:
            generated = BackupCommand.dumpAll(
                target: target,
                filePath: filePath,
                rolesOnly: rolesOnly,
                globalsOnly: globalsOnly,
                noRolePasswords: noRolePasswords,
                clean: clean
            )
        case .restore:
            guard let filePath else { return nil }
            generated = BackupCommand.restore(
                target: target,
                archivePath: filePath,
                clean: clean,
                jobs: jobs
            )
        }
        guard var argv = generated, !argv.isEmpty else { return nil }
        // 允许用绝对路径替换 argv[0]（PATH 里没有 pg_dump 时唯一可行的办法）。
        argv[0] = executableName
        return argv
    }

    /// 展示给用户的命令行。**密码写成 `***`** —— 它会进日志、会被截图，
    /// 而真实的密码走 `PGPASSWORD` 环境变量，不出现在命令行里。
    public func displayCommand(password: String?) -> String {
        guard let arguments else { return "（参数不合法，无法生成命令）" }
        let prefix = password?.isEmpty == false ? "PGPASSWORD=*** " : ""
        return prefix + arguments.map(Self.shellQuoted).joined(separator: " ")
    }

    /// 只为**展示**做引号包裹（执行时不经过 shell，所以这里不涉及正确性，只影响可读性）。
    static func shellQuoted(_ value: String) -> String {
        value.contains(" ") || value.contains("\"") || value.contains("'")
            ? "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
            : value
    }
}

/// 执行结果。
public struct BackupExecutionResult: Equatable, Sendable {
    public var exitCode: Int32
    public var outputLineCount: Int
    /// 最后几行输出：失败时它就是"线索"。
    public var lastOutputLines: [String]

    public var isFailure: Bool { exitCode != 0 }

    /// 失败摘要（成功时为 nil）：把最后几行摊出来，而不是只说"失败了"。
    public var failureSummary: String? {
        guard isFailure else { return nil }
        let tail = lastOutputLines.suffix(3).joined(separator: "\n")
        return tail.isEmpty ? "退出码 \(exitCode)（没有任何输出）" : tail
    }
}

/// 执行备份计划的编排。真起进程这件事交给注入的 `ExternalProcessRunner`。
public struct BackupExecutor {

    /// 失败摘要里保留的最后几行数量。
    static let tailLineLimit = 20

    private let runner: any ExternalProcessRunner

    public init(runner: any ExternalProcessRunner = FoundationProcessRunner()) {
        self.runner = runner
    }

    /// 执行；输出逐行回调（调用方负责展示 / 落盘）。
    public func execute(
        _ plan: BackupPlan,
        password: String?,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> BackupExecutionResult {
        guard let arguments = plan.arguments, let executable = arguments.first else {
            throw AppError.invalidConfiguration("备份参数不合法（库名 / 格式 / 并行数不满足该命令的要求）")
        }

        // 密码走环境变量：**不进 argv**（进程列表对所有用户可见）。
        var environment: [String: String] = [:]
        if let password, !password.isEmpty {
            environment["PGPASSWORD"] = password
        }

        let tail = LineTail(limit: Self.tailLineLimit)
        let exitCode = try await runner.run(
            executable: executable,
            arguments: Array(arguments.dropFirst()),
            environment: environment
        ) { line in
            tail.append(line)
            onOutput(line)
        }

        return BackupExecutionResult(
            exitCode: exitCode,
            outputLineCount: tail.totalCount,
            lastOutputLines: tail.lines
        )
    }

    /// 线程安全的"保留最后 N 行 + 计数"盒子。
    private final class LineTail: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private(set) var lines: [String] = []
        private(set) var totalCount = 0

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ line: String) {
            lock.lock()
            totalCount += 1
            lines.append(line)
            if lines.count > limit {
                lines.removeFirst(lines.count - limit)
            }
            lock.unlock()
        }
    }
}
