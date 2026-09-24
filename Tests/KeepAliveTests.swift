import XCTest
@testable import DoyahCore

/// 连接保活心跳（FR-CONN-20）。
///
/// 需求只要求"间隔可配置、可关闭"，但落地时的三个坑都在这里钉住：
/// 空闲判据以**真实活动**为准、心跳本身要刷新活动时间、失败只记录不打断。
final class KeepAliveTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }

    // MARK: 策略

    func testDisabledPolicyNeverPings() {
        let policy = KeepAlivePolicy.disabled
        XCTAssertFalse(KeepAliveScheduler.shouldPing(lastActivity: ago(9999), now: now, policy: policy))
    }

    /// 间隔边界：**恰好到点就该发**（否则"60 秒心跳"实际要等到 61 秒）。
    func testIntervalBoundaryIsInclusive() {
        let policy = KeepAlivePolicy(intervalSeconds: 60)
        XCTAssertFalse(KeepAliveScheduler.shouldPing(lastActivity: ago(59.9), now: now, policy: policy))
        XCTAssertTrue(KeepAliveScheduler.shouldPing(lastActivity: ago(60), now: now, policy: policy))
    }

    /// 间隔有下限：再密就不是保活而是刷屏。
    func testIntervalHasFloor() {
        XCTAssertEqual(KeepAlivePolicy(intervalSeconds: 1).intervalSeconds, 5)
        XCTAssertEqual(KeepAlivePolicy(intervalSeconds: 120).intervalSeconds, 120, "可配置的间隔要原样保留")
    }

    /// 下限是**一个**常量：界面（设置面板的 Stepper）与策略都读它，
    /// 不允许界面再写一个字面量 5 —— 否则迟早出现"界面允许 3 秒、策略按 5 秒跑"。
    func testMinimumIntervalIsTheSameConstantUsedForClamping() {
        XCTAssertEqual(KeepAlivePolicy.minimumIntervalSeconds, 5)
        XCTAssertEqual(KeepAlivePolicy(intervalSeconds: 0).intervalSeconds, KeepAlivePolicy.minimumIntervalSeconds)
        XCTAssertEqual(KeepAlivePolicy(intervalSeconds: -100).intervalSeconds, KeepAlivePolicy.minimumIntervalSeconds)
    }

    func testNextPingDateAndCountdown() {
        let policy = KeepAlivePolicy(intervalSeconds: 60)
        let last = ago(20)
        XCTAssertEqual(KeepAliveScheduler.nextPingDate(lastActivity: last, policy: policy).timeIntervalSince(now), 40, accuracy: 0.001)
        XCTAssertEqual(KeepAliveScheduler.secondsUntilNextPing(lastActivity: last, now: now, policy: policy), 40, accuracy: 0.001)
        // 已经超时：倒计时为负（界面据此显示"该发了"）
        XCTAssertLessThan(KeepAliveScheduler.secondsUntilNextPing(lastActivity: ago(90), now: now, policy: policy), 0)
    }

    /// 心跳语句必须**无副作用**（不能是 `SELECT now()` 之外的写操作）。
    func testHeartbeatStatementIsHarmless() {
        for type in [DatabaseType.postgresql, .gbase8a] {
            let sql = KeepAlivePolicy.statement(for: type)
            XCTAssertTrue(sql.uppercased().hasPrefix("SELECT"), sql)
            for forbidden in ["INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "TRUNCATE"] {
                XCTAssertFalse(sql.uppercased().contains(forbidden), "\(type) 的心跳语句不该含 \(forbidden)：\(sql)")
            }
        }
    }

    // MARK: 记录

    func testRecordAggregatesAndKeepsLastFailure() {
        var record = KeepAliveRecord()
        XCTAssertEqual(record.summary, "尚未发送心跳")
        XCTAssertTrue(record.isHealthy, "还没发过心跳不算不健康（没有证据）")
        record.record(success: true, at: now)
        XCTAssertTrue(record.isHealthy)
        XCTAssertEqual(record.summary, "心跳成功 1 次")

        record.record(success: false, at: now, failure: "连接已关闭")
        XCTAssertEqual(record.failures, 1)
        XCTAssertEqual(record.successes, 1, "失败不该清空成功计数（曾经通过也是信息）")
        XCTAssertFalse(record.isHealthy)
        XCTAssertTrue(record.summary.contains("连接已关闭"), record.summary)

        record.record(success: true, at: now)
        XCTAssertNil(record.lastFailure, "成功之后最近失败原因要清掉（否则状态栏一直挂着旧错）")
        XCTAssertTrue(record.isHealthy)
    }

    func testRecordTotalCountsBothOutcomes() {
        var record = KeepAliveRecord()
        record.record(success: true, at: now)
        record.record(success: true, at: now)
        record.record(success: false, at: now, failure: "x")
        XCTAssertEqual(record.total, 3)
    }
}
