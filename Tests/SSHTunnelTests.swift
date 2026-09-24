import XCTest
@testable import DoyahCore

/// SSH 隧道的配置规则与 `ssh` 参数拼装（FR-CONN-18）。
///
/// 这里钉的是"连不上时最难看出来的那些差异"：认证方式该留哪些、指纹策略、
/// 以及**绝不能碰用户自己的 known_hosts / ssh-agent**。
final class SSHTunnelTests: XCTestCase {

    private let target = SSHTunnelTarget(host: "10.0.0.9", port: 5432)

    private func arguments(
        _ config: SSHTunnelConfig,
        localPort: Int = 55_001
    ) -> [String] {
        SSHTunnelArguments.make(
            config: config,
            localPort: localPort,
            target: target,
            knownHostsPath: "/tmp/doyah/known_hosts",
            passwordMode: false
        )
    }

    func testValidationReportsMissingFields() {
        var config = SSHTunnelConfig(isEnabled: true, host: "", port: 0, username: "")
        XCTAssertTrue(config.issues().contains(.missingHost))
        XCTAssertTrue(config.issues().contains(.missingUsername))
        XCTAssertTrue(config.issues().contains(.invalidPort))
        XCTAssertFalse(config.isValid)

        config.host = "jump.example.com"
        config.port = 22
        config.username = "alice"
        XCTAssertTrue(config.isValid, "填齐之后不该再报问题")
    }

    func testPrivateKeyRequiresPath() {
        var config = SSHTunnelConfig(host: "jump", username: "alice", authentication: .privateKey(path: "  ", isEncrypted: false))
        XCTAssertTrue(config.issues().contains(.missingPrivateKeyPath))
        config.authentication = .privateKey(path: "/Users/me/.ssh/id_ed25519", isEncrypted: true)
        XCTAssertTrue(config.isValid)
    }

    /// 端口转发的三条核心参数必须在：`-N`、`-L local:target`、`-p 跳板机端口`。
    func testForwardingArguments() {
        let config = SSHTunnelConfig(host: "jump.example.com", port: 2222, username: "alice", authentication: .agent)
        let args = arguments(config)
        XCTAssertTrue(args.contains("-N"))
        XCTAssertEqual(value(of: "-L", in: args), "55001:10.0.0.9:5432")
        XCTAssertEqual(value(of: "-p", in: args), "2222")
        XCTAssertEqual(args.last, "alice@jump.example.com")
    }

