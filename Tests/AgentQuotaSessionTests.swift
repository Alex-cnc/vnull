import XCTest
@testable import DoyahCore

/// 配额是**会话级**的（NFR-AI-04）：账本必须跨调用累计，否则上限永远触发不了。
///
/// 这组测试钉住的是"调用方该怎么用它"：把上一次返回的 `quotaLedger` 传给下一次。
/// 之所以值得单独钉：`AppState` 此前每次都传 `.empty`，于是「调用次数 / 累计 token」
/// 这两个上限**在真实路径上永远不会生效** —— 判定代码全对，接线错了。
final class AgentQuotaSessionTests: XCTestCase {

    private func configuration(
        maxRequests: Int? = nil,
        maxTotalTokens: Int? = nil
    ) -> AgentConfiguration {
        AgentConfiguration(
            isEnabled: true,
            endpoint: "http://127.0.0.1:11434",
            model: "qwen2.5:7b",
            quota: AgentQuota(
                maxRequestsPerSession: maxRequests,
                maxOutputTokensPerRequest: nil,
                maxTotalTokens: maxTotalTokens
            )
        )
    }

    /// 只回文本的假客户端（本文件自备：别的测试文件里的同名类型是 fileprivate）。
    private struct StubClient: LLMClient {
        var text: String
        var usage: LLMUsage

        func complete(_ request: LLMRequest) async throws -> LLMResponse {
            LLMResponse(text: text, model: request.model, usage: usage, finishReason: "stop")
        }
    }

    private func generate(
        ledger: AgentQuotaLedger,
        usageTokens: Int,
        configuration: AgentConfiguration
    ) async throws -> AgentSQLGenerator.Result {
        let client = StubClient(
            text: "SELECT 1",
            usage: LLMUsage(promptTokens: usageTokens / 2, completionTokens: usageTokens / 2, totalTokens: usageTokens)
        )
        return try await AgentSQLGenerator.generate(
            request: .init(instruction: "列出用户", schema: AgentSQLGenerator.SchemaSummary(tables: [])),
            configuration: configuration,
            apiKey: nil,
            ledger: ledger,
            client: client
        )
    }

    /// 会话内第 3 次调用超过「最多 2 次」：**终止并给出可读原因**，不是静默失败。
    func testRequestLimitTriggersOnThirdCallInSession() async throws {
        let configuration = configuration(maxRequests: 2)

        let first = try await generate(ledger: .empty, usageTokens: 10, configuration: configuration)
        XCTAssertEqual(first.quotaLedger.requestCount, 1)

        // 第二次：把上一次的账本带上 —— 这正是真实调用方必须做的事。
        let second = try await generate(ledger: first.quotaLedger, usageTokens: 10, configuration: configuration)
        XCTAssertEqual(second.quotaLedger.requestCount, 2)

        do {
            _ = try await generate(ledger: second.quotaLedger, usageTokens: 10, configuration: configuration)
            XCTFail("第 3 次应当被配额拦下")
        } catch let error as LLMError {
            guard case .quotaExceeded(let message) = error else {
                return XCTFail("应当是 quotaExceeded，实际：\(error)")
            }
            XCTAssertFalse(message.isEmpty, "超限必须给可读原因")
        }
    }

    /// 累计 token 上限：**用满即拦**。
    func testUsedUpTokenBudgetBlocksNextCall() async throws {
        let configuration = configuration(maxTotalTokens: 200)

        let first = try await generate(ledger: .empty, usageTokens: 150, configuration: configuration)
        XCTAssertEqual(first.quotaLedger.totalTokens, 150)
        // 150 < 200，这一段还没用满 —— 下一次仍可发。
        let second = try await generate(ledger: first.quotaLedger, usageTokens: 50, configuration: configuration)
        XCTAssertEqual(second.quotaLedger.totalTokens, 200)

        do {
            _ = try await generate(ledger: second.quotaLedger, usageTokens: 10, configuration: configuration)
            XCTFail("累计量已达上限时应当被拦下")
        } catch let error as LLMError {
            guard case .quotaExceeded(let message) = error else {
                return XCTFail("应当是 quotaExceeded，实际：\(error)")
            }
            XCTAssertTrue(message.contains("200") || message.contains("token"), message)
        }
    }

