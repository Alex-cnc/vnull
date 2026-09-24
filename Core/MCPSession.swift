import Foundation

/// 我们**作为 MCP server** 的会话状态机（FR-AI-10 的 server 方向）。
///
/// 纯逻辑：给一行报文，回一行（或零行）报文 + 一条审计。**不读 stdin、不连数据库** ——
/// 真正的 I/O 与执行由调用方（CLI / 界面）注入，于是这一层可以离线测到每一条分支。
public struct MCPServerSession: Sendable {

    /// 当前会话能提供什么（由调用方从**当前连接**推导，不从外部请求里来 —— 这就是"继承当前会话"）。
    public struct Capabilities: Sendable {
        /// 当前是否有一个已连接的会话。
        public var hasConnection: Bool
        /// 当前连接是否只读。
        public var isReadOnly: Bool
        public var databaseType: DatabaseType
        /// 连接的自述（例如 `postgres@127.0.0.1:5432/analytics`）—— 只给"到哪儿去了"，不含口令。
        public var target: String
        /// **已获批的"具体调用"**（`MCPToolCatalog.callFingerprint`）——按次批准，不按工具名。
        /// 界面点过"这一次允许"就把这次调用的指纹放进来。
        public var approvedCalls: Set<String>

        public init(
            hasConnection: Bool,
            isReadOnly: Bool,
            databaseType: DatabaseType = .postgresql,
            target: String,
            approvedCalls: Set<String> = []
        ) {
            self.hasConnection = hasConnection
            self.isReadOnly = isReadOnly
            self.databaseType = databaseType
            self.target = target
            self.approvedCalls = approvedCalls
        }
    }

    /// 调用方要执行的一次工具调用（会话只**决定**，不执行）。
    public struct Invocation: Equatable, Sendable {
        public var tool: String
        public var arguments: MCPValue
        public var requestID: MCPMessage.MCPID?

        public init(tool: String, arguments: MCPValue, requestID: MCPMessage.MCPID?) {
            self.tool = tool
            self.arguments = arguments
            self.requestID = requestID
        }
    }

    public private(set) var isInitialized = false
    public private(set) var clientName = "unknown"
    public private(set) var audit: [MCPAuditEntry] = []
    public var capabilities: Capabilities

    public init(capabilities: Capabilities) {
        self.capabilities = capabilities
    }

    /// 处理一行报文。返回：要写回去的报文（通知不必回）+ 需要调用方执行的调用（可能没有）。
    public struct Outcome: Sendable {
        public var replies: [MCPMessage]
        public var invocation: Invocation?
        public var error: String?
    }

    public mutating func handle(line: String) -> Outcome {
        switch MCPMessage.decode(line) {
        case .failure(let error):
            return Outcome(replies: [.error(id: nil, error: error)], invocation: nil, error: error.message)
        case .success(let message):
            return handle(message: message)
        }
    }

    public mutating func handle(message: MCPMessage) -> Outcome {
        switch message {
        case .request(let id, let method, let params):
            return handleRequest(id: id, method: method, params: params)
        case .notification(let method, let params):
            // `initialized`：对方确认握手完成。**不回包**（JSON-RPC 的通知不带 id）。
            if method == "notifications/initialized" || method == "initialized" {
                if let name = params["clientInfo"]?["name"]?.stringValue {
                    clientName = name
                }
            }
            return Outcome(replies: [], invocation: nil, error: nil)
        case .response, .error:
            // 我们是 server：收到响应型报文说明对端搞错了方向 —— 如实说，不要假装没收到。
            return Outcome(
                replies: [.error(id: nil, error: .invalidRequest)],
                invocation: nil,
                error: "unexpected response message"
            )
        }
    }

