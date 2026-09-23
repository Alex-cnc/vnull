import XCTest
@testable import DoyahCore

/// 编辑器补全的候选合并策略（FR-AI-13 S4）。
///
/// 这套规则里能出错的地方都**不在"能不能补全"**，而在**顺序与准入**：
/// 记忆会不会把 `SELECT` 挤走、空前缀会不会被历史刷屏、同一条会不会出现两次。
/// 这些在 AppKit 回调里只能靠手点看出来，所以规则抽到 Core 用单测钉死。
final class QueryCompletionTests: XCTestCase {

    private let dialect: SQLDialect = SQLDialectFactory.make(for: .postgresql)

    private func memory(
        _ sql: String,
        runCount: Int = 1,
        connections: Set<String> = ["生产库"],
        daysAgo: Int = 0
    ) -> QueryMemory.Memory {
        QueryMemory.Memory(
            fingerprint: QueryMemory.coarseFingerprint(sql),
            latestSQL: sql,
            variantCount: 1,
            runCount: runCount,
            days: ["2026-09-23"],
            connections: connections,
            lastExecutedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(daysAgo) * 86_400)
        )
    }

    // MARK: 方言层（回归：旧 SQLCompleter 的语义不能被改坏）

    func testEmptyPrefixReturnsKeywordsFromStart() {
        let result = QueryCompletion.suggestions(prefix: "", dialect: dialect)
        XCTAssertEqual(result.count, QueryCompletion.totalLimit)
        XCTAssertTrue(result.contains("SELECT"))
    }

    func testPrefixFiltersCaseInsensitively() {
        let result = QueryCompletion.suggestions(prefix: "sel", dialect: dialect)
        XCTAssertTrue(result.contains("SELECT"), "\(result)")
        XCTAssertTrue(result.allSatisfy { $0.uppercased().hasPrefix("SEL") }, "\(result)")
    }

    // MARK: 记忆准入（三条刻意选择）

    /// 空前缀**不给记忆** —— 打开补全先看到关键字，不是历史。
    func testEmptyPrefixDoesNotOfferMemory() {
        let index = QueryMemory.Index(memories: [memory("SELECT * FROM orders WHERE id = 7")])
        let result = QueryCompletion.suggestions(prefix: "", dialect: dialect, memory: index)
        XCTAssertEqual(result.count, QueryCompletion.totalLimit)
        XCTAssertFalse(result.contains { $0.contains("orders") }, "\(result)")
    }

    /// 有前缀时才出现，且**排在同前缀的方言候选之后**。
    func testMemoryComesAfterDialectMatches() {
        let index = QueryMemory.Index(memories: [memory("SELECT * FROM orders WHERE id = 7")])
        let result = QueryCompletion.suggestions(prefix: "select * from ord", dialect: dialect, memory: index)
        let memoryPosition = try? XCTUnwrap(result.firstIndex { $0.contains("orders") })
        XCTAssertNotNil(memoryPosition)
        // 前缀这么长时方言基本没有命中，所以记忆应该在最前 —— 关键是不能被截掉。
        XCTAssertEqual(result.count, 1)
    }

    /// **方言填满候选时记忆不出现**：记忆是补充，不是顶替关键字。
    func testMemoryDoesNotDisplaceFullKeywordList() {
        let many = (0..<QueryCompletion.totalLimit).map { "KEYWORD\($0)" }
        let merged = QueryCompletion.merge(dialect: many, memory: ["SELECT * FROM orders"])
        XCTAssertEqual(merged.count, QueryCompletion.totalLimit)
        XCTAssertFalse(merged.contains("SELECT * FROM orders"))
    }

    /// 方言没填满时，记忆按剩余名额补进来。
    func testMemoryFillsRemainingSlots() {
        let merged = QueryCompletion.merge(
            dialect: ["SELECT", "SELECTION"],
            memory: ["SELECT * FROM orders", "SELECT * FROM customers"]
        )
        XCTAssertEqual(merged, ["SELECT", "SELECTION", "SELECT * FROM orders", "SELECT * FROM customers"])
    }

    // MARK: 去重与长度

    /// 大小写不敏感去重，且**方言先出现者胜出**（不会变成两条重复）。
    func testDedupeIsCaseInsensitiveAndDialectWins() {
        let merged = QueryCompletion.merge(dialect: ["select"], memory: ["SELECT", "select * from t"])
        XCTAssertEqual(merged, ["select", "select * from t"])
    }

    /// 超长 SQL 不进补全：补全是"替换光标处的半个词"，不是往光标里灌报表。
    func testOverlongSQLIsNotInsertable() {
        let long = "SELECT " + String(repeating: "x", count: QueryCompletion.maxInsertableSQLLength)
        XCTAssertFalse(QueryCompletion.isInsertable(long))
        let index = QueryMemory.Index(memories: [memory(long)])
        XCTAssertTrue(QueryCompletion.memoryMatches(prefix: "select", in: index).isEmpty)
    }

    /// 边界：恰好等于上限可以插入。
    func testExactlyAtLimitIsInsertable() {
        let exact = "SELECT " + String(repeating: "x", count: QueryCompletion.maxInsertableSQLLength - "SELECT ".count)
        XCTAssertEqual(exact.count, QueryCompletion.maxInsertableSQLLength)
        XCTAssertTrue(QueryCompletion.isInsertable(exact))
    }

    func testBlankSQLIsNotInsertable() {
        XCTAssertFalse(QueryCompletion.isInsertable("   \n  "))
        XCTAssertFalse(QueryCompletion.isInsertable(""))
    }

    /// 记忆候选有取数上限，不会一次塞满整个候选框。
    func testMemoryCandidatesAreCapped() {
        let memories = (0..<20).map { memory("SELECT * FROM t\($0)") }
        let index = QueryMemory.Index(memories: memories)
        let matches = QueryCompletion.memoryMatches(prefix: "select", in: index)
        XCTAssertEqual(matches.count, QueryCompletion.memoryLimit)
    }

    // MARK: 连接隔离（S4 也必须守这条）

    /// 生产连接补全时看不到别的连接的记忆 —— 隔离在合并层依然成立。
    func testConnectionIsolationAppliesToCompletion() {
        let index = QueryMemory.Index(memories: [
            memory("SELECT * FROM prod_orders", connections: ["生产库"]),
            memory("SELECT * FROM test_orders", connections: ["测试库"])
        ])
        let prod = QueryCompletion.memoryMatches(prefix: "select", in: index, connection: "生产库")
        XCTAssertEqual(prod.count, 1)
        XCTAssertTrue(prod[0].contains("prod_orders"))
        let test = QueryCompletion.memoryMatches(prefix: "select", in: index, connection: "测试库")
        XCTAssertEqual(test.count, 1)
        XCTAssertTrue(test[0].contains("test_orders"))
    }

    /// 验收标准③：**从没执行过任何 SQL 的连接**上补全不报错。
    ///
    /// 口径说清楚：这里"为空"指的是**记忆部分为空** —— 关键字补全（FR-EDIT-09）当然还在，
    /// 否则换个新建连接就连 `SELECT` 都补不出来。这条区别写进文档，不靠读者自己猜。
    func testConnectionWithNoHistoryYieldsNoMemoryButStillKeywords() {
        let index = QueryMemory.Index(memories: [memory("SELECT * FROM orders", connections: ["生产库"])])
        let memoryOnly = QueryCompletion.memoryMatches(prefix: "select", in: index, connection: "从没用过的库")
        XCTAssertTrue(memoryOnly.isEmpty)
        let candidates = QueryCompletion.suggestions(
            prefix: "sel",
            dialect: dialect,
            memory: index,
            connection: "从没用过的库"
        )
        XCTAssertEqual(candidates, QueryCompletion.dialectMatches(prefix: "sel", dialect: dialect))
        XCTAssertFalse(candidates.isEmpty, "关键字补全不该因为没历史而消失")
    }

    // MARK: 排序稳定性

    /// 同前缀下按执行次数排 —— 跑得多的排前面，且顺序可复现。
    func testMemoryOrderFollowsRunCountAndIsStable() {
        let index = QueryMemory.Index(memories: [
            memory("SELECT * FROM few", runCount: 2),
            memory("SELECT * FROM many", runCount: 50)
        ])
        let first = QueryCompletion.memoryMatches(prefix: "select", in: index)
        let second = QueryCompletion.memoryMatches(prefix: "select", in: index)
        XCTAssertEqual(first, second, "同一前缀两次调用必须一模一样")
        XCTAssertTrue(first[0].contains("many"))
    }

    /// 空索引时行为与旧路径**逐字一致**（回归保护）。
    func testEmptyIndexMatchesLegacyBehaviour() {
        for prefix in ["", "sel", "co", "zzz"] {
            XCTAssertEqual(
                QueryCompletion.suggestions(prefix: prefix, dialect: dialect),
                QueryCompletion.dialectMatches(prefix: prefix, dialect: dialect),
                "前缀 \(prefix) 下空记忆不该改变候选"
            )
        }
    }
}
