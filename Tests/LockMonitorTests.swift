import XCTest
@testable import DoyahCore

/// FR-DIAG-05：锁等待与阻塞链解析。
final class LockMonitorTests: XCTestCase {

    private let columnNames = [
        "pid", "usename", "datname", "state", "wait_event_type", "wait_event",
        "locktype", "mode", "granted", "relation", "blocking_pids", "query", "waiting_seconds"
    ]

    private func result(_ rows: [[String?]]) -> QueryResult {
        let columns = columnNames.enumerated().map { ColumnMeta(id: $0.offset, name: $0.element, typeName: "text") }
        return QueryResult(columns: columns, rows: rows)
    }

    private func row(pid: String?, blockers: String?, granted: String? = "f", seconds: String? = "12") -> [String?] {
        ["pid", "usename", "datname", "state", "wait_event_type", "wait_event", "locktype", "mode"]
            .isEmpty ? [] : [
                pid, "alice", "appdb", "active", "Lock", "transactionid",
                "transactionid", "ExclusiveLock", granted, "public.users", blockers, "UPDATE t SET a = 1", seconds
            ]
    }

    func testParsesLockWaitRow() {
        let waits = LockMonitor.waits(from: result([row(pid: "200", blockers: "101")]))
        XCTAssertEqual(waits.count, 1)
        let wait = waits[0]
        XCTAssertEqual(wait.pid, 200)
        XCTAssertEqual(wait.user, "alice")
        XCTAssertEqual(wait.database, "appdb")
        XCTAssertEqual(wait.lockType, "transactionid")
        XCTAssertEqual(wait.mode, "ExclusiveLock")
        XCTAssertFalse(wait.granted)
        XCTAssertEqual(wait.relation, "public.users")
        XCTAssertEqual(wait.blockingPids, [101])
        XCTAssertEqual(wait.waitingSeconds, 12)
        XCTAssertTrue(wait.isBlocked)
    }

    func testEmptyResultProducesNoWaits() {
        XCTAssertTrue(LockMonitor.waits(from: result([])).isEmpty)
    }

    func testRowsWithoutPidAreSkipped() {
        let waits = LockMonitor.waits(from: result([row(pid: nil, blockers: "101"), row(pid: "202", blockers: "")]))
        XCTAssertEqual(waits.map(\.pid), [202])
    }

    func testBlockingPidsParsesCommaList() {
        let waits = LockMonitor.waits(from: result([row(pid: "200", blockers: "101,102")]))
        XCTAssertEqual(waits[0].blockingPids, [101, 102])
    }

    func testBlockingPidsParsesArrayLiteral() {
        // 直接取 int[] 时驱动会给成 `{101,102}`，同样要能解析。
        let waits = LockMonitor.waits(from: result([row(pid: "200", blockers: "{101, 102}")]))
        XCTAssertEqual(waits[0].blockingPids, [101, 102])
    }

    func testGrantedFallsBackToBlockersWhenMissing() {
        let blocked = LockMonitor.waits(from: result([row(pid: "200", blockers: "101", granted: nil)]))
        XCTAssertFalse(blocked[0].granted)
        let free = LockMonitor.waits(from: result([row(pid: "201", blockers: "", granted: nil)]))
        XCTAssertTrue(free[0].granted)
    }

    func testBlockingChainFollowsBlockers() {
        let waits = LockMonitor.waits(from: result([
            row(pid: "200", blockers: "101"),
            row(pid: "101", blockers: "100"),
            row(pid: "100", blockers: "")
        ]))
        XCTAssertEqual(LockMonitor.blockingChain(from: 200, in: waits), [200, 101, 100])
        XCTAssertEqual(LockMonitor.blockingChain(from: 100, in: waits), [100])
    }

    func testBlockingChainStopsOnCycle() {
        // 脏数据造出环时不能死循环。
        let waits = LockMonitor.waits(from: result([
            row(pid: "1", blockers: "2"),
            row(pid: "2", blockers: "1")
        ]))
        XCTAssertEqual(LockMonitor.blockingChain(from: 1, in: waits), [1, 2])
    }

    func testBlockedCountAndSummary() {
        let waits = LockMonitor.waits(from: result([
            row(pid: "200", blockers: "101"),
            row(pid: "101", blockers: ""),
            row(pid: "202", blockers: "101,103")
        ]))
        XCTAssertEqual(LockMonitor.blockedCount(in: waits), 2)
        let lines = LockMonitor.summaryLines(for: waits)
        XCTAssertEqual(lines.first, "锁等待记录 3 条，被阻塞会话 2 个")
        XCTAssertTrue(lines.contains("最长等待 12 秒"))
        XCTAssertEqual(LockMonitor.summaryLines(for: []), ["当前无锁等待"])
    }
}
