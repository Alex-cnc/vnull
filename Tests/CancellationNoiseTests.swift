import XCTest
@testable import DoyahCore

/// 「取消不是故障」（FR-CONN-13 / FR-META-09 的启动噪声）。
///
/// 这条判据是**实测逼出来的**：启动时 `.task(id:)` 被取消 → `loadDatabases` 把
/// `queryFailed("查询没有返回结果集")` 当成真故障写进 `databaseError`，
/// 界面上就是「SQL 执行失败」，要点一下刷新才消失。
final class CancellationNoiseTests: XCTestCase {

    func testCancelledTaskIsNoiseEvenWithARealLookingError() {
        XCTAssertTrue(CancellationNoise.isNoise(CancellationError(), taskIsCancelled: false))
        // 关键那一档：流提前结束时调用方合成的是 AppError.queryFailed —— 只要任务确实被取消，就是噪声。
        XCTAssertTrue(CancellationNoise.isNoise(CancellationError(), taskIsCancelled: true))
    }

    func testOtherErrorsAreNotNoise() {
        struct Boom: Error {}
        XCTAssertFalse(CancellationNoise.isNoise(Boom(), taskIsCancelled: false))
        XCTAssertFalse(CancellationNoise.isNoise(nil, taskIsCancelled: false))
    }

    /// 任务被取消时，**无论**抓到的是什么（甚至 nil）都算噪声 —— 取消后的错误不可信。
    func testWhenCancelledEverythingIsNoise() {
        struct Boom: Error {}
        XCTAssertTrue(CancellationNoise.isNoise(Boom(), taskIsCancelled: true))
        XCTAssertTrue(CancellationNoise.isNoise(nil, taskIsCancelled: true))
    }
}
