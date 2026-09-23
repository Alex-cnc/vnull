import XCTest
@testable import DoyahCore

/// 查询记忆层（FR-AI-13）：粗指纹归一、按连接隔离、补全排序稳定。
///
/// 这一层最容易做错的是**归一化的松紧**：太松会把查订单的推荐给查客户的人，
/// 太紧则同一查询碎成几千条、候选全是噪音。
final class QueryMemoryTests: XCTestCase {

    // MARK: 粗指纹（归一化的松紧）

    /// 同一件事的不同取值 / 写法 → 同一个骨架。
    func testSameStructureWithDifferentLiteralsCollapses() {
        let a = QueryMemory.coarseFingerprint("SELECT * FROM orders WHERE id = 1")
        let b = QueryMemory.coarseFingerprint("select *  from orders where id = 42")
        XCTAssertEqual(a, b, "字面量、大小写、空白都不该把它拆成两条")
        XCTAssertTrue(a.contains("orders"))
        XCTAssertTrue(a.contains("?"), a)
    }

    /// **不同表必须算不同骨架** —— 否则补全会张冠李戴。
    func testDifferentTablesStayDistinct() {
        let orders = QueryMemory.coarseFingerprint("SELECT * FROM orders WHERE id = 1")
        let customers = QueryMemory.coarseFingerprint("SELECT * FROM customers WHERE id = 1")
        XCTAssertNotEqual(orders, customers)
    }

    /// 字符串里的引号转义不能把后续内容判错（`'it''s'` 是一个字面量）。
    func testEscapedQuotesInsideLiteral() {
        let fingerprint = QueryMemory.coarseFingerprint("SELECT * FROM t WHERE note = 'it''s ok' AND id = 3")
        XCTAssertEqual(fingerprint, "select * from t where note = '?' and id = ?")
    }

    func testDecimalAndNumbersCollapse() {
        XCTAssertEqual(
            QueryMemory.coarseFingerprint("WHERE amount > 12.5"),
            QueryMemory.coarseFingerprint("WHERE amount > 99.75")
        )
    }

    func testEmptySQLGivesEmptyFingerprint() {
        XCTAssertEqual(QueryMemory.coarseFingerprint("   "), "")
    }

    // MARK: 索引构建

