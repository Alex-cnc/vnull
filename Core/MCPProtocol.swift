import Foundation

/// MCP（Model Context Protocol）互操作层（FR-AI-10）—— **消息与状态机**，不含任何 I/O。
///
/// **为什么先把这一层单独做出来**：MCP 是两个方向（我们当 host 接别人的服务器；我们当 server 把
/// 自己的能力暴露出去），但**两个方向用的是同一套 JSON-RPC 报文**。把它写成纯函数之后：
///   · 可以离线单测（不需要网络、不需要真实 MCP 服务器）；
///   · 两个方向的解析/生成**不可能不一致**（同一份实现）；
///   · 脚本可以用**假对端**（一个读 stdin 写 stdout 的小程序）把两个方向都跑一遍。
///
/// 需求原文的一条硬约束贯穿全层：「权限**继承当前会话**，不另开特权；外部调用同样进审批与审计」——
/// 落到代码里就是 `MCPToolCatalog` 的逐工具判定与 `MCPAuditEntry`。
public enum MCPProtocol {
    /// 我们声明的协议版本。对方给别的版本时**如实回报**我们支持的版本，而不是假装兼容。
    public static let version = "2024-11-05"
    public static let jsonrpc = "2.0"
}

/// JSON-RPC 2.0 报文（MCP 的传输格式）。
public enum MCPMessage: Equatable, Sendable {
    case request(id: MCPID, method: String, params: MCPValue)
    case notification(method: String, params: MCPValue)
    case response(id: MCPID, result: MCPValue)
    case error(id: MCPID?, error: MCPError)

    /// 请求 / 响应的 id：MCP 允许字符串与数字两种。
    public enum MCPID: Equatable, Hashable, Sendable {
        case number(Int)
        case text(String)

        public var jsonValue: MCPValue {
            switch self {
            case .number(let value): return .number(Double(value))
            case .text(let value): return .string(value)
            }
        }
    }

    public struct MCPError: Error, Equatable, Sendable {
        public var code: Int
        public var message: String
        /// 给调用方看的补充（我们用它放"该改哪儿"的说明）。
        public var data: MCPValue?

        public init(code: Int, message: String, data: MCPValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        /// 标准错误码（JSON-RPC 2.0）。
        public static let parseError = MCPError(code: -32700, message: "Parse error")
        public static let invalidRequest = MCPError(code: -32600, message: "Invalid Request")
        public static let methodNotFound = MCPError(code: -32601, message: "Method not found")
        public static func invalidParams(_ detail: String) -> MCPError {
            MCPError(code: -32602, message: "Invalid params", data: .string(detail))
        }
        public static func internalError(_ detail: String) -> MCPError {
            MCPError(code: -32603, message: "Internal error", data: .string(detail))
        }
    }
}

/// 一个够用的 JSON 值类型。
///
/// 为什么用自写的而不是 `Codable` 结构体：MCP 的 `params` / `result` 是**开放**的
/// （不同工具的参数形状不同、对方可能塞我们没实现的字段），用强类型结构会变成
/// "遇到没见过的字段就整条解析失败"——那正好是互操作里最不该有的行为。这个类型**保留未知字段**。
public indirect enum MCPValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPValue])
    case object([String: MCPValue])

    // MARK: - 便捷取值

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var arrayValue: [MCPValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: MCPValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> MCPValue? {
        objectValue?[key]
    }
}

// MARK: - 编解码

extension MCPMessage {

    /// 解析一行报文。**解析失败要能被调用方区分**（JSON-RPC 要求回 `-32700`）。
    public static func decode(_ line: String) -> Result<MCPMessage, MCPMessage.MCPError> {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            return .failure(.parseError)
        }
        return decode(object: object)
    }

    static func decode(object: [String: Any]) -> Result<MCPMessage, MCPError> {
        let id = (object["id"]).flatMap(decodeID)
        let method = object["method"] as? String
        let params = MCPValue(any: object["params"] ?? NSNull())

        if let method {
            // 有 id = 请求；没有 id = 通知（MCP 的 `initialized` 就是通知）。
            if let id {
                return .success(.request(id: id, method: method, params: params))
            }
            return .success(.notification(method: method, params: params))
        }

        if let errorObject = object["error"] as? [String: Any] {
            let code = errorObject["code"] as? Int ?? -32603
            let message = errorObject["message"] as? String ?? "Unknown error"
            let data = errorObject["data"].map { MCPValue(any: $0) }
            return .success(.error(id: id, error: MCPError(code: code, message: message, data: data)))
        }

        guard let id else { return .failure(.invalidRequest) }
        return .success(.response(id: id, result: MCPValue(any: object["result"] ?? NSNull())))
    }

    private static func decodeID(_ any: Any) -> MCPID? {
        if let number = any as? Int { return .number(number) }
        if let number = any as? Double { return .number(Int(number)) }
        if let text = any as? String { return .text(text) }
        return nil
    }

    /// 编码成一行（JSON-RPC 行分隔传输：一个报文一行）。
    public func encode() -> String {
        let object: [String: Any]
        switch self {
        case .request(let id, let method, let params):
            object = ["jsonrpc": MCPProtocol.jsonrpc, "id": id.jsonValue.anyValue, "method": method, "params": params.anyValue]
        case .notification(let method, let params):
            object = ["jsonrpc": MCPProtocol.jsonrpc, "method": method, "params": params.anyValue]
        case .response(let id, let result):
            object = ["jsonrpc": MCPProtocol.jsonrpc, "id": id.jsonValue.anyValue, "result": result.anyValue]
        case .error(let id, let error):
            var errorObject: [String: Any] = ["code": error.code, "message": error.message]
            if let data = error.data { errorObject["data"] = data.anyValue }
            object = ["jsonrpc": MCPProtocol.jsonrpc, "id": id?.jsonValue.anyValue ?? NSNull(), "error": errorObject]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"encode failed\"}}"
        }
        return text
    }
}

extension MCPValue {

    public init(any: Any) {
        switch any {
        case let value as NSNull:
            self = .null
            _ = value
        case let value as NSNumber:
            // **必须先区分 Bool 与数字**：`NSNumber` 的 `1` 既能桥成 `Int` 也能桥成 `Bool`，
            // 而 Swift 的 `as? Bool` 会先命中 —— 于是 JSON 里的数字 1 会变成 `true`，
            // 写进 SQL 就是一个"看着没问题"的错误值（本轮实测踩到：`{"a":1}` 读出来成了布尔）。
            // 判据看 `objCType`：布尔是 'c' / 'B'，整数是 'q' / 'i' 等，浮点是 'd' / 'f'。
            let type = String(cString: value.objCType)
            if type == "c" || type == "B" {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .number(Double(value))
        case let value as Double:
            self = .number(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map { MCPValue(any: $0) })
        case let value as [String: Any]:
            self = .object(value.mapValues { MCPValue(any: $0) })
        default:
            self = .null
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues { $0.anyValue }
        }
    }

    /// 便于测试与日志：稳定的紧凑表示。
    public var jsonText: String {
        guard let data = try? JSONSerialization.data(withJSONObject: anyValue, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}
