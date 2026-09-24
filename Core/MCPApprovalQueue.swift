import Foundation

/// 外部智能体调用的**待审批队列**（FR-AI-10 的界面那一半）。
///
/// 解决的问题：MCP server 跑在 CLI 的 stdin/stdout 上（那是协议通道，不能借来弹窗），
/// 而"批准这一次外部调用"必须由**界面**上的人来点。于是两边共用一个**文件队列**：
///   · server 侧遇到"需要审批"的调用 → **入队并等**（等多久由调用方定）；
///   · 界面侧展示待审批项 → 用户点允许 / 拒绝 → 写**决定**；
///   · server 侧读决定 → 放行或拒绝。
///
/// 为什么用文件而不是 socket：两侧是**两个进程**（CLI 可能没有界面在跑），文件让"没有界面时"
/// 也有明确行为（等超时 → 如实拒绝），而且能被人直接看一眼、也能被脚本断言。
/// 队列是**追加式**的：`pending` 里没有的决定就是"还没决定"，不需要锁，也不会读到半截记录
/// （一行一条 JSON，坏行跳过并报出来）。
public struct MCPApprovalRequest: Codable, Equatable, Sendable {
    public var id: String
    public var at: Date
    /// 外部对端的自称。
    public var client: String
    public var tool: String
    /// 参数摘要（给人看的；**不含口令**）。
    public var argumentsSummary: String
    /// 调用指纹（与 `MCPToolCatalog.callFingerprint` 一致，用于把决定对回具体这一次调用）。
    public var fingerprint: String
    /// 如果是执行语句的工具，把语句原样带上 —— 人要看的就是它。
    public var sql: String?
    /// 需要审批的原因。
    public var reason: String

    public init(
        id: String,
        at: Date = Date(),
        client: String,
        tool: String,
        argumentsSummary: String,
        fingerprint: String,
        sql: String? = nil,
        reason: String
    ) {
        self.id = id
        self.at = at
        self.client = client
        self.tool = tool
        self.argumentsSummary = argumentsSummary
        self.fingerprint = fingerprint
        self.sql = sql
        self.reason = reason
    }
}

/// 决定（追加式：同一个 id 每次决定都追加一条，**最后一条为准**，于是"批准后又反悔"也留痕）。
public struct MCPApprovalDecision: Codable, Equatable, Sendable {
    public var requestID: String
    public var approved: Bool
    public var at: Date

    public init(requestID: String, approved: Bool, at: Date = Date()) {
        self.requestID = requestID
        self.approved = approved
        self.at = at
    }
}

