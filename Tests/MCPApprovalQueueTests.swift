import XCTest
@testable import DoyahCore

/// FR-AI-10 的"界面审批"那一半：文件队列（入队 / 待办 / 决定 / 反悔 / 坏行容错）。
final class MCPApprovalQueueTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doyah-mcp-approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> MCPApprovalStore { MCPApprovalStore(directory: directory) }

    func testEnqueueAppearsInPending() throws {
        let store = store()
        let request = try store.enqueue(
            client: "claude-desktop",
            tool: MCPToolCatalog.querySQL,
            argumentsSummary: #"{"sql":"DELETE FROM customers"}"#,
            fingerprint: MCPToolCatalog.callFingerprint(
                tool: MCPToolCatalog.querySQL,
                arguments: .object(["sql": .string("DELETE FROM customers")])
            ),
            sql: "DELETE FROM customers",
            reason: "写语句"
        )
        let pending = try store.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].id, request.id)
        XCTAssertEqual(pending[0].sql, "DELETE FROM customers")
        XCTAssertEqual(pending[0].client, "claude-desktop")
    }

    func testDecidedRequestLeavesPendingButStaysOnRecord() throws {
        let store = store()
        let request = try store.enqueue(
            client: "c", tool: "query_sql", argumentsSummary: "{}", fingerprint: "f", sql: "SELECT 1", reason: "r"
        )
        try store.decide(requestID: request.id, approved: true)
        XCTAssertTrue(try store.pending().isEmpty, "决定之后就不该再出现在待办里")
        XCTAssertEqual(try store.decision(for: request.id), true)
        XCTAssertEqual(try store.requests().count, 1, "请求本身要留在记录里")
    }

    /// **反悔**：同一个请求再决定一次，以**最后一条**为准（于是"批准后又拒绝"也留痕）。
    func testLastDecisionWins() throws {
        let store = store()
        let request = try store.enqueue(
            client: "c", tool: "query_sql", argumentsSummary: "{}", fingerprint: "f", sql: "DROP TABLE t", reason: "r"
        )
        try store.decide(requestID: request.id, approved: true)
        try store.decide(requestID: request.id, approved: false)
        XCTAssertEqual(try store.decision(for: request.id), false)
    }

    /// 按指纹回查：server 侧就是这么把"用户刚批准的那一次"对回来的。
    func testLatestDecisionForFingerprint() throws {
        let store = store()
        let fingerprint = MCPToolCatalog.callFingerprint(
            tool: MCPToolCatalog.querySQL,
            arguments: .object(["sql": .string("CREATE TEMP TABLE t (id int)")])
        )
        let first = try store.enqueue(
            client: "c", tool: "query_sql", argumentsSummary: "{}", fingerprint: fingerprint,
            sql: "CREATE TEMP TABLE t (id int)", reason: "r"
        )
        XCTAssertNil(try store.latestDecision(forFingerprint: fingerprint), "还没决定时应当是 nil（不是 false）")

        try store.decide(requestID: first.id, approved: true)
        let found = try store.latestDecision(forFingerprint: fingerprint)
        XCTAssertEqual(found?.approved, true)
        XCTAssertEqual(found?.request.id, first.id)

        // 同一个指纹再入队一次、再拒绝：回查应当拿到**最近**那次的决定。
        let second = try store.enqueue(
            client: "c", tool: "query_sql", argumentsSummary: "{}", fingerprint: fingerprint,
            sql: "CREATE TEMP TABLE t (id int)", reason: "r"
        )
        try store.decide(requestID: second.id, approved: false)
        XCTAssertEqual(try store.latestDecision(forFingerprint: fingerprint)?.approved, false)
    }

    /// 坏行**跳过但报数**（一个坏行不该让整条审批链不可用，也不该静默少几条）。
    func testMalformedLinesAreSkippedAndCounted() throws {
        let store = store()
        _ = try store.enqueue(
            client: "c", tool: "query_sql", argumentsSummary: "{}", fingerprint: "f", sql: "SELECT 1", reason: "r"
        )
        let handle = try FileHandle(forWritingTo: store.pendingURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{这不是 JSON}\n".utf8))
        try handle.close()

        XCTAssertEqual(try store.pending().count, 1, "坏行不该让好行读不出来")
        XCTAssertEqual(store.malformedLineCount(), 1)
    }

    func testPruneDecidedKeepsUndecided() throws {
        let store = store()
        let a = try store.enqueue(client: "c", tool: "t", argumentsSummary: "{}", fingerprint: "fa", sql: nil, reason: "r")
        _ = try store.enqueue(client: "c", tool: "t", argumentsSummary: "{}", fingerprint: "fb", sql: nil, reason: "r")
        try store.decide(requestID: a.id, approved: true)
        try store.pruneDecided()
        let remaining = try store.pending()
        XCTAssertEqual(remaining.count, 1, "没决定的要留着")
        XCTAssertEqual(remaining[0].fingerprint, "fb")
    }

    /// 两侧必须算出**同一个**默认目录 —— 否则界面写的决定 server 读不到。
    func testDefaultStoreIsStable() {
        let first = MCPApprovalStore.defaultStore(environment: [:]).directory
        let second = MCPApprovalStore.defaultStore(environment: [:]).directory
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.path.contains("DoyahStudio"))
        XCTAssertTrue(first.path.hasSuffix("mcp-approvals"))
    }

    /// 环境变量能把队列整体挪走（探针与脚本用；两侧都读同一个变量，所以仍然一致）。
    func testEnvironmentOverrideMovesTheQueue() {
        let overridden = MCPApprovalStore.defaultStore(environment: ["DOYAH_MCP_APPROVAL_DIR": "/tmp/doyah-probe"])
        XCTAssertEqual(overridden.directory.path, "/tmp/doyah-probe")
        // 空值不算覆盖（否则一个空环境变量会把队列指到当前目录，那是个很隐蔽的坑）。
        let empty = MCPApprovalStore.defaultStore(environment: ["DOYAH_MCP_APPROVAL_DIR": ""])
        XCTAssertTrue(empty.directory.path.contains("DoyahStudio"))
    }
}
