import Foundation

/// 智能体接入配置（FR-AI-01）。
///
/// 设计要点：
/// - **安全默认**：`default` 是「总开关关闭 + 端点与模型为空」——装好软件不会自己往外发东西
///   （NFR-SEC-05 默认零外发、AC-AI-01）；
/// - **配置里没有 API Key 字段**：密钥只进系统钥匙串（`AgentKeyStore`），
///   从类型上就杜绝「密钥被写进配置文件 / 日志 / 审计」这一类事故；
/// - 本类型只描述「配了什么」，「能不能发」由 `AgentGate.decide` 判定。
public struct AgentConfiguration: Codable, Equatable, Sendable {

    /// 总开关（FR-AI-01）。关闭时**零外发**，与端点 / 模型 / 密钥是否配好无关。
    public var isEnabled: Bool
    /// OpenAI 兼容端点，例如 `http://127.0.0.1:11434/v1`（Ollama）、`https://api.example.com/v1`。
    public var endpoint: String
    /// 模型名，例如 `qwen2.5:7b`、`gpt-4o-mini`。
    public var model: String
    /// 单次请求超时（秒）。
    public var timeoutSeconds: TimeInterval
    /// 成本与配额（NFR-AI-04）。
    public var quota: AgentQuota
    /// 审批 / 护栏策略（FR-AI-09、FR-AI-12）：只读模式与白名单。
    ///
    /// v1.0 默认**只读**（`AgentGuardPolicy.readOnlyDefault`）：智能体发起的写操作 /
    /// DDL 一律被拒（AC-AI-02）。要放开必须显式关闭只读模式，且放开后写操作仍需逐次审批。
    public var guardPolicy: AgentGuardPolicy

    public init(
        isEnabled: Bool = false,
        endpoint: String = "",
        model: String = "",
        timeoutSeconds: TimeInterval = AgentConfiguration.defaultTimeoutSeconds,
        quota: AgentQuota = AgentQuota(),
        guardPolicy: AgentGuardPolicy = .readOnlyDefault
    ) {
        self.isEnabled = isEnabled
        self.endpoint = endpoint
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.quota = quota
        self.guardPolicy = guardPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case endpoint
        case model
        case timeoutSeconds
        case quota
        case guardPolicy
    }

    /// 手写解码只为一件小事：**向后兼容**。
    ///
    /// 老版本的 `agent.json` 里没有 `guardPolicy` 字段，用合成解码会整份配置读不出来，
    /// 用户明明配好的端点 / 模型会被静默丢掉。缺字段时退回只读默认（也就是安全默认）。
    /// 顺带把白名单归一化（剔除 `unknown`，见 `AgentGuardPolicy.sanitized`）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        self.timeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds)
            ?? AgentConfiguration.defaultTimeoutSeconds
        self.quota = try container.decodeIfPresent(AgentQuota.self, forKey: .quota) ?? AgentQuota()
        self.guardPolicy = (try container.decodeIfPresent(AgentGuardPolicy.self, forKey: .guardPolicy)
            ?? .readOnlyDefault).sanitized
    }

    /// 默认超时（秒）。
    public static let defaultTimeoutSeconds: TimeInterval = 60
    /// 允许的最大超时（秒）：超过这个值多半是误填，不如直接拒绝。
    public static let maximumTimeoutSeconds: TimeInterval = 600

    /// 安全默认：总开关关闭、端点与模型为空。
    public static let `default` = AgentConfiguration()
}

// MARK: - 校验

/// 配置问题（阻断外发）。
public enum AgentConfigurationIssue: String, Equatable, Sendable, CaseIterable {
    case emptyEndpoint
    case invalidEndpoint
    case emptyModel
    case invalidTimeout
    case invalidQuota

    /// 可读说明，直接给界面用。
    public var message: String {
        switch self {
        case .emptyEndpoint: return "尚未填写模型服务端点。"
        case .invalidEndpoint: return "模型服务端点必须是 http(s) 地址，且包含主机名。"
        case .emptyModel: return "尚未填写模型名。"
        case .invalidTimeout: return "超时必须在 0 秒到 600 秒之间。"
        case .invalidQuota: return "配额上限必须是正整数（留空表示不限）。"
        }
    }
}

/// 配置警告（不阻断外发，但要在界面上提示）。
public enum AgentConfigurationWarning: String, Equatable, Sendable, CaseIterable {
    /// 远端明文 http 端点：密钥会以明文上网。
    case insecureRemoteEndpoint
    /// 只读模式已关闭：智能体可以发起写操作 / DDL（仍须逐次审批）。
    case agentWritesAllowed