    private mutating func handleRequest(
        id: MCPMessage.MCPID,
        method: String,
        params: MCPValue
    ) -> Outcome {
        switch method {
        case "initialize":
            isInitialized = true
            if let name = params["clientInfo"]?["name"]?.stringValue {
                clientName = name
            }
            let requested = params["protocolVersion"]?.stringValue ?? "(none)"
            let result = MCPValue.object([
                "protocolVersion": .string(MCPProtocol.version),
                // 对方要的版本与我们不一致时**如实回报我们支持的版本**（协议要求由客户端决定是否继续）。
                "serverInfo": .object([
                    "name": .string("DoyahStudio"),
                    "version": .string("1.0"),
                ]),
                "capabilities": .object([
                    "tools": .object([:]),
                    "resources": .object([:]),
                    "experimental": .object([
                        "requestedProtocolVersion": .string(requested),
                    ]),
                ]),
                "instructions": .string(text(.mcpInitialized)),
            ])
            audit.append(
                MCPAuditEntry(
                    client: clientName,
                    tool: "initialize",
                    argumentsSummary: "protocol=\(requested)",
                    outcome: "ok"
                )
            )
            return Outcome(replies: [.response(id: id, result: result)], invocation: nil, error: nil)

        case "tools/list":
            let tools = MCPToolCatalog.all.map { $0.schemaJSON() }
            return Outcome(
                replies: [.response(id: id, result: .object(["tools": .array(tools)]))],
                invocation: nil,
                error: nil
            )

        case "resources/list":
            // 资源 = 当前会话的"目录"（连接自述 + 工具说明）。**不含口令**。
            let resources = MCPValue.array([
                .object([
                    "uri": .string("doyah://session"),
                    "name": .string("current-session"),
                    "description": .string(capabilities.target),
                    "mimeType": .string("application/json"),
                ])
            ])
            return Outcome(
                replies: [.response(id: id, result: .object(["resources": resources]))],
                invocation: nil,
                error: nil
            )

        case "ping":
            return Outcome(replies: [.response(id: id, result: .object([:]))], invocation: nil, error: nil)

        case "tools/call":
            return handleToolCall(id: id, params: params)

        default:
            return Outcome(
                replies: [.error(id: id, error: .methodNotFound)],
                invocation: nil,
                error: "method not found: \(method)"
            )
        }
    }

    private mutating func handleToolCall(id: MCPMessage.MCPID, params: MCPValue) -> Outcome {
        guard isInitialized else {
            // 没握手就调工具：协议上说不过去，如实拒（不假装成功）。
            return Outcome(
                replies: [.error(id: id, error: .invalidRequest)],
                invocation: nil,
                error: "tools/call before initialize"
            )
        }
        guard let name = params["name"]?.stringValue else {
            return Outcome(
                replies: [.error(id: id, error: .invalidParams("missing tool name"))],
                invocation: nil,
                error: "missing tool name"
            )
        }
        guard let tool = MCPToolCatalog.tool(named: name) else {
            let reason = text(.mcpToolNotExposed, name)
            audit.append(MCPAuditEntry(client: clientName, tool: name, argumentsSummary: "—", outcome: "not-exposed"))
            return Outcome(
                replies: [.response(id: id, result: errorContent(reason))],
                invocation: nil,
                error: reason
            )
        }

        let arguments = params["arguments"] ?? .object([:])
        let sql = arguments["sql"]?.stringValue

        // **没有会话就不要动**：外部调用一律不另开连接（"不另开特权"的第一层含义）。
        if !capabilities.hasConnection, tool.access != .metadata {
            let reason = text(.mcpNoConnection)
            audit.append(MCPAuditEntry(client: clientName, tool: name, argumentsSummary: "—", outcome: "no-session"))
            return Outcome(replies: [.response(id: id, result: errorContent(reason))], invocation: nil, error: reason)
        }

        let decision = MCPToolCatalog.decision(
            for: tool,
            sql: sql,
            databaseType: capabilities.databaseType,
            isReadOnlyConnection: capabilities.isReadOnly,
            isApproved: capabilities.approvedCalls.contains(
                MCPToolCatalog.callFingerprint(tool: name, arguments: arguments)
            )
        )
        switch decision {
        case .refused(let reason):
            audit.append(
                MCPAuditEntry(client: clientName, tool: name, argumentsSummary: summarize(arguments), outcome: "refused")
            )
            return Outcome(replies: [.response(id: id, result: errorContent(reason))], invocation: nil, error: reason)
        case .needsApproval(let reason):
            audit.append(
                MCPAuditEntry(client: clientName, tool: name, argumentsSummary: summarize(arguments), outcome: "needs-approval")
            )
            return Outcome(replies: [.response(id: id, result: errorContent(reason))], invocation: nil, error: reason)
        case .allowed(let access, _):
            audit.append(
                MCPAuditEntry(
                    client: clientName,
                    tool: name,
                    argumentsSummary: summarize(arguments),
                    outcome: "allowed(\(access.rawValue))"
                )
            )
            return Outcome(
                replies: [],
                invocation: Invocation(tool: name, arguments: arguments, requestID: id),
                error: nil
            )
        }
    }

