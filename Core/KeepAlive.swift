import Foundation

/// 连接保活心跳（FR-CONN-20）：空闲连接按间隔发一条轻量查询，避免被防火墙 / 中间件掐断。
///
/// 需求点名的验收只有两条：**间隔可配置、可关闭** —— 听起来简单，但落地时有三个坑，
/// 这里逐个定死：
/// 1. **"空闲"以最后一次真实活动为准**，不是"距上次心跳"。否则一条正在被频繁使用的连接
///    照样会被我们插进心跳查询（既没用，又可能干扰正在跑的事务）。
/// 2. **心跳本身也算活动**（成功之后要刷新活动时间），否则它会每隔几秒连发。
/// 3. **心跳失败只记录，不打断连接**：掐断可能发生在任何一刻，工具该做的是**如实报告**
///    "这条连接已经不通了"，而不是在用户没发查询的时候自己弹一堆错误。
public enum KeepAlive {}

/// 保活策略：间隔可配置、可关闭（需求原文的两条验收）。
public struct KeepAlivePolicy: Equatable, Sendable {
    /// 是否开启（关掉后完全不起作用 —— 不偷偷跑）。
    public var isEnabled: Bool
    /// 空闲多久之后发一次心跳（秒）。下限 5 秒：再密就不是保活、而是刷屏了。
    public var intervalSeconds: Int

    /// 间隔下限（秒）。放成公开常量是因为**界面 / 偏好读取 / 策略**三处都要用同一个下限 ——
    /// 界面里再写一个字面量 5，迟早出现"界面允许 3 秒、策略却按 5 秒跑"的错位。
    public static let minimumIntervalSeconds = 5

    public init(isEnabled: Bool = true, intervalSeconds: Int = 60) {
        self.isEnabled = isEnabled
        self.intervalSeconds = max(Self.minimumIntervalSeconds, intervalSeconds)
    }

    public static let `default` = KeepAlivePolicy()
    public static let disabled = KeepAlivePolicy(isEnabled: false)

    /// 心跳语句：越轻越好，**不做任何有副作用的事**。
    public static func statement(for dialect: DatabaseType) -> String {
        switch dialect {
        case .mysql, .gbase8a: return "SELECT 1"
        case .postgresql: return "SELECT 1"
        }
    }
}

/// 该不该发心跳（纯函数，可脱离定时器与数据库单测）。
public enum KeepAliveScheduler {

    /// 距离上次活动是否已经够久。
    public static func shouldPing(
        lastActivity: Date,
        now: Date,
        policy: KeepAlivePolicy
    ) -> Bool {
        guard policy.isEnabled else { return false }
        return now.timeIntervalSince(lastActivity) >= Double(policy.intervalSeconds)
    }

    /// 下一次该发心跳的时刻（界面倒计时 / 定时器排期用）。
    public static func nextPingDate(lastActivity: Date, policy: KeepAlivePolicy) -> Date {
        lastActivity.addingTimeInterval(Double(policy.intervalSeconds))
    }

    /// 距下次心跳还有多少秒（可为负：已经该发了）。
    public static func secondsUntilNextPing(
        lastActivity: Date,
        now: Date,
        policy: KeepAlivePolicy
    ) -> Double {
        nextPingDate(lastActivity: lastActivity, policy: policy).timeIntervalSince(now)
    }
}

/// 心跳记录（成功 / 失败各计一次；失败原因**只留最近一条**，免得日志被刷爆）。
public struct KeepAliveRecord: Equatable, Sendable {
    public var successes: Int
    public var failures: Int
    public var lastPingAt: Date?
    public var lastFailure: String?

    public init(successes: Int = 0, failures: Int = 0, lastPingAt: Date? = nil, lastFailure: String? = nil) {
        self.successes = successes
        self.failures = failures
        self.lastPingAt = lastPingAt
        self.lastFailure = lastFailure
    }

    public var total: Int { successes + failures }

    /// 当前是否健康：**看最近一次结果**，而不是"历史上从未失败过"。
    ///
    /// 为什么：一次偶发失败（网络抖一下）之后连接又通了，若健康态显示成永久"不健康"，
    /// 用户会一直以为连接坏了 —— 那是把历史当成现状。计数仍保留全部历史（`failures`）。
    /// 还没发过心跳时不算不健康（没有任何证据）。
    public var isHealthy: Bool { lastFailure == nil }

    /// 记一次结果。**失败不清空成功计数**（"曾经通过"也是有价值的信息）。
    public mutating func record(success: Bool, at date: Date, failure: String? = nil) {
        lastPingAt = date
        if success {
            successes += 1
            lastFailure = nil
        } else {
            failures += 1
            lastFailure = failure
        }
    }

    /// 一句话状态（界面 / CLI 共用）。
    public var summary: String {
        if total == 0 { return "尚未发送心跳" }
        if isHealthy { return "心跳成功 \(successes) 次" }
        return "心跳成功 \(successes) 次、失败 \(failures) 次（最近：\(lastFailure ?? "未知原因")）"
    }
}
