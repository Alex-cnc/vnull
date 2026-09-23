import XCTest
@testable import DoyahCore

/// 服务端游标分页（FR-RES-13 的「取」那一半）。
///
/// 重点在三件事：只能对**单条查询**开游标；`FETCH` 是**顺序**的（不做 OFFSET 重扫）；
/// 失败或提前结束必须**回滚清理**，绝不能把事务提交掉。
final class CursorPagingTests: XCTestCase {

    // MARK: 计划生成

    func testPlanShape() throws {
        let plan = try CursorPaging.plan(query: "SELECT * FROM t", pageSize: 500).get()
        XCTAssertEqual(plan.beginStatement, "BEGIN")
        XCTAssertEqual(plan.commitStatement, "COMMIT")
        XCTAssertEqual(plan.rollbackStatement, "ROLLBACK")
        XCTAssertEqual(plan.declareStatement, "DECLARE \"doyah_export_cursor\" CURSOR FOR SELECT * FROM t")
        XCTAssertEqual(plan.closeStatement, "CLOSE \"doyah_export_cursor\"")
        XCTAssertEqual(plan.fetchStatement(pageSize: 500), "FETCH FORWARD 500 FROM \"doyah_export_cursor\"")
        XCTAssertEqual(plan.pageSize, 500)
    }

    /// 结尾分号可以有一个（编辑器里习惯这么写），多语句必须拒绝。
    func testSingleTrailingSemicolonAllowedButMultipleStatementsRejected() throws {
        XCTAssertNoThrow(try CursorPaging.plan(query: "SELECT 1;").get())
        for bad in ["SELECT 1; DROP TABLE t", "SELECT 1; SELECT 2"] {
            guard case .failure(.notASingleQuery) = CursorPaging.plan(query: bad) else {
                return XCTFail("应当拒绝多语句：\(bad)")
            }
        }
    }

    func testOnlyQueriesCanBeCursored() {
        for bad in ["UPDATE t SET a = 1", "DELETE FROM t", "INSERT INTO t VALUES (1)", "DROP TABLE t"] {
            guard case .failure(.notASingleQuery(let reason)) = CursorPaging.plan(query: bad) else {
                return XCTFail("应当拒绝：\(bad)")
            }
            XCTAssertFalse(reason.isEmpty, "拒绝必须给可读原因")
        }
        // 允许的几种查询形态
        for good in ["SELECT 1", "WITH x AS (SELECT 1) SELECT * FROM x", "TABLE t", "VALUES (1)", "(SELECT 1)"] {
            if case .failure(let error) = CursorPaging.plan(query: good) {
                XCTFail("应当允许 \(good)：\(error)")
            }
        }
    }

    /// 开头的注释不该被当成关键字（否则 `-- 说明\nSELECT …` 会被误判）。
    func testLeadingCommentsAreSkipped() throws {
        let plan = try CursorPaging.plan(query: "-- 导出订单\nSELECT * FROM orders").get()
        XCTAssertTrue(plan.declareStatement.hasSuffix("SELECT * FROM orders"), plan.declareStatement)

        let block = try CursorPaging.plan(query: "/* 说明 */ SELECT 1").get()
        XCTAssertTrue(block.declareStatement.hasSuffix("SELECT 1"), block.declareStatement)
    }

    func testInvalidPageSizeRejected() {
        guard case .failure(.invalidPageSize) = CursorPaging.plan(query: "SELECT 1", pageSize: 0) else {
            return XCTFail("页大小 0 应当被拒绝")
        }
        guard case .failure(.invalidPageSize) = CursorPaging.plan(query: "SELECT 1", pageSize: -5) else {
            return XCTFail("负数页大小应当被拒绝")
        }
    }

    func testCursorNameIsQuotedAgainstOddCharacters() throws {
        let plan = try CursorPaging.plan(query: "SELECT 1", cursorName: "we\"ird").get()
        XCTAssertTrue(plan.declareStatement.contains("\"we\"\"ird\""), plan.declareStatement)
    }

    // MARK: 逐页取数

    /// 记录执行过的语句，并按预置结果返回。
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var statements: [String] = []
        var pages: [[[String?]]] = []

