import XCTest
@testable import DoyahCore

/// FR-AI-10 MCP 双向：协议编解码 + 工具裁决 + 两个方向的会话状态机。
///
/// **不需要网络、不需要真实 MCP 服务器、不需要数据库**：这一层是纯报文与纯判决。
final class MCPTests: XCTestCase {

    private func session(
        hasConnection: Bool = true,
        isReadOnly: Bool = false,
        approved: Set<String> = []
    ) -> MCPServerSession {
        MCPServerSession(
            capabilities: .init(
                hasConnection: hasConnection,
                isReadOnly: isReadOnly,
                target: "postgres@127.0.0.1:5432/analytics",
                approvedCalls: approved
            )
        )
    }

    private func initializeLine(id: Int = 1) -> String {
        MCPMessage.request(
            id: .number(id),
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                "clientInfo": .object(["name": .string("claude-desktop")]),
            ])
        ).encode()
    }

    private func callLine(tool: String, arguments: MCPValue, id: Int = 2) -> String {
        MCPMessage.request(
            id: .number(id),
            method: "tools/call",
            params: .object(["name": .string(tool), "arguments": arguments])
        ).encode()
    }

    // MARK: - 协议编解码

    func testRequestRoundTrip() throws {
        let line = MCPMessage.request(
            id: .text("abc"),
            method: "tools/call",
            params: .object(["name": .string("query_sql")])
        ).encode()
        guard case .success(let decoded) = MCPMessage.decode(line) else {
            return XCTFail("解不回来")
        }
        XCTAssertEqual(decoded, .request(id: .text("abc"), method: "tools/call", params: .object(["name": .string("query_sql")])))
    }

    /// 通知（没有 id）必须被认成通知，而不是"缺 id 的请求"。
    func testNotificationHasNoIDAndNeedsNoReply() {
        let line = MCPMessage.notification(method: "notifications/initialized", params: .object([:])).encode()
        guard case .success(let decoded) = MCPMessage.decode(line) else { return XCTFail("解不回来") }
        guard case .notification(let method, _) = decoded else { return XCTFail("应当是通知：\(decoded)") }
        XCTAssertEqual(method, "notifications/initialized")
    }

    func testMalformedLineReportsParseError() {
        guard case .failure(let error) = MCPMessage.decode("这不是 JSON") else {
            return XCTFail("坏报文必须报 -32700")
        }
        XCTAssertEqual(error.code, -32700)
    }

    /// **未知字段要保留**（互操作里最不该有的行为就是"见到没见过的字段就整条失败"）。
    func testUnknownFieldsArePreserved() {
        let line = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"x","arguments":{},"futureField":{"a":1}}}"#
        guard case .success(let message) = MCPMessage.decode(line),
              case .request(_, _, let params) = message else { return XCTFail("解不回来") }
        XCTAssertEqual(params["futureField"]?["a"]?.intValue, 1)
    }

    // MARK: - server 方向：握手 / 工具清单 / 权限继承

    func testInitializeReportsOurProtocolVersionAndAudits() {
        var session = self.session()
        let outcome = session.handle(line: initializeLine())
        XCTAssertEqual(outcome.replies.count, 1)
        guard case .response(let id, let result) = outcome.replies[0] else { return XCTFail("应当回响应") }
        XCTAssertEqual(id, .number(1))
        XCTAssertEqual(result["protocolVersion"]?.stringValue, "2024-11-05")
        XCTAssertEqual(result["serverInfo"]?["name"]?.stringValue, "DoyahStudio")
        XCTAssertTrue(session.isInitialized)
        XCTAssertEqual(session.clientName, "claude-desktop")
        XCTAssertEqual(session.audit.last?.tool, "initialize")
    }

    /// 对方给了别的协议版本时**如实回报我们支持的版本**，并把它记在结果里（不假装兼容）。
    func testDifferentProtocolVersionIsReportedNotFaked() {
        var session = self.session()
        let line = MCPMessage.request(
            id: .number(1),
            method: "initialize",
            params: .object(["protocolVersion": .string("2099-01-01")])
        ).encode()
        let outcome = session.handle(line: line)
        guard case .response(_, let result) = outcome.replies[0] else { return XCTFail("应当回响应") }
        XCTAssertEqual(result["protocolVersion"]?.stringValue, MCPProtocol.version)
        XCTAssertEqual(result["capabilities"]?["experimental"]?["requestedProtocolVersion"]?.stringValue, "2099-01-01")
    }

    func testToolsListExposesExactlyTheFourCatalogTools() {
        var session = self.session()
        _ = session.handle(line: initializeLine())
        let outcome = session.handle(line: MCPMessage.request(id: .number(2), method: "tools/list", params: .object([:])).encode())
        guard case .response(_, let result) = outcome.replies[0] else { return XCTFail("应当回响应") }
        let names = result["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertEqual(names.sorted(), ["describe_table", "export_result", "list_objects", "query_sql"])
    }

    /// **没握手就调工具**：协议上说不过去，如实拒（不假装成功）。
    func testToolCallBeforeInitializeIsRefused() {
        var session = self.session()
        let outcome = session.handle(line: callLine(tool: MCPToolCatalog.querySQL, arguments: .object(["sql": .string("SELECT 1")])))
        guard case .error(_, let error) = outcome.replies[0] else { return XCTFail("应当回错误") }
        XCTAssertEqual(error.code, -32600)
        XCTAssertNil(outcome.invocation)
    }

    func testUnknownMethodIsMethodNotFound() {
        var session = self.session()
        let outcome = session.handle(
            line: MCPMessage.request(id: .number(9), method: "prompts/list", params: .object([:])).encode()
        )
        guard case .error(_, let error) = outcome.replies[0] else { return XCTFail("应当回错误") }
        XCTAssertEqual(error.code, -32601)
    }

    /// **没暴露的工具一律拒绝**，并留审计（外部智能体不该能猜到我们内部有什么）。
    func testUnexposedToolIsRefusedAndAudited() {
        var session = self.session()
        _ = session.handle(line: initializeLine())
        let outcome = session.handle(line: callLine(tool: "run_shell", arguments: .object([:]), id: 3))
        XCTAssertNil(outcome.invocation)
        XCTAssertEqual(session.audit.last?.outcome, "not-exposed")
    }

    // MARK: - server 方向：审批与"不另开权限"

    func testReadQueryIsAllowedWithoutApproval() {
        var session = self.session()
        _ = session.handle(line: initializeLine())
        let outcome = session.handle(
            line: callLine(tool: MCPToolCatalog.querySQL, arguments: .object(["sql": .string("SELECT * FROM customers")]), id: 4)
        )
        XCTAssertEqual(outcome.invocation?.tool, MCPToolCatalog.querySQL)
        XCTAssertEqual(session.audit.last?.outcome, "allowed(readQuery)")
    }

    /// **写语句即使在 `query_sql` 里也要审批** —— 判据是语句内容，不是工具名。
    func testWriteStatementInsideQueryToolNeedsApproval() {
        var session = self.session()
        _ = session.handle(line: initializeLine())
        let outcome = session.handle(
            line: callLine(tool: MCPToolCatalog.querySQL, arguments: .object(["sql": .string("DELETE FROM customers")]), id: 5)
        )
        XCTAssertNil(outcome.invocation, "没批准之前不许执行")
        XCTAssertEqual(session.audit.last?.outcome, "needs-approval")
        XCTAssertTrue(outcome.replies[0].encode().contains("isError"))
    }

    func testApprovedWriteIsAllowed() {
        var session = session(approved: [
            MCPToolCatalog.callFingerprint(
                tool: MCPToolCatalog.querySQL,
                arguments: .object(["sql": .string("UPDATE customers SET name = 'x' WHERE id = 1")])
            )
        ])
        _ = session.handle(line: initializeLine())
        let outcome = session.handle(
            line: callLine(tool: MCPToolCatalog.querySQL, arguments: .object(["sql": .string("UPDATE customers SET name = 'x' WHERE id = 1")]), id: 6)
        )
        XCTAssertEqual(outcome.invocation?.tool, MCPToolCatalog.querySQL)
    }

    /// **只读连接上写语句被拒，且"已批准"也救不回来**（与 `ExecutionSafety` 同一条不可绕过的口径）。
    func testReadOnlyConnectionRefusesWritesEvenWhenApproved() {
        var session = session(isReadOnly: true, approved: [
            MCPToolCatalog.callFingerprint(
                tool: MCPToolCatalog.querySQL,
                arguments: .object(["sql": .string("UPDATE customers SET name = 'x'")])
            )
        ])
        _ = session.handle(line: initializeLine())
        let outcome = session.handle(
            line: callLine(tool: MCPToolCatalog.querySQL, arguments: .object(["sql": .string("UPDATE customers SET name = 'x'")]), id: 7)
        )
        XCTAssertNil(outcome.invocation)
        XCTAssertEqual(session.audit.last?.outcome, "refused")
    }

    /// **没有会话就不动**：外部调用一律不另开连接。
    func testNoConnectionMeansNoInvocation() {
        var session = session(hasConnection: false)
        _ = session.handle(line: initializeLine())
        let outcome = session.handle(
            line: callLine(tool: MCPToolCatalog.querySQL, arguments: .object(["sql": .string("SELECT 1")]), id: 8)
        )
        XCTAssertNil(outcome.invocation)
        XCTAssertEqual(session.audit.last?.outcome, "no-session")
    }

    func testFinishWrapsResultAsMCPContent() throws {
        var session = session()
        _ = session.handle(line: initializeLine())
        let outcome = session.handle(
            line: callLine(tool: MCPToolCatalog.listObjects, arguments: .object([:]), id: 9)
        )
        let invocation = try XCTUnwrap(outcome.invocation)
        let reply = try XCTUnwrap(session.finish(invocation, text: "customers\norders"))
        guard case .response(let id, let result) = reply else { return XCTFail("应当回响应") }
        XCTAssertEqual(id, .number(9))
        XCTAssertEqual(result["content"]?.arrayValue?.first?["text"]?.stringValue, "customers\norders")
        XCTAssertEqual(result["isError"]?.boolValue, false)
    }

    // MARK: - 审计

    func testEveryCallLeavesAnAuditEntry() {
        var session = session()
        _ = session.handle(line: initializeLine())
        _ = session.handle(line: callLine(tool: MCPToolCatalog.querySQL, arguments: .object(["sql": .string("SELECT 1")]), id: 2))
        _ = session.handle(line: callLine(tool: MCPToolCatalog.exportResult, arguments: .object(["sql": .string("SELECT 1"), "path": .string("/tmp/x.csv")]), id: 3))
        let tools = session.audit.map(\.tool)
        XCTAssertEqual(tools, ["initialize", MCPToolCatalog.querySQL, MCPToolCatalog.exportResult])
        XCTAssertEqual(session.audit.last?.outcome, "needs-approval")
        XCTAssertTrue(session.audit.allSatisfy { !$0.argumentsSummary.contains("口令") })
    }

    // MARK: - host 方向（同一套报文，另一个角色）

    func testClientSessionHandshakeAndToolList() {
        var client = MCPClientSession()
        let initialize = client.initializeRequest()
        guard case .request(let id, let method, _) = initialize else { return XCTFail("应当是请求") }
        XCTAssertEqual(id, .number(1))
        XCTAssertEqual(method, "initialize")

        let reply = MCPMessage.response(
            id: id,
            result: .object([
                "protocolVersion": .string("2024-11-05"),
                "serverInfo": .object(["name": .string("files"), "version": .string("0.1")]),
            ])
        ).encode()
        XCTAssertTrue(client.receive(line: reply))
        XCTAssertTrue(client.isInitialized)
        XCTAssertEqual(client.serverName, "files")

        let listRequest = client.toolsListRequest()
        guard case .request(let listID, _, _) = listRequest else { return XCTFail("应当是请求") }
        _ = client.receive(
            message: .response(
                id: listID,
                result: .object([
                    "tools": .array([
                        .object(["name": .string("read_file"), "description": .string("Read a file")]),
                        .object(["name": .string("write_file"), "description": .string("Write a file")]),
                    ])
                ])
            )
        )
        XCTAssertEqual(client.tools.map(\.name), ["read_file", "write_file"])
    }

    func testClientSessionParsesToolCallContentAndErrors() {
        var client = MCPClientSession()
        _ = client.initializeRequest()
        let call = client.toolsCallRequest(tool: "echo", arguments: .object(["text": .string("你好")]))
        guard case .request(let id, _, _) = call else { return XCTFail("应当是请求") }
        _ = client.receive(
            message: .response(
                id: id,
                result: .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("你好")])]),
                    "isError": .bool(false),
                ])
            )
        )
        XCTAssertEqual(client.lastResult, "你好")
        XCTAssertFalse(client.hasError())

        let failing = client.toolsCallRequest(tool: "boom", arguments: .object([:]))
        guard case .request(let failID, _, _) = failing else { return XCTFail("应当是请求") }
        _ = client.receive(
            message: .response(
                id: failID,
                result: .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("炸了")])]),
                    "isError": .bool(true),
                ])
            )
        )
        XCTAssertTrue(client.hasError())
        XCTAssertEqual(client.lastError, "炸了")
    }

    func testClientSessionReportsServerError() {
        var client = MCPClientSession()
        XCTAssertFalse(client.receive(line: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#))
        XCTAssertEqual(client.lastError, "Method not found")
    }
}