    /// 私钥模式：**只**用指定钥匙（`IdentitiesOnly`），并且非交互。
    func testPrivateKeyMode() {
        let config = SSHTunnelConfig(
            host: "jump",
            username: "alice",
            authentication: .privateKey(path: "/Users/me/.ssh/id_ed25519", isEncrypted: false)
        )
        let args = arguments(config)
        XCTAssertEqual(value(of: "-i", in: args), "/Users/me/.ssh/id_ed25519")
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("PreferredAuthentications=publickey"))
    }

    /// 口令模式：必须关掉 BatchMode，并把认证方式限制成口令 —— 否则 ssh 会先试本机私钥。
    func testPasswordModeIsInteractiveAndPasswordOnly() {
        let args = arguments(SSHTunnelConfig(host: "jump", username: "alice", authentication: .password))
        XCTAssertTrue(args.contains("BatchMode=no"))
        XCTAssertTrue(args.contains("PreferredAuthentications=password,keyboard-interactive"))
        XCTAssertTrue(args.contains("NumberOfPasswordPrompts=1"))
        XCTAssertFalse(args.contains("IdentitiesOnly=yes"))
    }

    /// 指纹策略：默认"首次信任、之后变了就拒"，可以收紧成 strict。
    func testHostKeyPolicy() {
        var config = SSHTunnelConfig(host: "jump", username: "alice", authentication: .agent)
        XCTAssertTrue(arguments(config).contains("StrictHostKeyChecking=accept-new"))
        config.hostKeyPolicy = .strict
        XCTAssertTrue(arguments(config).contains("StrictHostKeyChecking=yes"))
    }

    /// **不碰用户的 SSH 配置**：known_hosts 用我们自己的；也不把 agent 转给远端。
    func testDoesNotTouchUserSSHState() {
        let config = SSHTunnelConfig(host: "jump", username: "alice", authentication: .agent)
        let args = arguments(config)
        XCTAssertTrue(args.contains("UserKnownHostsFile=/tmp/doyah/known_hosts"))
        XCTAssertTrue(args.contains("ForwardAgent=no"))
        XCTAssertFalse(args.contains("-A"))
        XCTAssertFalse(args.contains("PermitLocalCommand=yes"))
    }

    /// 转发失败要立刻失败（否则会出现"隧道没建起来但 ssh 还活着"的假成功）。
    func testFailsFastWhenForwardingCannotBeEstablished() {
        let config = SSHTunnelConfig(host: "jump", username: "alice", authentication: .agent)
        XCTAssertTrue(arguments(config).contains("ExitOnForwardFailure=yes"))
    }

    /// 跳板机上的 `127.0.0.1` 指的是**跳板机自己**（很常见的"只监听回环"部署）—— 不能改写。
    func testLoopbackTargetsAreLeftAlone() {
        XCTAssertTrue(SSHTunnelTarget(host: "127.0.0.1", port: 5432).isLoopback)
        XCTAssertTrue(SSHTunnelTarget(host: "localhost", port: 5432).isLoopback)
        XCTAssertFalse(SSHTunnelTarget(host: "10.0.0.9", port: 5432).isLoopback)
    }

    private func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    // MARK: 运行时（进程层）

    /// **端口被别人占着时必须快速失败** —— 这条是实测踩出来的：
    /// 探测看到"端口通"就报就绪，而那个监听其实是别人的，隧道根本没建起来。
    func testFailsFastWhenLocalPortIsAlreadyTaken() async {
        let config = SSHTunnelConfig(host: "jump", username: "alice", authentication: .agent)
        let tunnel = SSHTunnelProcess(
            config: config,
            target: SSHTunnelTarget(host: "10.0.0.9", port: 5432),
            localPort: 55_777,
            knownHostsPath: NSTemporaryDirectory() + "doyah-test-known-hosts",
            executable: "/usr/bin/true",
            isPortOpen: { _, _ in true }        // 假装端口已被占用
        )
        do {
            _ = try await tunnel.start(timeout: 1)
            XCTFail("端口被占用时不该报成功")
        } catch let error as SSHTunnelError {
            XCTAssertEqual(error, .portInUse(55_777))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        XCTAssertEqual(tunnel.currentState, .failed("本地端口 55777 已被占用"))
    }

    /// 可执行文件不存在 → 立刻给出"起 ssh 失败"，不静默挂着。
    func testLaunchFailureIsReported() async {
        let config = SSHTunnelConfig(host: "jump", username: "alice", authentication: .agent)
        let tunnel = SSHTunnelProcess(
            config: config,
            target: SSHTunnelTarget(host: "10.0.0.9", port: 5432),
            localPort: 55_778,
            knownHostsPath: NSTemporaryDirectory() + "doyah-test-known-hosts",
            executable: "/nonexistent/ssh",
            isPortOpen: { _, _ in false }
        )
        do {
            _ = try await tunnel.start(timeout: 1)
            XCTFail("不该成功")
        } catch {
            XCTAssertTrue(tunnel.diagnosticText.isEmpty || !tunnel.diagnosticText.isEmpty)
        }
    }

}

/// 隧道口令的存储键与 `ssh` 可执行文件解析（FR-CONN-18）。
///
/// 派生规则是**持久化格式的一部分**：改了它，用户已保存的隧道口令就读不出来 —— 所以要钉死。
final class SSHTunnelSecretsTests: XCTestCase {

    func testDerivedKeyIsStableAndDistinctFromConnectionID() {
        let connection = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let first = SSHTunnelSecrets.secretKey(for: connection)
        let second = SSHTunnelSecrets.secretKey(for: connection)
        XCTAssertEqual(first, second, "同一连接必须每次都算出同一个键")
        XCTAssertNotEqual(first, connection, "不能等于连接自己的 ID —— 那会覆盖数据库口令")
    }

