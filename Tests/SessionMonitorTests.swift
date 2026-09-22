import XCTest
@testable import DoyahCore

/// FR-SESS-01 ~ FR-SESS-02：会话监控解析。
final class SessionMonitorTests: XCTestCase {

    private func pgResult() -> QueryResult {
        let columns = [
            "pid", "usename", "datname", "client_addr", "application_name",
            "state", "wait_event_type", "wait_event", "backend_start", "query_start", "query"
        ].enumerated().map { ColumnMeta(id: $0.offset, name: $0.element, typeName: "text") }

        let rows: [[String?]] = [
            ["101", "postgres", "appdb", "192.0.2.20", "psql", "active", "Lock", "transactionid",
             "2026-09-20 20:00:00.000000+00", "2026-09-20 21:59:00.000000+00", "UPDATE t SET a = 1"],
            ["102", "app", "appdb", nil, "myapp", "idle", nil, nil,
             "2026-09-20 20:01:00.000000+00", "2026-09-20 21:00:00.000000+00", "SELECT 1"],
            [nil, "ghost", "appdb", nil, nil, "idle", nil, nil, nil, nil, nil]
        ]

        return QueryResult(columns: columns, rows: rows)
    }

    func testMapsPostgresActivityColumns() {
        let sessions = SessionMonitor.sessions(from: pgResult())

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].pid, 101)
        XCTAssertEqual(sessions[0].user, "postgres")
        XCTAssertEqual(sessions[0].database, "appdb")
        XCTAssertEqual(sessions[0].clientAddress, "192.0.2.20")
        XCTAssertEqual(sessions[0].state, "active")
        XCTAssertEqual(sessions[0].waitEvent, "transactionid")
        XCTAssertEqual(sessions[1].pid, 102)
    }

    func testRowsWithoutUsablePidAreSkipped() {
        let sessions = SessionMonitor.sessions(from: pgResult())
        XCTAssertFalse(sessions.contains { $0.user == "ghost" })
    }

    func testMapsMySqlProcesslistColumns() {
        let columns = ["Id", "User", "Host", "db", "Command", "Time", "State", "Info"]
            .enumerated().map { ColumnMeta(id: $0.offset, name: $0.element, typeName: "text") }
        let rows: [[String?]] = [
            ["77", "root", "localhost:5000", "appdb", "Query", "3", "executing", "SELECT * FROM t"]
        ]
        let result = QueryResult(columns: columns, rows: rows)

        let sessions = SessionMonitor.sessions(from: result)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].pid, 77)
        XCTAssertEqual(sessions[0].database, "appdb")
        XCTAssertEqual(sessions[0].query, "SELECT * FROM t")
        XCTAssertTrue(sessions[0].isActive)
    }

    func testStateHelpers() {
        let waiting = ServerSession(pid: 1, state: "active", waitEventType: "Lock")
        let running = ServerSession(pid: 2, state: "active")
        let idle = ServerSession(pid: 3, state: "idle")
        let clientWait = ServerSession(pid: 4, state: "active", waitEventType: "Client")

        XCTAssertTrue(waiting.isWaiting)
        XCTAssertTrue(running.isActive)
        XCTAssertFalse(running.isWaiting)
        XCTAssertTrue(idle.isIdle)
        XCTAssertFalse(clientWait.isWaiting, "Client 等待属于正常等客户端收数据，不算阻塞")
    }

    func testSortPutsWaitingAndActiveFirst() {
        let sessions = [
            ServerSession(pid: 30, state: "idle"),
            ServerSession(pid: 20, state: "active"),
            ServerSession(pid: 10, state: "active", waitEventType: "Lock")
        ]

        XCTAssertEqual(SessionMonitor.sorted(sessions).map(\.pid), [10, 20, 30])
    }

    func testSummarizeCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual(SessionMonitor.summarize("SELECT\n   1\n FROM t"), "SELECT 1 FROM t")
        XCTAssertEqual(SessionMonitor.summarize(nil), "")

        let long = String(repeating: "x", count: 200)
        let summary = SessionMonitor.summarize(long, limit: 10)
        XCTAssertEqual(summary, "xxxxxxxxxx…")
    }

    func testElapsedSecondsUsesTimestampDifference() {
        let start = "2026-09-20 22:00:00.000000+00"
        guard let parsed = SessionMonitor.parseTimestamp(start) else {
            return XCTFail("时间戳应当可以解析")
        }

        let now = parsed.addingTimeInterval(90)
        XCTAssertEqual(SessionMonitor.elapsedSeconds(since: start, now: now) ?? -1, 90, accuracy: 0.001)
    }

    func testParseTimestampAcceptsSeveralShapes() {
        XCTAssertNotNil(SessionMonitor.parseTimestamp("2026-09-20 22:00:00.123+00"))
        XCTAssertNotNil(SessionMonitor.parseTimestamp("2026-09-20 22:00:00"))
        XCTAssertNotNil(SessionMonitor.parseTimestamp("2026-09-20T22:00:00"))
        XCTAssertNil(SessionMonitor.parseTimestamp("不是时间"))
        XCTAssertNil(SessionMonitor.parseTimestamp(nil))
    }

    func testSessionElapsedUsesQueryStart() {
        let session = ServerSession(pid: 5, queryStart: "2026-09-20 22:00:00.000000+00")
        guard let parsed = SessionMonitor.parseTimestamp(session.queryStart) else {
            return XCTFail("时间戳应当可以解析")
        }
        XCTAssertEqual(session.elapsedSeconds(now: parsed.addingTimeInterval(12)) ?? -1, 12, accuracy: 0.001)
        XCTAssertEqual(ServerSession(pid: 6).elapsedSeconds() == nil, true)
    }

    func testPostgresDialectProvidesSessionStatements() {
        let dialect = PostgresDialect()

        XCTAssertNotNil(dialect.serverActivityQuery())
        XCTAssertTrue(dialect.serverActivityQuery()?.contains("pg_stat_activity") == true)
        XCTAssertEqual(dialect.cancelSessionStatement(pid: 42), "SELECT pg_cancel_backend(42)")
        XCTAssertEqual(dialect.terminateSessionStatement(pid: 42), "SELECT pg_terminate_backend(42)")
    }

    func testGBaseDialectUsesProcessListAndKill() {
        let dialect = GBaseDialect()

        XCTAssertEqual(dialect.serverActivityQuery(), "SHOW PROCESSLIST")
        XCTAssertEqual(dialect.cancelSessionStatement(pid: 7), "KILL QUERY 7")
        XCTAssertEqual(dialect.terminateSessionStatement(pid: 7), "KILL 7")
    }
}
