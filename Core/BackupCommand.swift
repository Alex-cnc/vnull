import Foundation

/// 备份 / 恢复命令行构建（FR-IO-04）。
///
/// 两个刻意的设计：
/// 1. **只产出 argv 数组，不拼 shell 字符串** —— 库名 / 用户名里的空格、引号、`;` 都只是普通参数，
///    天然免疫命令注入（相比 `"pg_dump \(db)"` 这类拼串安全得多）。
/// 2. **不执行** —— App Sandbox 下子进程能否继承父沙箱尚未决策（见 R-18），
///    因此把「生成命令」与「执行命令」解耦：界面先能展示真实命令行与执行计划，执行留待架构选型。
///
/// 密码不进入 argv（会出现在进程列表里）：交给 `PGPASSWORD` 环境变量或 `.pgpass`。
public enum BackupCommand {

    /// `pg_dump` 的输出格式。
    public enum Format: String, Sendable {
        case plain
        case custom
        case directory
    }

    /// 连接目标。
    public struct Target: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var user: String?
        /// 单库备份必填；`pg_dumpall`（集群级）不需要。
        public var database: String?

        public init(host: String, port: Int = 5432, user: String? = nil, database: String? = nil) {
            self.host = host
            self.port = port
            self.user = user
            self.database = database
        }
    }

    // MARK: - 单库备份

    /// 生成 `pg_dump` 命令；参数不合法返回 `nil`。
    ///
    /// - `jobs` 只在 `format == .directory` 时有效（PostgreSQL 的并行导出限制）。
    public static func dump(
        target: Target,
        format: Format = .plain,
        filePath: String? = nil,
        jobs: Int? = nil,
        noOwner: Bool = false,
        clean: Bool = false
    ) -> [String]? {
        guard isValidPort(target.port),
              let database = target.database, !database.isEmpty
        else { return nil }
        if let jobs {
            guard format == .directory, jobs >= 1 else { return nil }
        }

        var argv = ["pg_dump", "--host", target.host, "--port", "\(target.port)"]
        if let user = target.user, !user.isEmpty { argv += ["--username", user] }
        argv += ["--format", format.rawValue]
        if noOwner { argv.append("--no-owner") }
        if clean { argv.append("--clean") }
        if let jobs { argv += ["--jobs", "\(jobs)"] }
        if let filePath, !filePath.isEmpty { argv += ["--file", filePath] }
        argv.append(database)
        return argv
    }

    // MARK: - 集群级备份（v3.8 扩写：pg_dumpall）

    /// 生成 `pg_dumpall` 命令（集群级：角色、表空间等全局对象 + 各库）；
    /// 参数不合法返回 `nil`。
    ///
    /// `rolesOnly` 与 `globalsOnly` 互斥（PostgreSQL 自身不允许同时指定）。
    public static func dumpAll(
        target: Target,
        filePath: String? = nil,
        rolesOnly: Bool = false,
        globalsOnly: Bool = false,
        noRolePasswords: Bool = false,
        clean: Bool = false
    ) -> [String]? {
        guard isValidPort(target.port) else { return nil }
        if rolesOnly && globalsOnly { return nil }

        var argv = ["pg_dumpall", "--host", target.host, "--port", "\(target.port)"]
        if let user = target.user, !user.isEmpty { argv += ["--username", user] }
        if rolesOnly { argv.append("--roles-only") }
        if globalsOnly { argv.append("--globals-only") }
        if noRolePasswords { argv.append("--no-role-passwords") }
        if clean { argv.append("--clean") }
        if let filePath, !filePath.isEmpty { argv += ["--file", filePath] }
        return argv
    }

    // MARK: - 恢复

    /// 生成 `pg_restore` 命令（custom / directory 归档）；参数不合法返回 `nil`。
    ///
    /// 归档文件放在 argv 末尾（`pg_restore` 的位置参数）。
    public static func restore(
        target: Target,
        archivePath: String,
        clean: Bool = false,
        jobs: Int? = nil,
        section: String? = nil
    ) -> [String]? {
        guard isValidPort(target.port),
              !archivePath.isEmpty,
              let database = target.database, !database.isEmpty
        else { return nil }
        if let jobs, jobs < 1 { return nil }

        var argv = ["pg_restore", "--host", target.host, "--port", "\(target.port)"]
        if let user = target.user, !user.isEmpty { argv += ["--username", user] }
        argv += ["--dbname", database]
        if clean { argv.append("--clean") }
        if let jobs { argv += ["--jobs", "\(jobs)"] }
        if let section, !section.isEmpty { argv += ["--section", section] }
        argv.append(archivePath)
        return argv
    }

    /// 端口合法性（与连接配置同一口径）。
    static func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }
}