    private func makeArchiveDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueryMemoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ entries: [SQLArchiveEntry], to directory: URL, fileName: String) throws {
        // `render` 要 day 参数（决定文件里的日期头）；条目本身带时间，取其中最早的一天即可。
        let day = entries.map(\.firstExecutedAt).min() ?? Date(timeIntervalSince1970: 1_760_000_000)
        try SQLArchive.render(entries, day: day).write(
            to: directory.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeEntry(
        _ sql: String,
        connection: String = "生产库",
        at date: Date,
        runCount: Int = 1
    ) -> SQLArchiveEntry {
        SQLArchiveEntry(
            sql: sql,
            firstExecutedAt: date,
            lastExecutedAt: date,
            runCount: runCount,
            connection: connection,
            database: "app"
        )
    }

    /// 频次跨文件累加、跨天集合正确、原文取最近那版。
    func testBuildIndexAggregatesAcrossFiles() throws {
        let directory = try makeArchiveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let day1 = Date(timeIntervalSince1970: 1_760_000_000)   // 固定时间，避免依赖"今天"
        let day2 = day1.addingTimeInterval(86_400)
        try write([makeEntry("SELECT * FROM orders WHERE id = 1", at: day1, runCount: 3)], to: directory, fileName: "2026-09-21.sql")
        try write([makeEntry("SELECT * FROM orders WHERE id = 2", at: day2, runCount: 2)], to: directory, fileName: "2026-09-22.sql")

        let index = QueryMemory.buildIndex(directory: directory)
        XCTAssertEqual(index.parsedEntryCount, 2)
        XCTAssertEqual(index.memories.count, 1, "同一个骨架应当聚合成一条记忆")

        let memory = try XCTUnwrap(index.memories.first)
        XCTAssertEqual(memory.runCount, 5, "次数要跨文件累加（3 + 2）")
        XCTAssertEqual(memory.variantCount, 2, "两份不同的原文")
        XCTAssertTrue(memory.spansMultipleDays, "跨了两天")
        XCTAssertEqual(memory.latestSQL, "SELECT * FROM orders WHERE id = 2", "原文取最近那版")
    }

    /// 坏文件 / 非归档文件要被记下来并继续，而不是让整个记忆层不可用。
    func testBadFilesAreSkippedAndReported() throws {
        let directory = try makeArchiveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try "这不是归档文件".write(to: directory.appendingPathComponent("random.sql"), atomically: true, encoding: .utf8)
        try write([makeEntry("SELECT 1", at: Date(timeIntervalSince1970: 1_760_000_000))], to: directory, fileName: "2026-09-21.sql")

        let index = QueryMemory.buildIndex(directory: directory)
        XCTAssertEqual(index.memories.count, 1, "好文件仍然要建出索引")
        XCTAssertTrue(index.skippedFiles.contains { $0.contains("random.sql") }, "\(index.skippedFiles)")
    }

    func testMissingDirectoryIsReportedNotCrashing() {
        let index = QueryMemory.buildIndex(directory: URL(fileURLWithPath: "/tmp/绝对不存在的目录-\(UUID().uuidString)"))
        XCTAssertTrue(index.isEmpty)
        XCTAssertFalse(index.skippedFiles.isEmpty, "目录读不了要说出来")
    }

    /// **索引是纯派生缓存**：同一个目录重建两次结果必须一致（删掉重建不丢信息）。
    func testIndexIsDeterministicAcrossRebuilds() throws {
        let directory = try makeArchiveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let day = Date(timeIntervalSince1970: 1_760_000_000)
        try write([
            makeEntry("SELECT * FROM a WHERE id = 1", at: day, runCount: 2),
            makeEntry("SELECT * FROM b WHERE id = 5", at: day, runCount: 4),
        ], to: directory, fileName: "2026-09-21.sql")

        let first = QueryMemory.buildIndex(directory: directory)
        let second = QueryMemory.buildIndex(directory: directory)
        XCTAssertEqual(first, second)
    }

    // MARK: 补全

    private func index(with memories: [QueryMemory.Memory]) -> QueryMemory.Index {
        QueryMemory.Index(memories: memories, parsedEntryCount: memories.count)
    }

    private func memory(
        _ sql: String,
        runs: Int,
        at timestamp: TimeInterval,
        connections: Set<String> = ["生产库"]
    ) -> QueryMemory.Memory {
        QueryMemory.Memory(
            fingerprint: QueryMemory.coarseFingerprint(sql),
            latestSQL: sql,
            variantCount: 1,
            runCount: runs,
            days: ["2026-09-21"],
            connections: connections,
            lastExecutedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    /// 前缀命中排在前，且**同档按执行次数**。
    func testSuggestionsRankByMatchThenFrequency() {
        let built = index(with: [
            memory("SELECT * FROM orders", runs: 3, at: 1_760_000_000),
            memory("SELECT * FROM customers", runs: 30, at: 1_760_000_000),
            memory("WITH x AS (SELECT * FROM orders) SELECT * FROM x", runs: 99, at: 1_760_000_000),
        ])
        let suggestions = QueryMemory.suggestions(prefix: "SELECT * FROM o", in: built)
        // 两条都会出现：`SELECT * FROM orders` 是**前缀**命中，WITH 那条是**子串**命中。
        // 我第一版期望只有 1 条 —— 是期望写错（子串命中本来就该在候选里，只是排后面）。
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions.first?.sql, "SELECT * FROM orders", "前缀命中要排在子串命中之前")
    }

    func testSubstringMatchIsWeakerThanPrefix() {
        let built = index(with: [
            memory("WITH x AS (SELECT * FROM orders) SELECT * FROM x", runs: 99, at: 1_760_000_000),
            memory("SELECT * FROM orders", runs: 1, at: 1_760_000_000),
        ])
        let suggestions = QueryMemory.suggestions(prefix: "SELECT * FROM orders", in: built)
        XCTAssertEqual(suggestions.first?.sql, "SELECT * FROM orders", "前缀命中即使次数少也排在前面")
    }

    /// **按连接隔离**：生产库的记忆不该流进测试库的补全。
    func testConnectionIsolation() {
        let built = index(with: [
            memory("SELECT * FROM orders", runs: 5, at: 1_760_000_000, connections: ["生产库"]),
            memory("SELECT * FROM staging_only", runs: 5, at: 1_760_000_000, connections: ["测试库"]),
        ])
        let production = QueryMemory.suggestions(prefix: "SELECT", in: built, connection: "生产库")
        XCTAssertEqual(production.map(\.sql), ["SELECT * FROM orders"])

        let all = QueryMemory.suggestions(prefix: "SELECT", in: built)
        XCTAssertEqual(all.count, 2, "不指定连接时给出全部（例如在设置里浏览记忆）")
    }

    /// 排序稳定：同一个前缀问两次，顺序必须一样。
    func testSuggestionOrderIsStable() {
        let built = index(with: [
            memory("SELECT * FROM a", runs: 5, at: 1_760_000_000),
            memory("SELECT * FROM b", runs: 5, at: 1_760_000_000),
            memory("SELECT * FROM c", runs: 5, at: 1_760_000_000),
        ])
        XCTAssertEqual(
            QueryMemory.suggestions(prefix: "SELECT", in: built).map(\.sql),
            QueryMemory.suggestions(prefix: "SELECT", in: built).map(\.sql)
        )
        // 次数相同、时间相同 → 按 SQL 文本兜底排序（不是靠输入顺序）
        XCTAssertEqual(QueryMemory.suggestions(prefix: "SELECT", in: built).map(\.sql),
                       ["SELECT * FROM a", "SELECT * FROM b", "SELECT * FROM c"])
    }

    func testEmptyPrefixGivesNothing() {
        let built = index(with: [memory("SELECT 1", runs: 1, at: 1_760_000_000)])
        XCTAssertTrue(QueryMemory.suggestions(prefix: "   ", in: built).isEmpty)
    }

    func testLimitIsRespected() {
        let built = index(with: (1...9).map { memory("SELECT * FROM t\($0)", runs: 1, at: 1_760_000_000) })
        XCTAssertEqual(QueryMemory.suggestions(prefix: "SELECT", in: built, limit: 3).count, 3)
    }

    /// 端到端：从归档文件建索引 → 给补全（这是这一项真正的用法）。
    func testEndToEndFromArchiveToSuggestion() throws {
        let directory = try makeArchiveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let day = Date(timeIntervalSince1970: 1_760_000_000)
        try write([
            makeEntry("SELECT count(*) FROM orders WHERE status = 'paid'", connection: "生产库", at: day, runCount: 12),
            makeEntry("SELECT count(*) FROM orders WHERE status = 'refunded'", connection: "生产库", at: day, runCount: 1),
            makeEntry("SELECT * FROM customers", connection: "测试库", at: day, runCount: 40),
        ], to: directory, fileName: "2026-09-21.sql")

        let built = QueryMemory.buildIndex(directory: directory)
        let production = QueryMemory.suggestions(prefix: "SELECT count", in: built, connection: "生产库", limit: 5)
        XCTAssertEqual(production.count, 1, "两条 count 语句是同一骨架 → 一条记忆")
        XCTAssertEqual(production.first?.memory.runCount, 13, "次数是两条之和")

        let customer = QueryMemory.suggestions(prefix: "SELECT * FROM customers", in: built, connection: "生产库")
        XCTAssertTrue(customer.isEmpty, "测试库的记忆不该出现在生产库的补全里")
    }
}