    /// **提前拦**：本次预算会把累计量顶过上限时，请求根本不发出去（此前这条永远不会触发 ——
    /// 调用方传进来的就是它自己比较的那个上限值，见 v3.88）。
    func testCallIsBlockedBeforeItWouldExceedBudget() async throws {
        let configuration = AgentConfiguration(
            isEnabled: true,
            endpoint: "http://127.0.0.1:11434",
            model: "qwen2.5:7b",
            quota: AgentQuota(
                maxRequestsPerSession: nil,
                maxOutputTokensPerRequest: 100,
                maxTotalTokens: 200
            )
        )
        let transport = CountingTransport()
        let client = OpenAICompatibleClient(transport: transport)

        // 已用 150，本次最多再花 100 → 预计 250 > 200：应当**在发送前**就被拦。
        do {
            _ = try await AgentSQLGenerator.generate(
                request: .init(instruction: "x", schema: AgentSQLGenerator.SchemaSummary(tables: [])),
                configuration: configuration,
                apiKey: nil,
                ledger: AgentQuotaLedger(requestCount: 0, totalTokens: 150),
                client: client
            )
            XCTFail("预计超预算时应当在发送前被拦下")
        } catch let error as LLMError {
            guard case .quotaExceeded = error else { return XCTFail("应当是 quotaExceeded，实际：\(error)") }
        }

        XCTAssertEqual(transport.sendCount, 0, "被拦下时一次请求都不该发出")
    }

    /// 每次都从零开始的账本 = 上限永远不生效 —— 这条测试把这个错误用法钉成"反例"。
    func testRestartingLedgerEachCallNeverTriggersLimit() async throws {
        let configuration = configuration(maxRequests: 1)

        // 正确的用法：第一次就被 1 次的上限挡住? 不 —— 上限是"已经用掉 1 次之后不能再发"。
        _ = try await generate(ledger: .empty, usageTokens: 5, configuration: configuration)

        // 错误用法（此前 AppState 就是这样）：每次传空账本 → 第二次、第三次照样能发出去。
        for _ in 0..<3 {
            _ = try await generate(ledger: .empty, usageTokens: 5, configuration: configuration)
        }

        // 正确用法：带上累计账本，立刻被拦。
        do {
            _ = try await generate(ledger: AgentQuotaLedger(requestCount: 1, totalTokens: 5), usageTokens: 5, configuration: configuration)
            XCTFail("累计账本下应当被拦下")
        } catch let error as LLMError {
            guard case .quotaExceeded = error else { return XCTFail("应当是 quotaExceeded，实际：\(error)") }
        }
    }

    /// 不设上限时不该被拦（nil = 不限）。
    func testNoLimitsMeansNoBlocking() async throws {
        let configuration = configuration()
        var ledger = AgentQuotaLedger.empty
        for _ in 0..<5 {
            let result = try await generate(ledger: ledger, usageTokens: 1_000, configuration: configuration)
            ledger = result.quotaLedger
        }
        XCTAssertEqual(ledger.requestCount, 5)
    }

    /// 被拦下时**不该发出请求**：配额判定在请求组装之前（省下的是真金白银）。
    func testBlockedCallDoesNotSendRequest() async throws {
        let transport = CountingTransport()
        let client = OpenAICompatibleClient(transport: transport)
        let configuration = configuration(maxRequests: 1)

        do {
            _ = try await AgentSQLGenerator.generate(
                request: .init(instruction: "x", schema: AgentSQLGenerator.SchemaSummary(tables: [])),
                configuration: configuration,
                apiKey: nil,
                ledger: AgentQuotaLedger(requestCount: 1, totalTokens: 0),
                client: client
            )
            XCTFail("应当被拦下")
        } catch {
            // 期望：抛错且一次请求都没发。
        }

        XCTAssertEqual(transport.sendCount, 0, "被配额拦下时不该发出任何请求")
    }

    /// 只数请求次数的传输层。
    private final class CountingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var sendCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock()
            count += 1
            lock.unlock()
            let body = #"{"choices":[{"message":{"content":"SELECT 1"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }
}