    /// 调用方执行完（或失败）之后，把结果包成 MCP 的 `tools/call` 结果。
    public mutating func finish(
        _ invocation: Invocation,
        text result: String,
        isError: Bool = false
    ) -> MCPMessage? {
        guard let id = invocation.requestID else { return nil }
        if isError {
            audit.append(
                MCPAuditEntry(client: clientName, tool: invocation.tool, argumentsSummary: "—", outcome: "failed")
            )
        }
        let content: MCPValue = .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(result)])
            ]),
            "isError": .bool(isError),
        ])
        return .response(id: id, result: content)
    }

    private func errorContent(_ message: String) -> MCPValue {
        .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(message)])
            ]),
            "isError": .bool(true),
        ])
    }

    private func summarize(_ arguments: MCPValue) -> String {
        // 审计里只留**参数摘要**：太长就截断（审计是给人看的，不是数据仓库）。
        let text = arguments.jsonText
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}

/// 我们**作为 MCP host** 的会话状态机（FR-AI-10 的 host 方向）。
///
/// 只做到"握手 → 列工具 → 调工具 → 解析结果"这条最小闭环：多了会在没有真实 MCP 服务器的情况下
/// 变成一堆没验过的代码。外部服务器的**工具名与参数**原样透传（我们不做改名、不做参数补全），
/// 因为改名会让"同一个工具在两个客户端里名字不同"，那对互操作是负价值。
public struct MCPClientSession: Sendable {

    public struct RemoteTool: Equatable, Sendable {
        public var name: String
        public var description: String
    }

    public private(set) var isInitialized = false
    public private(set) var serverName = "unknown"
    public private(set) var protocolVersion = ""
    public private(set) var tools: [RemoteTool] = []
    public private(set) var lastResult: String?
    public private(set) var lastError: String?

    private var nextID = 1

    public init() {}

    /// 下一步该发什么（调用方写出去）。
    public mutating func initializeRequest() -> MCPMessage {
        let id = MCPMessage.MCPID.number(nextID)
        nextID += 1
        return .request(
            id: id,
            method: "initialize",
            params: .object([
                "protocolVersion": .string(MCPProtocol.version),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("DoyahStudio"),
                    "version": .string("1.0"),
                ]),
            ])
        )
    }

    public mutating func toolsListRequest() -> MCPMessage {
        let id = MCPMessage.MCPID.number(nextID)
        nextID += 1
        return .request(id: id, method: "tools/list", params: .object([:]))
    }

    public mutating func toolsCallRequest(tool: String, arguments: MCPValue) -> MCPMessage {
        let id = MCPMessage.MCPID.number(nextID)
        nextID += 1
        return .request(
            id: id,
            method: "tools/call",
            params: .object(["name": .string(tool), "arguments": arguments])
        )
    }

    /// 收到一行（外部服务器的回复）后更新状态。
    @discardableResult
    public mutating func receive(line: String) -> Bool {
        switch MCPMessage.decode(line) {
        case .failure(let error):
            lastError = error.message
            return false
        case .success(let message):
            return receive(message: message)
        }
    }

    @discardableResult
    public mutating func receive(message: MCPMessage) -> Bool {
        switch message {
        case .error(_, let error):
            lastError = error.message
            return false
        case .response(_, let result):
            if let serverInfo = result["serverInfo"] {
                serverName = serverInfo["name"]?.stringValue ?? serverName
            }
            if let version = result["protocolVersion"]?.stringValue {
                protocolVersion = version
                isInitialized = true
            }
            if let list = result["tools"]?.arrayValue {
                tools = list.compactMap { item in
                    guard let name = item["name"]?.stringValue else { return nil }
                    return RemoteTool(name: name, description: item["description"]?.stringValue ?? "")
                }
            }
            // `tools/call` 的结果：把文本内容拼起来（图片等其它类型原样说明类型，不装作看不见）。
            if let content = result["content"]?.arrayValue {
                var parts: [String] = []
                for item in content {
                    if let textValue = item["text"]?.stringValue {
                        parts.append(textValue)
                    } else if let type = item["type"]?.stringValue {
                        parts.append("[\(type)]")
                    }
                }
                lastResult = parts.joined(separator: "\n")
            }
            if result["isError"]?.boolValue == true {
                lastError = lastResult
            }
            return true
        case .request, .notification:
            // 我们只是 host 的最小闭环：不处理服务器反向发起的请求。
            return false
        }
    }

    public func hasError() -> Bool { lastError != nil }
}

/// Core 侧文案（同文件内使用）。
private func text(_ key: LKey, _ arguments: CVarArg...) -> String {
    if arguments.isEmpty {
        return LocalizedStrings.text(key, language: .simplifiedChinese)
    }
    return LocalizedStrings.format(key, language: .simplifiedChinese, arguments)
}