    public var message: String {
        switch self {
        case .insecureRemoteEndpoint:
            return "该端点是远端 http 地址，API Key 会以明文传输；建议改用 https。"
        case .agentWritesAllowed:
            return "只读模式已关闭：智能体可以发起写操作 / DDL（每次仍需逐次批准）。"
        }
    }
}

public extension AgentConfiguration {

    /// 端点解析结果；不是合法的 http(s) URL 时为 `nil`。
    var endpointURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }

    /// 去掉首尾空白的模型名；为空时 `nil`。
    var normalizedModel: String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 阻断性问题清单；为空即配置完整。
    var issues: [AgentConfigurationIssue] {
        var issues: [AgentConfigurationIssue] = []

        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEndpoint.isEmpty {
            issues.append(.emptyEndpoint)
        } else if endpointURL == nil {
            issues.append(.invalidEndpoint)
        }

        if normalizedModel == nil {
            issues.append(.emptyModel)
        }

        if !(timeoutSeconds > 0) || timeoutSeconds > Self.maximumTimeoutSeconds {
            issues.append(.invalidTimeout)
        }

        issues.append(contentsOf: quota.issues)
        return issues
    }

    /// 配置是否完整（不含总开关状态）。
    var isComplete: Bool { issues.isEmpty }

    /// 警告清单。
    var warnings: [AgentConfigurationWarning] {
        var warnings: [AgentConfigurationWarning] = []
        if let url = endpointURL,
           url.scheme?.lowercased() == "http",
           !isLocalEndpoint {
            warnings.append(.insecureRemoteEndpoint)
        }
        // 只读模式是 v1.0 的安全默认；关掉它值得在界面上说出来（FR-AI-09）。
        if !guardPolicy.readOnly {
            warnings.append(.agentWritesAllowed)
        }
        return warnings
    }

    /// 实际生效的护栏 / 审批策略（白名单已归一化，`unknown` 不在其中）。
    var effectiveGuardPolicy: AgentGuardPolicy { guardPolicy.sanitized }

    /// 端点是否指向本机 / 局域网（NFR-AI-06 本地模型优先）。
    ///
    /// 覆盖：`localhost`、`*.local`、IPv4 环回 `127/8`、RFC1918 私有段
    /// （`10/8`、`192.168/16`、`172.16/12`）、链路本地 `169.254/16`、
    /// IPv6 环回 `::1` 与唯一本地地址 `fc00::/7` / 链路本地 `fe80::/10`。
    /// 这些地址不会把数据带到公网。
    var isLocalEndpoint: Bool {
        guard let rawHost = endpointURL?.host?.lowercased() else { return false }
        // IPv6 字面量在 URL 里带方括号（`[::1]`），先剥掉再判断。
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast())
            : rawHost

        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasSuffix(".local") { return true }
        if host == "0.0.0.0" { return true }

        // IPv6（含 `::1`、`fc00::/7`、`fe80::/10`）
        if host.contains(":") {
            if host == "::1" { return true }
            if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") { return true }
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _): return true                       // 环回
        case (10, _): return true                        // RFC1918
        case (192, 168): return true                     // RFC1918
        case (172, 16...31): return true                 // RFC1918
        case (169, 254): return true                     // 链路本地
        default: return false
        }
    }

    /// 是否需要 API Key：本地端点（Ollama / vLLM 等）不需要。
    var requiresAPIKey: Bool { !isLocalEndpoint }
}

// MARK: - 外发判定

/// 一次外发前的判定结果（FR-AI-01 / AC-AI-01）。
public enum AgentOutboundDecision: Equatable, Sendable {
    /// 允许外发。
    case allowed(endpoint: URL, model: String, warnings: [AgentConfigurationWarning])
    /// 总开关关闭：**一律不外发**。
    case disabled
    /// 配置不完整。
    case misconfigured([AgentConfigurationIssue])
    /// 缺少 API Key。
    case missingAPIKey

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    /// 可读说明（拒绝时给界面用）。
    public var message: String {
        switch self {
        case .allowed(_, let model, let warnings):
            if warnings.isEmpty { return "将使用模型 \(model)。" }
            return "将使用模型 \(model)。" + warnings.map(\.message).joined(separator: " ")
        case .disabled:
            return "智能体总开关已关闭，不会向任何模型服务发送数据。"
        case .misconfigured(let issues):
            return issues.map(\.message).joined(separator: " ")
        case .missingAPIKey:
            return "尚未配置该端点的 API Key。"
        }
    }
}

/// 外发闸门（FR-AI-01、NFR-AI-02）。
///
/// **唯一入口**：所有要走模型网络请求的路径都应先问这里，不要在别处自己判断
/// 「开关是否打开」——把判定收在一处，AC-AI-01「关闭总开关后外发流量为 0」
/// 才是可核对的性质，而不是散落各处的 if。
public enum AgentGate {

