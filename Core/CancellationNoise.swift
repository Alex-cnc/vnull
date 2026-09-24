import Foundation

/// 「这次失败是不是**任务被取消**造成的噪声」——决定要不要把它报给用户。
///
/// 为什么需要这条判据：SwiftUI 的 `.task(id:)` 在 **id 变化 / 视图被重建 / 视图消失**时都会
/// **取消**上一个任务；取消发生在 `await` 点上时，会以两种面貌出现：
///   ① 抛 `CancellationError`；
///   ② 流的迭代**提前结束**（AsyncThrowingStream 被 finish 掉），调用方看到的却是"什么都没拿到"。
/// 后者尤其坑：`runSingleQuery` 会把"没拿到结果集"翻译成 `AppError.queryFailed("查询没有返回结果集")`，
/// 于是**一次正常的取消**被显示成「SQL 执行失败：查询没有返回结果集」——
/// 实测（App 内探针）：启动时 `loadDatabases` 的 catch 就是 `取消=true / queryFailed("查询没有返回结果集")`，
/// 界面上那条错误要等用户手动刷新才会消失。
///
/// 结论：取消是**控制流**，不是故障。所有"在 `.task` 里跑、失败后写错误状态"的地方都要先过这一道。
public enum CancellationNoise {

    /// - Parameters:
    ///   - error: 捕获到的错误（可为 nil，例如流提前结束时调用方自己合成的错误）
    ///   - taskIsCancelled: 捕获时的 `Task.isCancelled`
    public static func isNoise(_ error: Error?, taskIsCancelled: Bool) -> Bool {
        if taskIsCancelled { return true }
        if error is CancellationError { return true }
        return false
    }
}