        func execute(_ sql: String) throws -> QueryResult {
            lock.lock()
            statements.append(sql)
            lock.unlock()
            if sql.hasPrefix("FETCH") {
                guard !pages.isEmpty else { return Self.result(rows: []) }
                return Self.result(rows: pages.removeFirst())
            }
            return Self.result(rows: [])
        }

        static func result(rows: [[String?]]) -> QueryResult {
            QueryResult(
                columns: [ColumnMeta(id: 0, name: "id", typeName: "integer")],
                rows: rows,
                affectedRows: nil,
                executionTime: 0,
                isTruncated: false,
                truncationLimit: nil
            )
        }
    }

    private func drain(_ plan: CursorPagingPlan, recorder: Recorder) async throws -> [[String?]] {
        let fetcher = CursorFetcher(plan: plan, execute: { try recorder.execute($0) })
        try await fetcher.open()
        var rows: [[String?]] = []
        while let page = try await fetcher.nextPage() {
            rows.append(contentsOf: page.rows)
        }
        return rows
    }

    /// 2500 行 / 每页 1000 → 三页（1000、1000、500），第四页不再请求。
    func testPagesAreFetchedSequentiallyUntilShortPage() async throws {
        let recorder = Recorder()
        recorder.pages = [
            (0..<1_000).map { ["\($0)"] },
            (1_000..<2_000).map { ["\($0)"] },
            (2_000..<2_500).map { ["\($0)"] },
        ]
        let plan = try CursorPaging.plan(query: "SELECT * FROM t", pageSize: 1_000).get()

        let rows = try await drain(plan, recorder: recorder)

        XCTAssertEqual(rows.count, 2_500)
        XCTAssertEqual(recorder.statements, [
            "BEGIN",
            plan.declareStatement,
            plan.fetchStatement(pageSize: 1_000),
            plan.fetchStatement(pageSize: 1_000),
            plan.fetchStatement(pageSize: 1_000),
            plan.closeStatement,
            "COMMIT",
        ])
    }

    /// **顺序取数**：语句里不得出现 OFFSET（那正是"大表翻页 O(n²)"的来源）。
    func testNoOffsetPagingIsUsed() async throws {
        let recorder = Recorder()
        recorder.pages = [Array(repeating: ["1"], count: 2), []]
        let plan = try CursorPaging.plan(query: "SELECT * FROM t", pageSize: 2).get()
        _ = try await drain(plan, recorder: recorder)
        XCTAssertFalse(recorder.statements.contains { $0.uppercased().contains("OFFSET") },
                       recorder.statements.joined(separator: " / "))
    }

    /// 空结果集：一次 FETCH 就够，仍然要 CLOSE + COMMIT。
    func testEmptyResultStillCleansUp() async throws {
        let recorder = Recorder()
        let plan = try CursorPaging.plan(query: "SELECT * FROM t", pageSize: 100).get()
        let rows = try await drain(plan, recorder: recorder)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(Array(recorder.statements.suffix(2)), [plan.closeStatement, "COMMIT"])
        XCTAssertEqual(recorder.statements.filter { $0.hasPrefix("FETCH") }.count, 1)
    }

    /// **按需取页**：消费者只取一页，数据库就只被 FETCH 一次 ——
    /// 这正是"内存与总行数无关"的前提（流式版本会抢跑，本轮实测过）。
    func testFetcherIsDemandDriven() async throws {
        let recorder = Recorder()
        recorder.pages = [
            (0..<10).map { ["\($0)"] },
            (10..<20).map { ["\($0)"] },
            (20..<30).map { ["\($0)"] },
        ]
        let plan = try CursorPaging.plan(query: "SELECT * FROM t", pageSize: 10).get()

        let fetcher = CursorFetcher(plan: plan, execute: { try recorder.execute($0) })
        try await fetcher.open()
        let first = try await fetcher.nextPage()
        XCTAssertEqual(first?.rows.count, 10)

        XCTAssertEqual(recorder.statements.filter { $0.hasPrefix("FETCH") }.count, 1,
                       "消费者没继续取，就不该再 FETCH：\(recorder.statements)")
    }

    /// 提前结束：`close()` 必须**回滚**而不是提交。
    func testEarlyCloseRollsBackInsteadOfCommitting() async throws {
        let recorder = Recorder()
        recorder.pages = [(0..<10).map { ["\($0)"] }, (10..<20).map { ["\($0)"] }]
        let plan = try CursorPaging.plan(query: "SELECT * FROM t", pageSize: 10).get()

        let fetcher = CursorFetcher(plan: plan, execute: { try recorder.execute($0) })
        try await fetcher.open()
        _ = try await fetcher.nextPage()
        await fetcher.close()
        await fetcher.close()   // 幂等

        XCTAssertTrue(recorder.statements.contains("ROLLBACK"), recorder.statements.joined(separator: " / "))
        XCTAssertFalse(recorder.statements.contains("COMMIT"), "提前结束不该提交：\(recorder.statements)")
        XCTAssertEqual(recorder.statements.filter { $0 == "ROLLBACK" }.count, 1, "close 要幂等")
    }

    /// 取完之后再调 `close()` 不该再发 ROLLBACK（已经提交过了）。
    func testCloseAfterFinishIsNoop() async throws {
        let recorder = Recorder()
        recorder.pages = [(0..<3).map { ["\($0)"] }]
        let plan = try CursorPaging.plan(query: "SELECT * FROM t", pageSize: 10).get()

        let fetcher = CursorFetcher(plan: plan, execute: { try recorder.execute($0) })
        try await fetcher.open()
        while try await fetcher.nextPage() != nil {}
        await fetcher.close()

        XCTAssertTrue(recorder.statements.contains("COMMIT"))
        XCTAssertFalse(recorder.statements.contains("ROLLBACK"))
    }

    /// FETCH 出错：关游标 + **回滚**，错误照原样抛出。
    func testFetchFailureRollsBackAndRethrows() async throws {
        let recorder = Recorder()
        let plan = try CursorPaging.plan(query: "SELECT * FROM t", pageSize: 10).get()

        let fetcher = CursorFetcher(plan: plan, execute: { sql in
            if sql.hasPrefix("FETCH") { throw AppError.queryFailed("模拟取数失败") }
            return try recorder.execute(sql)
        })
        try await fetcher.open()

        do {
            _ = try await fetcher.nextPage()
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue(recorder.statements.contains(plan.closeStatement), recorder.statements.joined(separator: " / "))
            XCTAssertTrue(recorder.statements.contains("ROLLBACK"))
            XCTAssertFalse(recorder.statements.contains("COMMIT"), "失败时绝不能提交")
        }
    }

    /// BEGIN 就失败：不能继续 DECLARE，也不该尝试 COMMIT。
    func testBeginFailureStopsImmediately() async throws {
        let recorder = Recorder()
        let plan = try CursorPaging.plan(query: "SELECT * FROM t").get()

        let fetcher = CursorFetcher(plan: plan, execute: { sql in
            if sql == "BEGIN" { throw AppError.queryFailed("模拟连接问题") }
            return try recorder.execute(sql)
        })

        do {
            try await fetcher.open()
            XCTFail("应当抛错")
        } catch {
            XCTAssertFalse(recorder.statements.contains { $0.hasPrefix("DECLARE") })
            XCTAssertFalse(recorder.statements.contains("COMMIT"))
        }
    }

    /// 每页**绝不超过** pageSize（内存占用与总行数无关的前提）。
    func testPageNeverExceedsPageSize() async throws {
        let recorder = Recorder()
        recorder.pages = [
            (0..<50).map { ["\($0)"] },   // 50 < 100 → 视为最后一页
        ]
        let plan = try CursorPaging.plan(query: "SELECT * FROM t", pageSize: 100).get()

        // 先取完（50 < 100 即视为最后一页，所以只有一页）。
        let rows = try await drain(plan, recorder: recorder)
        XCTAssertEqual(rows.count, 50, "不足一页时就是最后一页，不该再问一次")
        XCTAssertEqual(recorder.statements.filter { $0.hasPrefix("FETCH") }.count, 1)
    }
}
