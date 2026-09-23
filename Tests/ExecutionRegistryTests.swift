import XCTest
@testable import DoyahCore

/// 取消的回归测试（R-29 / R-30）。
///
/// 缺陷原貌（2026-09-23 评审确认）：
///   · **R-29** —— 生产端是非结构化 Task 且没有 `onTermination`，多语句脚本取消后
///     剩余语句照旧执行；
///   · **R-30** —— 服务实例按「连接 + 库」缓存并跨页签共享，`cancel()` 直接按后端 PID
///     发 `pg_cancel_backend`，**取消 A 页签会杀掉同库 B 页签正在跑的语句**；
///     拿不到 PID 时还静默 `return`（界面显示"已取消"而服务端仍在跑）。
///
/// `ExecutionRegistry` 就是这两条修复的核心状态机（不依赖 I/O，所以能这样钉住）。
final class ExecutionRegistryTests: XCTestCase {

    func testActiveRunIsCancelledAndFlagged() {
        var registry = ExecutionRegistry()
        let run = ExecutionHandle()

        registry.enqueue(run)
        XCTAssertTrue(registry.begin(run))
        XCTAssertEqual(registry.activeHandle, run)

        XCTAssertEqual(registry.requestCancel(run), .cancelActive)
        XCTAssertTrue(registry.isCancelled(run), "取消后生产端每条语句前都要能看到这个标记")
    }

    /// **排队期间按停止 → 一条语句都不该执行**。
    ///
    /// 这是 R-29 里最容易被忽略的一半：停止按钮可能是在"还没轮到它"时按下的。
    func testCancelledWhileQueuedNeverStarts() {
        var registry = ExecutionRegistry()
        let run = ExecutionHandle()

        registry.enqueue(run)
        XCTAssertEqual(registry.requestCancel(run), .markOnly)

        XCTAssertFalse(registry.begin(run), "排队时被取消的执行，begin 必须拒绝")
    }

    /// **定向取消**：同一条连接上，取消 B 页签不得动到正在跑的 A 页签（R-30 核心）。
    func testCancellingOneRunDoesNotDisturbAnotherOnSameConnection() {
        var registry = ExecutionRegistry()
        let tabA = ExecutionHandle()
        let tabB = ExecutionHandle()

        registry.enqueue(tabA)
        registry.enqueue(tabB)
        XCTAssertTrue(registry.begin(tabA))

        // B 还在排队：只能标记，**不能**要求发服务端取消（那会杀掉 A 的语句）
        XCTAssertEqual(registry.requestCancel(tabB), .markOnly)
        XCTAssertEqual(registry.activeHandle, tabA, "A 仍然是这条连接上的活跃执行")
        XCTAssertFalse(registry.isCancelled(tabA), "取消 B 不能把 A 标记成已取消")
        XCTAssertFalse(registry.begin(tabB), "B 被取消后不再开始")
    }

    func testCancelAfterFinishIsNoOp() {
        var registry = ExecutionRegistry()
        let run = ExecutionHandle()

        registry.enqueue(run)
        XCTAssertTrue(registry.begin(run))
        registry.finish(run)

        XCTAssertEqual(registry.requestCancel(run), .alreadyFinished)
        XCTAssertNil(registry.activeHandle)
    }

    /// 结束后不留残迹：标记要清掉，句柄不能越攒越多。
    func testFinishClearsStateForReuse() {
        var registry = ExecutionRegistry()
        let runs = (0..<50).map { _ in ExecutionHandle() }

        for run in runs {
            registry.enqueue(run)
            XCTAssertTrue(registry.begin(run))
            _ = registry.requestCancel(run)
            registry.finish(run)
        }

        for run in runs {
            XCTAssertFalse(registry.isCancelled(run))
            XCTAssertEqual(registry.requestCancel(run), .alreadyFinished)
        }
        XCTAssertNil(registry.activeHandle)
    }

    /// 取消结果必须能区分「真发了取消」与「其实没停」—— 这是 R-30 静默返回的对立面。
    func testOutcomeDistinguishesDeliveryFromFailure() {
        XCTAssertTrue(CancelOutcome.cancelled.didCancel)
        XCTAssertTrue(CancelOutcome.cancelledBeforeStart.didCancel)
        XCTAssertFalse(CancelOutcome.notActive.didCancel)
        XCTAssertFalse(CancelOutcome.failed(reason: "未取得后端 PID").didCancel,
                       "下发失败时上层要如实告诉用户查询可能还在跑")
    }
}
