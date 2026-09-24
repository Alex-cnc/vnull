import Foundation

/// SSH 隧道相关的**派生键**与可执行文件解析（FR-CONN-18）。
///
/// **为什么要派生一个 ID**：`SecretStore` 的接口是按连接 ID 存一条口令，而 SSH 口令与数据库口令
/// 是**两个秘密**（同一条隧道可能连多个库；跳板机账号与数据库账号也常常不是同一个人）。
/// 与其改那个已经被平台实现实现过两次的接口，不如给"隧道口令"派生一个**稳定且不冲突**的键：
/// 同一连接每次算出来都一样，不同连接不会撞，也不会等于连接自己的 ID（免得覆盖数据库口令）。
///
/// 派生规则刻意写死在这里并单测：它是**持久化格式的一部分** —— 改了它，用户已保存的隧道口令就读不出来。
public enum SSHTunnelSecrets {

    /// 从连接 ID 派生「隧道口令 / 私钥口令」的存储键。
    ///
    /// 实现：把 UUID 的高 8 字节与一个固定盐做 XOR —— 可逆、无状态、两平台一致，
    /// 且对任意输入都不会等于原值（盐非零）。
    public static func secretKey(for connectionID: UUID) -> UUID {
        // 固定盐（不要改）：改了等于让所有已保存的隧道口令失效。
        let salt: [UInt8] = [0x53, 0x53, 0x48, 0x54, 0x75, 0x6E, 0x6E, 0x65,   // "SSHTunne"
                             0x6C, 0x2D, 0x44, 0x6F, 0x79, 0x61, 0x68, 0x21]   // "l-Doyah!"
        var raw = connectionID.uuid
        withUnsafeMutableBytes(of: &raw) { buffer in
            for index in 0..<min(16, buffer.count) {
                buffer[index] ^= salt[index]
            }
        }
        return UUID(uuid: raw)
    }

    /// `ssh` 可执行文件的位置。
    ///
    /// 默认用系统 `/usr/bin/ssh`；环境变量 `DOYAH_SSH_BINARY` 仅供**验收脚本**指定替身 ssh
    /// （真实 SSH 握手需要一台跳板机，脚本用替身做端到端转发验证）。生产路径不受影响。
    public static func executable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["DOYAH_SSH_BINARY"], !override.isEmpty {
            return override
        }
        return "/usr/bin/ssh"
    }
}
