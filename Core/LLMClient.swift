import Foundation

/// 一次模型调用的请求（与具体协议无关）（FR-AI-01 / FR-AI-02）。
///
/// 刻意只有「提示词 + 采样参数」：**没有任何可以携带结果集行数据的字段**。
/// NFR-AI-01 的「结果集行数据永不外发」因此不是靠调用方自觉，而是类型层面就没有入口。
public struct LLMRequest: Equatable, Sendable {
    public var endpoint: URL
    public var model: String
    public var apiKey: String?
    public var timeoutSeconds: TimeInterval
    public var systemPrompt: String
    public var userPrompt: String
    public var maxOutputTokens: Int?
    public var temperature: Double?

    public init(
        endpoint: URL,
        model: String,
        apiKey: String? = nil,
        timeoutSeconds: TimeInterval = 60,
        systemPrompt: String,
        userPrompt: String,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }
}

/// token 用量（NFR-AI-04 记账 / NFR-AI-03 审计都要用）。
public struct LLMUsage: Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    public static let unknown = LLMUsage()

    /// 记账用 token 数：优先总量，否则把提示与输出相加。
    public var billableTokens: Int {
        if let totalTokens { return max(0, totalTokens) }
        return max(0, (promptTokens ?? 0) + (completionTokens ?? 0))
    }
}

/// 模型返回。
public struct LLMResponse: Equatable, Sendable {
    public var text: String
    public var model: String?
    public var usage: LLMUsage
    public var finishReason: String?

    public init(text: String, model: String? = nil, usage: LLMUsage = .unknown, finishReason: String? = nil) {
        self.text = text
        self.model = model
        self.usage = usage
        self.finishReason = finishReason
    }
}

/// 模型调用错误。
public enum LLMError: Error, Equatable, LocalizedError {
    /// 总开关关闭：不发起任何请求。
    case disabled
    /// 闸门拒绝（配置不完整 / 缺密钥 / 只读策略拒绝等）。
    case forbidden(String)
    /// 配额超限（NFR-AI-04：终止并提示）。
    case quotaExceeded(String)
    /// 网络 / 传输层失败。
    case transport(String)
    /// 非 2xx 响应。
    case httpStatus(code: Int, message: String?)
    /// 响应不是预期的结构。
    case malformedResponse(String)
    /// 模型返回了空内容。
    case emptyCompletion

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "智能体总开关已关闭，未发送任何请求。"
        case .forbidden(let message):
            return message
        case .quotaExceeded(let message):
            return message
        case .transport(let message):
            return "模型服务连接失败：\(message)"
        case .httpStatus(let code, let message):
            return "模型服务返回 HTTP \(code)" + (message.map { "：\($0)" } ?? "。")
        case .malformedResponse(let message):
            return "模型返回内容无法解析：\(message)"
        case .emptyCompletion:
            return "模型返回了空内容。"
        }
    }
}

/// HTTP 传输层抽象：把「发请求」换成可替换的依赖，单测用假实现即可覆盖全部解析逻辑。
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 真实实现：`URLSession`。
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("响应不是 HTTP 响应。")
        }
        return (data, http)
    }
}

/// 模型客户端抽象（FR-AI-02 的「通道」）。
public protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

/// OpenAI 兼容客户端（覆盖云端 OpenAI 协议端点与本地 Ollama / vLLM，NFR-AI-06）。
public struct OpenAICompatibleClient: LLMClient {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// chat completions 路径。
    public static let chatCompletionsPath = "chat/completions"

    /// 把配置里的端点补成 `.../chat/completions`（已是该路径则不重复追加）。
    public static func chatCompletionsURL(from endpoint: URL) -> URL {
        let path = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(chatCompletionsPath) { return endpoint }
        return endpoint.appendingPathComponent(chatCompletionsPath)
    }

    /// 构造 `URLRequest`（单独暴露，便于单测检查「请求里到底发了什么」）。
    public static func makeURLRequest(_ request: LLMRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: chatCompletionsURL(from: request.endpoint))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        // 密钥只进 Authorization 头：不写进请求体（避免被日志 / 审计顺走）。
        if let apiKey = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        urlRequest.httpBody = try makeBody(request)
        return urlRequest
    }

    /// 构造请求体（JSON）。
    public static func makeBody(_ request: LLMRequest) throws -> Data {
        var payload: [String: Any] = [
            "model": request.model,
            "stream": false,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userPrompt]
            ]
        ]
        if let maxOutputTokens = request.maxOutputTokens {
            payload["max_tokens"] = maxOutputTokens
        }
        if let temperature = request.temperature {
            payload["temperature"] = temperature
        }

        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw LLMError.malformedResponse(error.localizedDescription)
        }
    }

    /// 解析响应体；结构不符时给出可读错误。
    public static func parse(_ data: Data) throws -> LLMResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformedResponse("响应不是 JSON 对象。")
        }

        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String
            throw LLMError.malformedResponse(message ?? "模型服务返回了错误对象。")
        }

        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            throw LLMError.malformedResponse("响应里没有 choices。")
        }

        let text: String?
        if let message = first["message"] as? [String: Any] {
            text = message["content"] as? String
        } else {
            // 兼容 legacy completions 的 `text` 字段。
            text = first["text"] as? String
        }
        guard let content = text, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyCompletion
        }

        var usage = LLMUsage.unknown
        if let usageObject = object["usage"] as? [String: Any] {
            usage = LLMUsage(
                promptTokens: usageObject["prompt_tokens"] as? Int,
                completionTokens: usageObject["completion_tokens"] as? Int,
                totalTokens: usageObject["total_tokens"] as? Int
            )
        }

        return LLMResponse(
            text: content,
            model: object["model"] as? String,
            usage: usage,
            finishReason: first["finish_reason"] as? String
        )
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let urlRequest = try Self.makeURLRequest(request)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw LLMError.httpStatus(code: response.statusCode, message: Self.errorMessage(from: data))
        }
        return try Self.parse(data)
    }

    /// 从错误响应里取出可读信息；**不回显请求头**（可能含密钥）。
    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty, text.count <= 500 else { return nil }
            return text
        }
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["type"] as? String)
        }
        return object["message"] as? String
    }
}