/// 文件队列。两侧（server 与界面）都用它，所以"谁写的决定"只有一个格式。
public struct MCPApprovalStore: Sendable {

    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// 默认目录：与其余本机数据同一处（`~/Library/Application Support/DoyahStudio`）。
    ///
    /// **两侧必须算出同一个路径** —— 所以它不是"各自拼一遍"，而是 Core 给一份。
    /// 环境变量 `DOYAH_MCP_APPROVAL_DIR` 可以整体改掉它（与 `DOYAH_SSH_BINARY` 同一路数）：
    /// 探针与脚本用它把队列挪到临时目录，免得在真实数据目录里留下测试痕迹。
    public static func defaultStore(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPApprovalStore {
        if let override = environment["DOYAH_MCP_APPROVAL_DIR"], !override.isEmpty {
            return MCPApprovalStore(directory: URL(fileURLWithPath: override))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return MCPApprovalStore(
            directory: base
                .appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
                .appendingPathComponent("mcp-approvals", isDirectory: true)
        )
    }

    public var pendingURL: URL { directory.appendingPathComponent("pending.jsonl") }
    public var decisionsURL: URL { directory.appendingPathComponent("decisions.jsonl") }

    // MARK: - 写

    /// 入队（返回带 id 的请求）。
    @discardableResult
    public func enqueue(
        client: String,
        tool: String,
        argumentsSummary: String,
        fingerprint: String,
        sql: String?,
        reason: String,
        now: Date = Date()
    ) throws -> MCPApprovalRequest {
        try ensureDirectory()
        let request = MCPApprovalRequest(
            id: UUID().uuidString,
            at: now,
            client: client,
            tool: tool,
            argumentsSummary: argumentsSummary,
            fingerprint: fingerprint,
            sql: sql,
            reason: reason
        )
        try append(try Self.encoder.encode(request), to: pendingURL)
        return request
    }

    /// 写一条决定。
    public func decide(requestID: String, approved: Bool, now: Date = Date()) throws {
        try ensureDirectory()
        let decision = MCPApprovalDecision(requestID: requestID, approved: approved, at: now)
        try append(try Self.encoder.encode(decision), to: decisionsURL)
    }

    // MARK: - 读

    /// 待审批（**还没有决定**的请求；已决定的自动从"待办"里消失，但记录都还在）。
    public func pending() throws -> [MCPApprovalRequest] {
        let requests = try requests()
        let decided = Set(try decisions().map(\.requestID))
        return requests.filter { !decided.contains($0.id) }
    }

    public func requests() throws -> [MCPApprovalRequest] {
        try read(MCPApprovalRequest.self, from: pendingURL)
    }

    public func decisions() throws -> [MCPApprovalDecision] {
        try read(MCPApprovalDecision.self, from: decisionsURL)
    }

    /// 某一次请求的决定（**最后一条为准**）。
    public func decision(for requestID: String) throws -> Bool? {
        try decisions().last { $0.requestID == requestID }?.approved
    }

    /// 按指纹找最近一次决定 —— server 侧就是这么把"用户刚才批准的那一次"对回来的。
    public func latestDecision(forFingerprint fingerprint: String) throws -> (request: MCPApprovalRequest, approved: Bool)? {
        let requests = try requests().filter { $0.fingerprint == fingerprint }
        let decisions = try decisions()
        // 从最近的请求往回找：第一个有决定的就是答案。
        for request in requests.reversed() {
            if let decision = decisions.last(where: { $0.requestID == request.id }) {
                return (request, decision.approved)
            }
        }
        return nil
    }

    // MARK: - 清理

    /// 清掉已决定的请求与它们的决定（保留"没决定的"）。
    ///
    /// 为什么可以清：队列是**给人看的待办**，不是审计来源 —— 审计在 `MCPAuditEntry` 那条线上。
    public func pruneDecided(now: Date = Date()) throws {
        let requests = try requests()
        let decisions = try decisions()
        let decidedIDs = Set(decisions.map(\.requestID))
        let remaining = requests.filter { !decidedIDs.contains($0.id) }
        try ensureDirectory()
        try write(remaining.map { try Self.encoder.encode($0) }, to: pendingURL)
    }

    // MARK: - 文件工具

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func append(_ data: Data, to url: URL) throws {
        var payload = data
        payload.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(to: url, options: .atomic)
        }
    }

    private func write(_ lines: [Data], to url: URL) throws {
        let joined = lines.map { $0 + Data([0x0A]) }.reduce(Data(), +)
        try joined.write(to: url, options: .atomic)
    }

    /// 逐行读 JSONL：**坏行跳过并报出来**（一个坏行不该让整条审批链不可用）。
    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [T] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8), let value = try? Self.decoder.decode(T.self, from: data) else {
                continue
            }
            result.append(value)
        }
        return result
    }

    /// 坏行数量（面板可以据此提示"有文件被手改坏了"，而不是静默少几条）。
    public func malformedLineCount() -> Int {
        func count(_ url: URL) -> Int {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
            return text.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
                guard let data = line.data(using: .utf8) else { return true }
                return (try? Self.decoder.decode(MCPApprovalRequest.self, from: data)) == nil
                    && (try? Self.decoder.decode(MCPApprovalDecision.self, from: data)) == nil
            }.count
        }
        return count(pendingURL) + count(decisionsURL)
    }
}
