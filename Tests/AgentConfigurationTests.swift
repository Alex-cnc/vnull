import XCTest
@testable import DoyahCore

/// 测试用内存密钥库：不碰真实钥匙串。
private final class InMemoryAgentKeyStore: AgentKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?
    private var writes = 0

    func setAPIKey(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage = key
        writes += 1
    }

    func apiKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func deleteAPIKey() throws {
        lock.lock()
        defer { lock.unlock() }
        storage = nil
    }

    var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }
}

/// FR-AI-01 / NFR-AI-02 / NFR-AI-04：智能体接入配置、外发闸门与配额模型。
final class AgentConfigurationTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConfigurationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func remoteConfiguration(isEnabled: Bool = true) -> AgentConfiguration {
        AgentConfiguration(
            isEnabled: isEnabled,
            endpoint: "https://api.example.com/v1",
            model: "gpt-4o-mini"
        )
    }

    private func localConfiguration(isEnabled: Bool = true) -> AgentConfiguration {
        AgentConfiguration(
            isEnabled: isEnabled,
            endpoint: "http://127.0.0.1:11434/v1",
            model: "qwen2.5:7b"
        )
    }

    // MARK: - 安全默认

    /// 装好软件时不应自己往外发东西：默认关闭且端点 / 模型为空。
    func testDefaultConfigurationIsDisabledAndIncomplete() {
        let configuration = AgentConfiguration.default

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.endpoint, "")
        XCTAssertEqual(configuration.model, "")
        XCTAssertEqual(configuration.timeoutSeconds, 60)
        XCTAssertTrue(configuration.quota.isUnlimited)
        XCTAssertFalse(configuration.isComplete)
        XCTAssertEqual(
            AgentGate.decide(configuration: configuration, apiKey: "sk-whatever"),
            .disabled
        )
    }

    // MARK: - 总开关（AC-AI-01）

    /// 关闭总开关后即使端点 / 模型 / 密钥全都配好，也一律不外发。
    func testDisabledSwitchBlocksOutboundEvenWhenFullyConfigured() {
        let remote = remoteConfiguration(isEnabled: false)

        XCTAssertTrue(remote.isComplete, "配置本身是完整的")
        XCTAssertEqual(AgentGate.decide(configuration: remote, apiKey: "sk-abcdef"), .disabled)
        XCTAssertFalse(AgentGate.decide(configuration: remote, apiKey: "sk-abcdef").isAllowed)
    }

    /// 关闭时连「配置有问题」都不必暴露：直接 `.disabled`。
    func testDisabledSwitchWinsOverMisconfiguration() {
        let broken = AgentConfiguration(isEnabled: false, endpoint: "not a url", model: "  ")

        XCTAssertEqual(AgentGate.decide(configuration: broken, apiKey: nil), .disabled)
    }

    // MARK: - 闸门

    func testLocalEndpointNeedsNoAPIKey() throws {
        let decision = AgentGate.decide(configuration: localConfiguration(), apiKey: nil)

        guard case .allowed(let endpoint, let model, let warnings) = decision else {
            return XCTFail("本地端点应当放行，实际：\(decision)")
        }
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(model, "qwen2.5:7b")
        XCTAssertTrue(warnings.isEmpty)
    }

    func testRemoteEndpointRequiresAPIKey() {
        XCTAssertEqual(
            AgentGate.decide(configuration: remoteConfiguration(), apiKey: nil),
            .missingAPIKey
        )
        XCTAssertEqual(
            AgentGate.decide(configuration: remoteConfiguration(), apiKey: "   "),
            .missingAPIKey
        )
        XCTAssertTrue(AgentGate.decide(configuration: remoteConfiguration(), apiKey: "sk-1").isAllowed)
    }

    func testGateReportsConfigurationIssues() {
        let empty = AgentConfiguration(isEnabled: true)
        XCTAssertEqual(
            AgentGate.decide(configuration: empty, apiKey: "sk-1"),
            .misconfigured([.emptyEndpoint, .emptyModel])
        )

        let badEndpoint = AgentConfiguration(isEnabled: true, endpoint: "ftp://example.com", model: "m")
        XCTAssertEqual(
            AgentGate.decide(configuration: badEndpoint, apiKey: "sk-1"),
            .misconfigured([.invalidEndpoint])
        )
    }

    func testEndpointParsing() {
        XCTAssertNil(AgentConfiguration(endpoint: "").endpointURL)
        XCTAssertNil(AgentConfiguration(endpoint: "   ").endpointURL)
        XCTAssertNil(AgentConfiguration(endpoint: "example.com/v1").endpointURL, "缺少 scheme")
        XCTAssertNil(AgentConfiguration(endpoint: "ftp://example.com").endpointURL, "非 http(s)")
        XCTAssertNil(AgentConfiguration(endpoint: "http://").endpointURL, "缺少主机")

        let normalized = AgentConfiguration(endpoint: "  https://api.example.com/v1  ")
        XCTAssertEqual(normalized.endpointURL?.host, "api.example.com")
    }

    func testModelNameIsTrimmed() {
        XCTAssertNil(AgentConfiguration(model: "   ").normalizedModel)
        XCTAssertEqual(AgentConfiguration(model: "  qwen2.5:7b ").normalizedModel, "qwen2.5:7b")
    }

    func testTimeoutBounds() {
        XCTAssertTrue(AgentConfiguration(endpoint: "https://a.example.com", model: "m", timeoutSeconds: 1).isComplete)
        XCTAssertTrue(AgentConfiguration(endpoint: "https://a.example.com", model: "m", timeoutSeconds: 600).isComplete)

        for invalid in [0, -1, 600.5, 10_000] {
            let configuration = AgentConfiguration(
                endpoint: "https://a.example.com", model: "m", timeoutSeconds: invalid
            )
            XCTAssertTrue(
                configuration.issues.contains(.invalidTimeout),
                "\(invalid) 秒应当被拒绝"
            )
        }
    }

    /// 本地 / 局域网端点识别（NFR-AI-06）。
    func testLocalEndpointDetection() {
        let locals = [
            "http://localhost:11434/v1",
            "http://ollama.local:11434/v1",
            "http://127.0.0.1:8080/v1",
            "http://127.9.9.9/v1",
            "http://10.0.0.7/v1",
            "http://192.168.1.50:8000/v1",
            "http://172.16.3.4/v1",
            "http://172.31.255.254/v1",
            "http://169.254.10.10/v1",
            "http://[::1]:8080/v1",
            "http://[fd00::1]:8080/v1"
        ]
        for endpoint in locals {
            XCTAssertTrue(
                AgentConfiguration(endpoint: endpoint).isLocalEndpoint,
                "\(endpoint) 应当判为本地"
            )
            XCTAssertFalse(AgentConfiguration(endpoint: endpoint).requiresAPIKey)
        }

        let remotes = [
            "https://api.example.com/v1",
            "https://8.8.8.8/v1",
            "http://172.32.0.1/v1",
            "http://192.169.1.1/v1",
            "http://11.0.0.1/v1"
        ]
        for endpoint in remotes {
            XCTAssertFalse(
                AgentConfiguration(endpoint: endpoint).isLocalEndpoint,
                "\(endpoint) 不应判为本地"
            )
            XCTAssertTrue(AgentConfiguration(endpoint: endpoint).requiresAPIKey)
        }
    }

    /// 远端明文 http 会给警告（不阻断），https 与本地 http 都不警告。
    func testInsecureRemoteEndpointWarning() {
        XCTAssertEqual(
            AgentConfiguration(endpoint: "http://api.example.com/v1").warnings,
            [.insecureRemoteEndpoint]
        )
        XCTAssertTrue(AgentConfiguration(endpoint: "https://api.example.com/v1").warnings.isEmpty)
        XCTAssertTrue(AgentConfiguration(endpoint: "http://127.0.0.1:11434/v1").warnings.isEmpty)
    }

    func testDecisionMessagesAreReadable() {
        XCTAssertTrue(
            AgentGate.decide(configuration: remoteConfiguration(isEnabled: false), apiKey: nil)
                .message.contains("总开关")
        )
        XCTAssertTrue(AgentGate.decide(configuration: AgentConfiguration(isEnabled: true), apiKey: nil)
            .message.contains("端点"))
        XCTAssertTrue(AgentGate.decide(configuration: remoteConfiguration(), apiKey: nil)
            .message.contains("API Key"))
    }

    // MARK: - 配额（NFR-AI-04）

    func testQuotaValidationRejectsNonPositiveLimits() {
        XCTAssertTrue(AgentQuota().isUnlimited)
        XCTAssertEqual(AgentQuota(maxRequestsPerSession: 0).issues, [.invalidQuota])
        XCTAssertEqual(AgentQuota(maxOutputTokensPerRequest: -5).issues, [.invalidQuota])
        XCTAssertEqual(AgentQuota(maxTotalTokens: 0).issues, [.invalidQuota])
        XCTAssertTrue(AgentQuota(maxRequestsPerSession: 10).issues.isEmpty)
    }

    func testQuotaAllowsWhenUnlimited() {
        let quota = AgentQuota()

        XCTAssertEqual(quota.decision(ledger: AgentQuotaLedger(requestCount: 999, totalTokens: 10_000_000)), .allowed)
    }

    func testRequestCountLimit() {
        let quota = AgentQuota(maxRequestsPerSession: 3)

        XCTAssertEqual(quota.decision(ledger: AgentQuotaLedger(requestCount: 2)), .allowed)
        XCTAssertEqual(
            quota.decision(ledger: AgentQuotaLedger(requestCount: 3)),
            .requestLimitReached(limit: 3)
        )
    }

    func testTotalTokenLimit() {
        let quota = AgentQuota(maxTotalTokens: 1_000)

        XCTAssertEqual(quota.decision(ledger: AgentQuotaLedger(totalTokens: 999)), .allowed)
        XCTAssertEqual(
            quota.decision(ledger: AgentQuotaLedger(totalTokens: 1_200)),
            .tokenLimitReached(limit: 1_000, used: 1_200)
        )
    }

    func testPerRequestOutputTokenLimit() {
        let quota = AgentQuota(maxOutputTokensPerRequest: 256)

        XCTAssertEqual(quota.decision(ledger: .empty, requestedOutputTokens: 256), .allowed)
        XCTAssertEqual(
            quota.decision(ledger: .empty, requestedOutputTokens: 257),
            .outputTokenLimitExceeded(requested: 257, limit: 256)
        )
    }

    func testQuotaRecordAccumulates() {
        let quota = AgentQuota(maxRequestsPerSession: 5, maxTotalTokens: 10_000)

        let afterFirst = quota.record(ledger: .empty, usedTokens: 120)
        let afterSecond = quota.record(ledger: afterFirst, usedTokens: 80)

        XCTAssertEqual(afterSecond.requestCount, 2)
        XCTAssertEqual(afterSecond.totalTokens, 200)
        // 负数 token（服务端异常）不应把累计值冲掉。
        XCTAssertEqual(quota.record(ledger: afterSecond, usedTokens: -50).totalTokens, 200)
    }

    func testQuotaDecisionMessagesAreReadable() {
        XCTAssertTrue(AgentQuotaDecision.requestLimitReached(limit: 3).message.contains("3"))
        XCTAssertTrue(AgentQuotaDecision.tokenLimitReached(limit: 100, used: 120).message.contains("100"))
        XCTAssertTrue(
            AgentQuotaDecision.outputTokenLimitExceeded(requested: 900, limit: 256).message.contains("900")
        )
        XCTAssertTrue(AgentQuotaDecision.allowed.message.isEmpty)
    }

    // MARK: - 持久化（密钥不落配置文件）

    func testConfigurationRoundTrip() async throws {
        let directory = try makeDirectory()
        let store = AgentConfigurationStore(directoryURL: directory)

        let configuration = AgentConfiguration(
            isEnabled: true,
            endpoint: "http://127.0.0.1:11434/v1",
            model: "qwen2.5:7b",
            timeoutSeconds: 45,
            quota: AgentQuota(maxRequestsPerSession: 20, maxTotalTokens: 50_000)
        )

        try await store.save(configuration)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, configuration)
    }

    /// 配置文件不存在时返回「关闭状态的默认配置」，而不是报错或默认开启。
    func testMissingFileReturnsDisabledDefault() async throws {
        let directory = try makeDirectory()
        let store = AgentConfigurationStore(directoryURL: directory)

        let loaded = try await store.load()

        XCTAssertEqual(loaded, .default)
        XCTAssertFalse(loaded.isEnabled)
    }

    /// AC-AI-01 的配套性质：密钥只进钥匙串，配置文件里绝不能出现。
    func testConfigurationFileNeverContainsAPIKey() async throws {
        let directory = try makeDirectory()
        let store = AgentConfigurationStore(directoryURL: directory)
        let keyStore = InMemoryAgentKeyStore()
        let secret = "sk-super-secret-value-12345"
        try keyStore.setAPIKey(secret)

        try await store.save(remoteConfiguration())
        let fileURL = await store.fileLocation()
        let text = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.lowercased().contains("apikey"))
        XCTAssertFalse(text.lowercased().contains("api_key"))
        // 非敏感项照常落盘。
        XCTAssertTrue(text.contains("api.example.com"))
        XCTAssertTrue(text.contains("gpt-4o-mini"))
    }

    // MARK: - 只读模式与白名单的持久化（FR-AI-09）

    /// 默认即只读，且「写操作逐次批准」默认开启（FR-AI-09）。
    func testDefaultGuardPolicyIsReadOnly() {
        let policy = AgentConfiguration.default.guardPolicy

        XCTAssertTrue(policy.readOnly)
        XCTAssertTrue(policy.requireApprovalForHighRisk)
        XCTAssertTrue(policy.requireApprovalForWrites)
        XCTAssertTrue(policy.allowedKinds.isEmpty)
        XCTAssertFalse(policy.allowedKinds.contains(.unknown))
        XCTAssertEqual(AgentConfiguration.default.effectiveGuardPolicy, policy)
    }

    /// 只读模式与白名单随 `agent.json` 一起落盘、一起读回（配置持久化复用同一处）。
    func testGuardPolicyRoundTrip() async throws {
        let directory = try makeDirectory()
        let store = AgentConfigurationStore(directoryURL: directory)

        var configuration = localConfiguration()
        configuration.guardPolicy = AgentGuardPolicy(
            readOnly: false,
            requireApprovalForHighRisk: true,
            requireApprovalForWrites: true,
            allowedKinds: [.dataChange, .sessionControl]
        )

        try await store.save(configuration)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, configuration)
        XCTAssertFalse(loaded.guardPolicy.readOnly)
        XCTAssertEqual(loaded.guardPolicy.effectiveAllowedKinds, [.dataChange, .sessionControl])
    }

    /// 老版本的 `agent.json` 里没有 `guardPolicy`：缺字段退回只读默认，
    /// 而不是让整份配置读不出来（用户配好的端点 / 模型不能被静默丢掉）。
    func testOlderConfigurationWithoutGuardPolicyStillLoads() async throws {
        let directory = try makeDirectory()
        let store = AgentConfigurationStore(directoryURL: directory)
        let legacy = """
        {
          "endpoint" : "http://127.0.0.1:11434/v1",
          "isEnabled" : true,
          "model" : "qwen2.5:7b",
          "timeoutSeconds" : 30
        }
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("agent.json"))

        let loaded = try await store.load()

        XCTAssertTrue(loaded.isEnabled)
        XCTAssertEqual(loaded.model, "qwen2.5:7b")
        XCTAssertEqual(loaded.timeoutSeconds, 30)
        XCTAssertTrue(loaded.quota.isUnlimited, "缺 quota 字段退回不限")
        XCTAssertEqual(loaded.guardPolicy, .readOnlyDefault, "缺 guardPolicy 字段退回只读默认")
    }

    /// 手改配置文件把 `unknown` 塞进白名单：读回时被剔除（`unknown` 永远要审批）。
    func testUnknownAllowlistIsStrippedWhenLoading() async throws {
        let directory = try makeDirectory()
        let store = AgentConfigurationStore(directoryURL: directory)
        let tampered = """
        {
          "endpoint" : "http://127.0.0.1:11434/v1",
          "isEnabled" : true,
          "model" : "qwen2.5:7b",
          "timeoutSeconds" : 60,
          "guardPolicy" : {
            "readOnly" : false,
            "requireApprovalForHighRisk" : true,
            "requireApprovalForWrites" : true,
            "allowedKinds" : ["unknown", "dataChange"]
          }
        }
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(tampered.utf8).write(to: directory.appendingPathComponent("agent.json"))

        let loaded = try await store.load()

        XCTAssertEqual(loaded.guardPolicy.effectiveAllowedKinds, [.dataChange])
        XCTAssertFalse(loaded.guardPolicy.allowedKinds.contains(.unknown))
    }

    /// 策略落盘，但配置文件里依然**没有密钥字段**（NFR-AI-03 的配套性质）。
    func testGuardPolicyIsPersistedWithoutSecrets() async throws {
        let directory = try makeDirectory()
        let store = AgentConfigurationStore(directoryURL: directory)
        let secret = "sk-super-secret-value-12345"
        let keyStore = InMemoryAgentKeyStore()
        try keyStore.setAPIKey(secret)

        var configuration = remoteConfiguration()
        configuration.guardPolicy = AgentGuardPolicy(readOnly: false, allowedKinds: [.dataChange])
        try await store.save(configuration)

        let text = try String(contentsOf: await store.fileLocation(), encoding: .utf8)

        XCTAssertTrue(text.contains("guardPolicy"))
        XCTAssertTrue(text.contains("dataChange"))
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.lowercased().contains("apikey"))
    }

    /// 只读模式关掉时给一条警告（界面要能说出来「写操作已放开」）。
    func testWritesAllowedWarningSurfacesOnlyWhenReadOnlyIsOff() {
        let readOnly = localConfiguration()
        XCTAssertFalse(readOnly.warnings.contains(.agentWritesAllowed))

        var writable = readOnly
        writable.guardPolicy = AgentGuardPolicy(readOnly: false)
        XCTAssertTrue(writable.warnings.contains(.agentWritesAllowed))
        XCTAssertTrue(writable.warnings.contains(where: { $0.message.contains("只读模式") }))
        XCTAssertTrue(writable.isComplete, "关掉只读模式是合法配置，只是要提示")
    }

    func testKeyStoreRoundTrip() throws {
        let keyStore = InMemoryAgentKeyStore()

        XCTAssertNil(try keyStore.apiKey())
        try keyStore.setAPIKey("sk-1")
        XCTAssertEqual(try keyStore.apiKey(), "sk-1")
        try keyStore.setAPIKey("sk-2")
        XCTAssertEqual(try keyStore.apiKey(), "sk-2")
        XCTAssertEqual(keyStore.writeCount, 2)
        try keyStore.deleteAPIKey()
        XCTAssertNil(try keyStore.apiKey())
    }

    /// 闸门用的密钥来自密钥库：库里没有就拒绝外发。
    func testGateConsumesKeyFromStore() throws {
        let keyStore = InMemoryAgentKeyStore()
        let configuration = remoteConfiguration()

        XCTAssertEqual(AgentGate.decide(configuration: configuration, apiKey: try keyStore.apiKey()),
                       .missingAPIKey)

        try keyStore.setAPIKey("sk-1")
        XCTAssertTrue(AgentGate.decide(configuration: configuration, apiKey: try keyStore.apiKey()).isAllowed)
    }
}