    /// 判定本次是否可以外发。
    ///
    /// **顺序即语义**：总开关最先判断，关闭时立即返回 `.disabled`，
    /// 后面即使端点 / 模型 / 密钥都齐全也绝不外发。
    public static func decide(
        configuration: AgentConfiguration,
        apiKey: String?
    ) -> AgentOutboundDecision {
        guard configuration.isEnabled else { return .disabled }

        let issues = configuration.issues
        guard issues.isEmpty,
              let endpoint = configuration.endpointURL,
              let model = configuration.normalizedModel
        else {
            return .misconfigured(issues.isEmpty ? [.invalidEndpoint] : issues)
        }

        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.requiresAPIKey, key?.isEmpty ?? true {
            return .missingAPIKey
        }

        return .allowed(endpoint: endpoint, model: model, warnings: configuration.warnings)
    }
}

// MARK: - 配额（NFR-AI-04）

/// 配额配置；`nil` 表示该项不限。
public struct AgentQuota: Codable, Equatable, Sendable {
    /// 单次会话最多调用次数。
    public var maxRequestsPerSession: Int?
    /// 单次请求最多输出 token。
    public var maxOutputTokensPerRequest: Int?
    /// 累计 token 上限。
    public var maxTotalTokens: Int?

    public init(
        maxRequestsPerSession: Int? = nil,
        maxOutputTokensPerRequest: Int? = nil,
        maxTotalTokens: Int? = nil
    ) {
        self.maxRequestsPerSession = maxRequestsPerSession
        self.maxOutputTokensPerRequest = maxOutputTokensPerRequest
        self.maxTotalTokens = maxTotalTokens
    }

    /// 未配置任何上限。
    public var isUnlimited: Bool {
        maxRequestsPerSession == nil && maxOutputTokensPerRequest == nil && maxTotalTokens == nil
    }

    var issues: [AgentConfigurationIssue] {
        var issues: [AgentConfigurationIssue] = []
        for value in [maxRequestsPerSession, maxOutputTokensPerRequest, maxTotalTokens] {
            if let value, value <= 0 { issues.append(.invalidQuota) }
        }
        return issues
    }

    /// 调用前的判定：超限返回具体原因（不是静默失败）。
    public func decision(
        ledger: AgentQuotaLedger,
        requestedOutputTokens: Int? = nil
    ) -> AgentQuotaDecision {
        if let limit = maxRequestsPerSession, ledger.requestCount >= limit {
            return .requestLimitReached(limit: limit)
        }
        if let limit = maxTotalTokens, ledger.totalTokens >= limit {
            return .tokenLimitReached(limit: limit, used: ledger.totalTokens)
        }
        if let limit = maxOutputTokensPerRequest, let requested = requestedOutputTokens, requested > limit {
            return .outputTokenLimitExceeded(requested: requested, limit: limit)
        }
        return .allowed
    }

    /// 调用完成后记账。
    public func record(ledger: AgentQuotaLedger, usedTokens: Int) -> AgentQuotaLedger {
        AgentQuotaLedger(
            requestCount: ledger.requestCount + 1,
            totalTokens: ledger.totalTokens + max(0, usedTokens)
        )
    }
}

/// 已消耗的配额。
public struct AgentQuotaLedger: Codable, Equatable, Sendable {
    public var requestCount: Int
    public var totalTokens: Int

    public init(requestCount: Int = 0, totalTokens: Int = 0) {
        self.requestCount = requestCount
        self.totalTokens = totalTokens
    }

    public static let empty = AgentQuotaLedger()
}

/// 配额判定结果。
public enum AgentQuotaDecision: Equatable, Sendable {
    case allowed
    case requestLimitReached(limit: Int)
    case tokenLimitReached(limit: Int, used: Int)
    case outputTokenLimitExceeded(requested: Int, limit: Int)

    public var isAllowed: Bool { self == .allowed }

    /// 可读提示：超限即终止并说明原因（NFR-AI-04）。
    public var message: String {
        switch self {
        case .allowed:
            return ""
        case .requestLimitReached(let limit):
            return "已达到本会话的调用次数上限（\(limit) 次），本次请求已终止。"
        case .tokenLimitReached(let limit, let used):
            return "已达到累计 token 上限（\(limit)，已用 \(used)），本次请求已终止。"
        case .outputTokenLimitExceeded(let requested, let limit):
            return "本次请求要求输出 \(requested) token，超过单次上限 \(limit)，已终止。"
        }
    }
}