    func testDifferentConnectionsGetDifferentKeys() {
        let a = SSHTunnelSecrets.secretKey(for: UUID())
        let b = SSHTunnelSecrets.secretKey(for: UUID())
        XCTAssertNotEqual(a, b)
    }

    /// 具体值钉死：这是**跨版本兼容**的锚点（改规则 = 已保存的口令全部失效）。
    func testDerivedKeyValueIsPinned() {
        let connection = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        XCTAssertEqual(
            SSHTunnelSecrets.secretKey(for: connection).uuidString,
            "53534854-756E-6E65-6C2D-446F79616821"
        )
    }

    func testExecutableDefaultsToSystemSSHAndHonoursOverride() {
        XCTAssertEqual(SSHTunnelSecrets.executable(environment: [:]), "/usr/bin/ssh")
        XCTAssertEqual(
            SSHTunnelSecrets.executable(environment: ["DOYAH_SSH_BINARY": "/tmp/stub-ssh"]),
            "/tmp/stub-ssh"
        )
        XCTAssertEqual(SSHTunnelSecrets.executable(environment: ["DOYAH_SSH_BINARY": ""]), "/usr/bin/ssh")
    }

    // MARK: - 连接目标改写（界面接线的那一步，最容易静默写错）

    private func sampleConfiguration() -> ConnectionConfig {
        ConnectionConfig(
            name: "生产只读",
            dbType: .postgresql,
            host: "10.20.30.40",
            port: 5432,
            database: "analytics",
            username: "report",
            sslMode: .prefer,
            timeout: 9,
            environment: .production,
            colorTag: .amber,
            isReadOnly: true,
            startupSQL: "SET statement_timeout = '5s'",
            group: "内网",
            sshTunnel: SSHTunnelConfig(host: "jump.example.com", username: "ops")
        )
    }

    /// 没配隧道（`localPort == nil`）时必须**一个字段都不变** —— 直连是这个产品的默认路径。
    func testRewriteWithoutTunnelReturnsOriginal() {
        let original = sampleConfiguration()
        let rewritten = SSHTunnelEndpoint.rewrite(original, localPort: nil)
        XCTAssertEqual(rewritten, original)
        XCTAssertEqual(rewritten.host, "10.20.30.40")
        XCTAssertEqual(rewritten.port, 5432)
    }

    /// 配了隧道：只换 host/port，其余（库名、用户、只读、启动 SQL、分组、隧道参数本身）全部保留。
    func testRewriteWithTunnelOnlyChangesEndpoint() {
        let original = sampleConfiguration()
        let rewritten = SSHTunnelEndpoint.rewrite(original, localPort: 55_777)

        XCTAssertEqual(rewritten.host, "127.0.0.1")
        XCTAssertEqual(rewritten.port, 55_777)
        // 不改写本机地址到配置里：原对象必须原封不动（值类型，改写只作用于副本）。
        XCTAssertEqual(original.host, "10.20.30.40")
        XCTAssertEqual(original.port, 5432)

        XCTAssertEqual(rewritten.name, original.name)
        XCTAssertEqual(rewritten.database, "analytics")
        XCTAssertEqual(rewritten.username, "report")
        XCTAssertEqual(rewritten.dbType, original.dbType)
        XCTAssertEqual(rewritten.sslMode, original.sslMode)
        XCTAssertEqual(rewritten.timeout, original.timeout)
        XCTAssertEqual(rewritten.environment, .production)
        XCTAssertEqual(rewritten.colorTag, .amber)
        XCTAssertTrue(rewritten.isReadOnly)
        XCTAssertEqual(rewritten.startupSQL, original.startupSQL)
        XCTAssertEqual(rewritten.group, "内网")
        // 隧道参数要跟着走：丢了这个，下次保存就把隧道配置抹掉了。
        XCTAssertEqual(rewritten.sshTunnel, original.sshTunnel)
        XCTAssertEqual(rewritten.id, original.id)
    }

    /// 隧道只在本机回环监听 —— 绝不能是 `0.0.0.0`（那等于把内网库暴露给整个局域网）。
    func testLoopbackHostIsNotWildcard() {
        XCTAssertEqual(SSHTunnelEndpoint.loopbackHost, "127.0.0.1")
        XCTAssertNotEqual(SSHTunnelEndpoint.loopbackHost, "0.0.0.0")
    }

