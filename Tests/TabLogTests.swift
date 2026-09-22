import XCTest
@testable import DoyahCore

/// 下方面板日志追加规则的测试（Problem / Output 共用的那段纯逻辑）。
final class TabLogTests: XCTestCase {

    private func append(
        _ entries: [TabLogEntry],
        _ message: String,
        _ severity: TabLogEntry.Severity = .info,
        limit: Int = 500
    ) -> [TabLogEntry] {
        TabLog.appended(entries, message: message, severity: severity, limit: limit)
    }

    func testAppendsTrimmedMessage() {
        let entries = append([], "  执行完成  ")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].message, "执行完成")
        XCTAssertEqual(entries[0].severity, .info)
    }

    func testSkipsBlankMessages() {
        XCTAssertTrue(append([], "   ").isEmpty)
        XCTAssertTrue(append([], "\n\t").isEmpty)
        XCTAssertTrue(append([], "").isEmpty)
    }

    /// 同一条状态在执行过程中常被反复写入，相邻重复不该刷屏。
    func testSkipsAdjacentDuplicate() {
        var entries = append([], "执行中")
        entries = append(entries, "执行中")
        XCTAssertEqual(entries.count, 1)

        // 中间隔了别的消息，就允许再次出现
        entries = append(entries, "完成")
        entries = append(entries, "执行中")
        XCTAssertEqual(entries.count, 3)
    }

    /// 同文案但严重级别不同（例如由 info 变 error）要各记一条。
    func testSameMessageDifferentSeverityIsKept() {
        var entries = append([], "失败", .info)
        entries = append(entries, "失败", .error)
        XCTAssertEqual(entries.count, 2)
    }

    func testDropsOldestWhenOverLimit() {
        var entries: [TabLogEntry] = []
        for index in 0..<10 {
            entries = append(entries, "第 \(index) 条", limit: 3)
        }
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.message), ["第 7 条", "第 8 条", "第 9 条"])
    }

    func testLimitZeroIsTreatedAsUnlimited() {
        var entries: [TabLogEntry] = []
        for index in 0..<5 {
            entries = append(entries, "第 \(index) 条", limit: 0)
        }
        XCTAssertEqual(entries.count, 5, "limit 传 0 表示不限量，而不是清空")
    }

    func testClearedReturnsEmpty() {
        XCTAssertTrue(TabLog.cleared().isEmpty)
    }

    func testEntriesKeepOrderAndIdentity() {
        var entries: [TabLogEntry] = []
        entries = append(entries, "A")
        entries = append(entries, "B")
        entries = append(entries, "C")
        XCTAssertEqual(entries.map(\.message), ["A", "B", "C"])
        XCTAssertEqual(Set(entries.map(\.id)).count, 3, "每条要有独立 id（列表用）")
    }
}
