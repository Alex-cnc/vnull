import Foundation

/// 一次执行的句柄（R-29 / R-30）。
///
/// 为什么取消要带句柄：同一个连接上会依次跑不同页签的语句（服务实例按「连接 + 库」
/// 缓存并跨页签共享），所以「取消」必须能指名道姓 —— 否则取消 A 页签的查询会把
/// 同库 B 页签正在跑的语句一起干掉（实测：`pg_cancel_backend` 是按后端进程发的，
/// 一个后端上同时只跑一条语句）。
public struct ExecutionHandle: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// 取消请求的裁决：告诉调用方「到底取消了什么」。
public enum CancelDecision: Equatable, Sendable {
    /// 这个句柄正跑在该连接上 → 应该真的向服务端发取消。
    case cancelActive
    /// 还没开始跑（排队中）→ 只标记；它一条语句都不会执行，**不要碰别人的语句**。
    case markOnly
    /// 已经结束了（或从未登记）→ 无事可做。
    case alreadyFinished
}

/// 取消的结果：**必须能说出来**。
///
/// 原来 `cancel()` 是 `guard let pid = backendPID else { return }` —— 拿不到 PID 就静默返回，
/// 用户界面显示「已取消」而服务端仍在跑（R-30：这比报错更糟，因为它让人以为停住了）。
public enum CancelOutcome: Equatable, Sendable {
    /// 已向服务端发出取消请求。
    case cancelled
    /// 该执行还没开始，已被标记；不会再执行。
    case cancelledBeforeStart
    /// 该句柄不在执行中（已结束，或该连接上跑的不是它）。
    case notActive
    /// 发不出去（拿不到后端 PID、取消连接建不起来…）—— 上层要把原因显示出来。
    case failed(reason: String)

    public var didCancel: Bool {
        switch self {
        case .cancelled, .cancelledBeforeStart: return true
        case .notActive, .failed: return false
        }
    }
}

/// 单连接上的执行注册表：**「谁在跑、谁被取消过」的唯一事实源**。
///
/// 它是 R-29 / R-30 的修复核心，故意做成不依赖 I/O 的纯状态机（因此可以单测）：
///
///   · **定向取消**：只有 `active` 等于该句柄时才允许真的发服务端取消；
///     排队中的句柄只做标记（`markOnly`），别人的语句一律不碰。
///   · **取消要先于开始**：排队期间被取消的句柄，`begin` 会拒绝执行 ——
///     用户按了停止，就不该再往数据库打语句。
///   · **消费者走开也算取消**：`AsyncThrowingStream` 的 `onTermination` 会走同一条路径。
public struct ExecutionRegistry: Sendable {
    private var active: ExecutionHandle?
    private var queued: Set<ExecutionHandle> = []
    private var cancelled: Set<ExecutionHandle> = []

    public init() {}

    /// 登记一次即将开始的执行（流刚被创建、还没真正跑）。
    public mutating func enqueue(_ handle: ExecutionHandle) {
        if active != handle, !cancelled.contains(handle) {
            queued.insert(handle)
        }
    }

    /// 真正开始执行。返回 `false` 表示**已被取消，不要执行**。
    public mutating func begin(_ handle: ExecutionHandle) -> Bool {
        queued.remove(handle)
        if cancelled.remove(handle) != nil {
            return false
        }
        active = handle
        return true
    }

    /// 执行结束（正常结束、抛错、取消都走这里）。
    public mutating func finish(_ handle: ExecutionHandle) {
        if active == handle {
            active = nil
        }
        queued.remove(handle)
        cancelled.remove(handle)
    }

    public func isCancelled(_ handle: ExecutionHandle) -> Bool {
        cancelled.contains(handle)
    }

    /// 请求取消某个句柄，并告知调用方该怎么处理。
    public mutating func requestCancel(_ handle: ExecutionHandle) -> CancelDecision {
        if active == handle {
            cancelled.insert(handle)
            return .cancelActive
        }
        if queued.contains(handle) {
            cancelled.insert(handle)
            return .markOnly
        }
        return .alreadyFinished
    }

    /// 当前活跃句柄（诊断与测试用）。
    public var activeHandle: ExecutionHandle? { active }
}

/// 执行注册表的**线程安全容器**。
///
/// 为什么不是直接把它做成 actor：`execute(_:options:handle:)` 是 `nonisolated`
/// （协议要求，流一被创建就要能登记句柄），而 actor 隔离的方法在 actor 忙时排不上队 ——
/// 排队期间的取消必须立即被记住，否则"按了停止、它还在排队、轮到时照旧执行"。
/// 用锁保护一个纯状态机，读写的粒度小、也没有跨 actor 的等待。
public final class ExecutionRegistryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var registry = ExecutionRegistry()

    public init() {}

    @discardableResult
    public func withLock<T>(_ body: (inout ExecutionRegistry) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&registry)
    }
}