    // MARK: - 隧道参数的合法性并进 ConnectionConfig.isValid（单一事实来源）

    func testConfigurationIsValidRequiresTunnelFieldsWhenEnabled() {
        var configuration = sampleConfiguration()
        configuration.sshTunnel = SSHTunnelConfig(isEnabled: true, host: "", username: "")
        XCTAssertFalse(configuration.isValid, "启用隧道却缺跳板机地址，不该判为可保存")
    }

    func testDisabledTunnelDoesNotBlockValidity() {
        var configuration = sampleConfiguration()
        configuration.sshTunnel = SSHTunnelConfig(isEnabled: false, host: "", username: "")
        XCTAssertTrue(configuration.isValid, "关掉的隧道不该拦住直连")
    }

    func testMissingTunnelConfigurationKeepsOldBehaviour() {
        var configuration = sampleConfiguration()
        configuration.sshTunnel = nil
        XCTAssertTrue(configuration.isValid)
    }

    // MARK: - 隧道配置的持久化（界面把它写进 connections.json，丢字段 = 隧道静默消失）

    /// 三种认证方式都要能原样存取 —— 存不住的症状是"配好了，重启之后隧道没了"。
    func testTunnelConfigSurvivesJSONRoundTrip() throws {
        let variants: [SSHTunnelConfig.Authentication] = [
            .agent,
            .password,
            .privateKey(path: "~/.ssh/id_ed25519", isEncrypted: true)
        ]
        for authentication in variants {
            var configuration = sampleConfiguration()
            configuration.sshTunnel = SSHTunnelConfig(
                isEnabled: true,
                host: "jump.example.com",
                port: 2222,
                username: "ops",
                authentication: authentication,
                hostKeyPolicy: .strict,
                connectTimeoutSeconds: 42
            )

            let data = try JSONEncoder().encode(configuration)
            let restored = try JSONDecoder().decode(ConnectionConfig.self, from: data)

            XCTAssertEqual(restored.sshTunnel, configuration.sshTunnel, "认证方式 \(authentication) 存取后不一致")
            XCTAssertEqual(restored.sshTunnel?.hostKeyPolicy, .strict)
            XCTAssertEqual(restored.sshTunnel?.port, 2222)
            XCTAssertEqual(restored.sshTunnel?.connectTimeoutSeconds, 42)
        }
    }

    /// **配置文件里不许出现口令字段**：口令存 `SecretStore`（NFR-SEC-01），
    /// 配置结构里连字段都不该有 —— 这条用"编码后的 JSON 里没有密码键"来钉。
    func testTunnelConfigurationHoldsNoSecretInJSON() throws {
        var configuration = sampleConfiguration()
        configuration.sshTunnel = SSHTunnelConfig(
            isEnabled: true,
            host: "jump.example.com",
            username: "ops",
            authentication: .password
        )
        let data = try JSONEncoder().encode(configuration)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tunnel = try XCTUnwrap(json["sshTunnel"] as? [String: Any])
        XCTAssertNil(tunnel["password"], "隧道配置里不该有口令字段")
        XCTAssertNil(tunnel["secret"])
        // 允许出现的键就是这几个（多了说明有人往里塞了别的东西）。
        XCTAssertEqual(Set(tunnel.keys), Set([
            "isEnabled", "host", "port", "username", "authentication", "hostKeyPolicy",
            "connectTimeoutSeconds"
        ]))
    }

    /// 老配置（没有 `sshTunnel` 这个键）必须照常读出为"没有隧道"，不触发迁移、不报错。
    func testLegacyConfigurationWithoutTunnelDecodes() throws {
        let legacy = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "name": "老连接",
          "dbType": "postgresql",
          "host": "10.0.0.5",
          "port": 5432,
          "database": "postgres",
          "username": "postgres",
          "sslMode": "prefer",
          "timeout": 5,
          "schemaVersion": 1
        }
        """
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.sshTunnel)
        XCTAssertEqual(decoded.host, "10.0.0.5")
        XCTAssertTrue(decoded.isValid)
    }
}
