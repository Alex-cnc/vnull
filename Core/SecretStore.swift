import Foundation

/// 连接密码的存储抽象（NFR-SEC-01 / NFR-SEC-02）。
///
/// **为什么只有协议**：Core 必须在两个平台上都能编译，而系统凭据存储是平台专属的
/// （macOS 钥匙串要 `import Security`，Linux 用 Secret Service 或「文件 + 0600 权限」）。
/// 所以 Core 只声明行为，实现放平台模块：
///   · macOS → `Platform/macOS/KeychainSecretStore.swift`
///   · Linux → 待建（见需求书 §10.9 P-02 与概要设计 §3 平台适配层契约）
///
/// 契约（两侧一致）：密码**不落配置文件**、重启后可恢复、可被明确清除、
/// 不出现在错误信息或日志里。
public protocol SecretStore: Sendable {
    func setPassword(_ password: String, for connectionID: UUID) throws
    func password(for connectionID: UUID) throws -> String?
    func deletePassword(for connectionID: UUID) throws
}
