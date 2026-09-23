import Foundation

/// 备份工具与服务器的**版本兼容性**（FR-IO-04 的前置检查）。
///
/// 为什么需要它：PostgreSQL 的规则是——**`pg_dump` 只能导出「不比自己新」的服务器**。
/// 本机实测撞到过：客户端 `pg_dump` 是 16.2，目标是 18.6 的服务器，跑到一半被拒：
/// `pg_dump: error: aborting because of server version mismatch / server version: 18.6; pg_dump version: 16.2`。
/// 错误本身没错，但**发现得太晚**（用户已经等了一会儿），而且这句话对非 DBA 并不直观。
///
/// 因此在执行前先比一次版本，把"能不能做、为什么不能"讲清楚 —— 这是**预防**，不是替代服务端校验。
public enum BackupToolCompatibility: Equatable, Sendable {

    /// 解析失败（拿不到版本）时的结论：**不知道就说不确定**，不假装兼容。
    case unknown(reason: String)
    case compatible
    /// 工具比服务器旧：按 PostgreSQL 规则会被拒绝。
    case toolOlderThanServer(toolMajor: Int, serverMajor: Int)
    /// 工具比服务器新 —— 允许（pg_dump 能导出更老的服务器）。
    case toolNewerThanServer(toolMajor: Int, serverMajor: Int)

    public var isUsable: Bool {
        switch self {
        case .compatible, .toolNewerThanServer: return true
        case .toolOlderThanServer, .unknown: return false
        }
    }
}

public enum BackupToolCheck {

    /// 判定兼容性。`restore` 场景传入的是 `pg_restore` 版本。
    public static func evaluate(toolVersion: DatabaseVersion?, serverVersion: DatabaseVersion?) -> BackupToolCompatibility {
        guard let toolVersion, toolVersion.major > 0 else {
            return .unknown(reason: "拿不到备份工具的版本（`--version` 输出无法解析）")
        }
        guard let serverVersion, serverVersion.major > 0 else {
            return .unknown(reason: "拿不到服务器版本")
        }

        if toolVersion.major < serverVersion.major {
            return .toolOlderThanServer(toolMajor: toolVersion.major, serverMajor: serverVersion.major)
        }
        if toolVersion.major > serverVersion.major {
            return .toolNewerThanServer(toolMajor: toolVersion.major, serverMajor: serverVersion.major)
        }
        return .compatible
    }

    /// 可读诊断（界面 / CLI 直接展示）。`nil` = 没问题，不必打扰用户。
    ///
    /// 文案里要给出**怎么办**：这类问题的答案永远是"装一个版本 ≥ 服务端的客户端工具"，
    /// 而工具在哪往往不好找（本机就在 `~/tools/pgserver/.../bin` 这种地方）。
    public static func diagnosis(for compatibility: BackupToolCompatibility, toolName: String) -> String? {
        switch compatibility {
        case .compatible, .toolNewerThanServer:
            return nil
        case .toolOlderThanServer(let toolMajor, let serverMajor):
            return """
            备份工具版本低于服务器：\(toolName) 是 \(toolMajor)，服务器是 \(serverMajor)（PostgreSQL 主版本）。\
            PostgreSQL 的 \(toolName) 只能处理「不比自己新」的服务器，继续执行一定会被拒绝。\
            请换用与服务器同主版本或更新的 \(toolName)（可用 --tool 指定绝对路径）。
            """
        case .unknown(let reason):
            return "无法确认备份工具与服务器的版本兼容性：\(reason)。继续执行可能中途失败。"
        }
    }

    /// 从 `<tool> --version` 的输出里取版本号（例如 `pg_dump (PostgreSQL) 16.2`）。
    public static func parseToolVersion(_ output: String) -> DatabaseVersion? {
        // 输出形如 `pg_dump (PostgreSQL) 16.2` / `pg_restore (PostgreSQL) 18.6 (Debian 18.6-1)`。
        // 次版本与补丁号都可选：存在只打主版本的构建，容错比严格更重要（拿不到版本才是不兼容的结论）。
        let pattern = #"(\d+)(?:\.(\d+))?(?:\.(\d+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range) else { return nil }

        func number(at index: Int) -> Int? {
            guard let sub = Range(match.range(at: index), in: output) else { return nil }
            return Int(output[sub])
        }
        guard let major = number(at: 1) else { return nil }
        return DatabaseVersion(
            major: major,
            minor: number(at: 2) ?? 0,
            patch: number(at: 3) ?? 0,
            raw: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
