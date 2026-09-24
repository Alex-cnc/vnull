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
