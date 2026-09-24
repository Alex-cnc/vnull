import Foundation

/// SSH 隧道配置（FR-CONN-18）：通过跳板机连不可直连的数据库。
///
/// **为什么把"参数拼装"单列一层**：`ssh` 的参数一旦写错，症状是"连不上但看不出为什么"
/// （口令被拒？转发没建立？主机指纹变了？）。这些差异全在**十几个 `-o` 选项**里，
/// 而它们是纯字符串拼接 —— 放 Core 里逐条单测，比在界面里点着试靠谱得多。
///
/// **安全口径（写清楚，不含糊）**：
///   · 口令 / 私钥口令一律走 `SecretStore`（与数据库口令**分开存**），不进配置文件、不进 argv；
///   · 口令模式下用 `SSH_ASKPASS` 把口令交给 `ssh`（见 `SSHTunnelProcess` 的说明），
///     临时文件 0600、握手完立刻删 —— 威胁模型仍是"同一用户"，这一点如实写在文档里；
///   · 私钥路径**只是路径**，我们不读它的内容；
///   · 主机指纹默认 `accept-new`（首次信任、之后变了就拒），可用 `strict` 收紧。
public struct SSHTunnelConfig: Codable, Hashable, Sendable {

    /// 认证方式。
    public enum Authentication: Codable, Hashable, Sendable {
        /// 口令认证。口令本身存 `SecretStore`，这里只声明"用口令"。
        case password
        /// 私钥文件（路径 + 私钥是否有口令；有口令时口令也存 `SecretStore`）。
        case privateKey(path: String, isEncrypted: Bool)
        /// 交给 `ssh-agent`（私钥不出代理，最安全的一种）。
        case agent
    }

    /// 主机指纹策略。
    public enum HostKeyPolicy: String, Codable, Hashable, Sendable, CaseIterable {
        /// 首次见到就信任，**之后再变就拒绝**（`accept-new`）。
        case acceptNew
        /// 必须已存在于我们的 `known_hosts`（`yes`）。
        case strict
    }

    public var isEnabled: Bool
    public var host: String
    public var port: Int
    public var username: String
    public var authentication: Authentication
    public var hostKeyPolicy: HostKeyPolicy
    /// 建隧道与握手的超时（秒）。
    public var connectTimeoutSeconds: Int

    public static let defaultPort = 22
    public static let defaultTimeoutSeconds = 15

    public init(
        isEnabled: Bool = true,
        host: String = "",
        port: Int = SSHTunnelConfig.defaultPort,
        username: String = "",
        authentication: Authentication = .agent,
        hostKeyPolicy: HostKeyPolicy = .acceptNew,
        connectTimeoutSeconds: Int = SSHTunnelConfig.defaultTimeoutSeconds
    ) {
        self.isEnabled = isEnabled
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.hostKeyPolicy = hostKeyPolicy
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    /// 配置里**说得清**的问题（界面直接照着显示；文案在界面层，Core 只给种类）。
    ///
    /// 为什么返回枚举而不是字符串：Core 的展示文案必须走 `LocalizedStrings`（本地化棘轮守着），
    /// 而"哪个字段不合法"是规则、不是文案。
    public enum Issue: Hashable, Sendable {
        case missingHost
        case missingUsername
        case invalidPort
        case missingPrivateKeyPath
        case invalidTimeout
    }

    public func issues() -> [Issue] {
        var result: [Issue] = []
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.missingHost) }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.missingUsername) }
        if port < 1 || port > 65_535 { result.append(.invalidPort) }
        if connectTimeoutSeconds < 1 || connectTimeoutSeconds > 600 { result.append(.invalidTimeout) }
        if case .privateKey(let path, _) = authentication,
           path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.missingPrivateKeyPath)
        }
        return result
    }

    public var isValid: Bool { issues().isEmpty }

    /// 界面上显示成一行：「user@host:22 · 私钥」。
    public var displayName: String {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = user.isEmpty ? host : "\(user)@\(host)"
        let suffix: String
        switch authentication {
        case .password: suffix = "password"
        case .privateKey: suffix = "key"
        case .agent: suffix = "agent"
        }
        return "\(head):\(port) · \(suffix)"
    }
}

/// 隧道要转发到哪里（就是数据库地址）。
public struct SSHTunnelTarget: Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// 数据库配置里那种"本机地址"要特殊照顾：跳板机上的 `127.0.0.1` 指的是**跳板机自己**，
    /// 那正是最常见的一种用法（数据库只监听跳板机的回环）。所以**不改写** —— 这一条容易被"优化"掉，
    /// 写在这里当提醒。
    public var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host.lowercased())
    }
}

/// `ssh` 命令行参数拼装（纯函数，逐条可测）。
public enum SSHTunnelArguments {

    /// 拼出完整的 `ssh` 参数表（不含可执行文件本身）。
    ///
    /// - Parameters:
    ///   - localPort: 本机监听端口（`-L` 的左半边）。
    ///   - knownHostsPath: 我们自己的 `known_hosts` —— **不动用户的 `~/.ssh/known_hosts`**：
    ///     一个数据库客户端偷偷往用户的 SSH 信任库里写东西，是不可接受的副作用。
    public static func make(
        config: SSHTunnelConfig,
        localPort: Int,
        target: SSHTunnelTarget,
        knownHostsPath: String,
        passwordMode: Bool
    ) -> [String] {
        var arguments: [String] = []
        // 只做端口转发，不在远端开 shell。
        arguments += ["-N"]
        arguments += ["-L", "\(localPort):\(target.host):\(target.port)"]
        arguments += ["-p", "\(config.port)"]
        arguments += ["-o", "ExitOnForwardFailure=yes"]
        arguments += ["-o", "ConnectTimeout=\(config.connectTimeoutSeconds)"]
        arguments += ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        arguments += ["-o", "StrictHostKeyChecking=\(config.hostKeyPolicy == .strict ? "yes" : "accept-new")"]
        arguments += ["-o", "UserKnownHostsFile=\(knownHostsPath)"]
        // 关上各种会自动"帮忙"的东西：我们要的是确定性，不是便利。
        arguments += ["-o", "ForwardAgent=no"]
        arguments += ["-o", "PermitLocalCommand=no"]
        arguments += ["-o", "RequestTTY=no"]

        switch config.authentication {
        case .password:
            // 口令模式：非交互（BatchMode=yes）会直接失败，所以要关掉它；
            // 认证方式**只留 password**，免得 ssh 先试着用本机私钥、把口令提示推到后面。
            arguments += ["-o", "BatchMode=no", "-o", "PreferredAuthentications=password,keyboard-interactive"]
            arguments += ["-o", "NumberOfPasswordPrompts=1"]
        case .privateKey(let path, _):
            arguments += ["-i", path]
            // `IdentitiesOnly=yes`：**只**用我们指定的这把钥匙，不去翻 ssh-agent / 默认钥匙 ——
            // 否则"配了 A 却用 B 连上"这种事会让人查一整天。
            arguments += ["-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes"]
            arguments += ["-o", "PreferredAuthentications=publickey"]
        case .agent:
            arguments += ["-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey"]
        }

        arguments += ["\(config.username)@\(config.host)"]
        _ = passwordMode     // 口令是否真的由 askpass 提供，由进程层决定；这里只保证参数一致
        return arguments
    }
}
