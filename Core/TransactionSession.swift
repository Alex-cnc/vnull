import Foundation

/// 事务模式（FR-EXEC-15）：「自动提交」还是「手工事务」。
public enum TransactionMode: String, Sendable, Equatable, CaseIterable {
    /// 每条语句各自提交（默认）。客户端不发送 BEGIN。
    case autoCommit
    /// 手工事务：第一条语句之前发 BEGIN，之后所有语句在同一事务内，直到提交或回滚。
    case manual

    public var isManual: Bool { self == .manual }
}

/// 事务的当前阶段。
public enum TransactionPhase: Equatable, Sendable {
    /// 没有进行中的事务。
    case idle
    /// 事务进行中，已执行 `statementCount` 条语句。
    case open(statementCount: Int)
    /// 事务内的语句失败 —— PostgreSQL 会把事务标记为失败，之后只接受 ROLLBACK。
    case aborted(reason: String)

    public var isOpen: Bool {
        switch self {
        case .open, .aborted: return true
        case .idle: return false
        }
    }

    public var statementCount: Int {
        if case .open(let count) = self { return count }
        return 0
    }
}

/// 拒绝执行事务操作的原因（**平台中立**：Core 不给文案，界面层映射成本地化文本）。
public enum TransactionRefusal: Equatable, Sendable {
    /// 自动提交模式下没有可提交 / 回滚的事务。
    case notInManualMode
    /// 手工模式，但还没有语句在事务里跑过。
    case nothingToDo
    /// 事务已失败，只能回滚。
    case aborted
    /// 有进行中的事务，不能直接切回自动提交。
    case hasOpenTransaction
}

/// 事务状态机告诉调用方**下一步该发什么命令**。
///
/// 为什么不直接在界面里写 `beginTransaction()`：事务的坑全在**时序**上
/// （第一条语句前才 BEGIN、失败后只能回滚、切连接时未提交事务怎么办），
/// 这些判断放在值类型里能单测，界面只负责照做与显示。
public enum TransactionAction: Equatable, Sendable {
    case begin
    case commit
    case rollback
    /// 无需服务端动作。
    case nothing
    /// 拒绝并给出原因（界面据此提示，且**不发任何命令**）。
    case refuse(TransactionRefusal)
}

/// 一个「连接 + 数据库」上的事务上下文。
///
/// 归属说得清清楚楚：事务属于**连接会话**，不是某个页签 ——
/// 同一个连接下的多个页签共用一条连接，因此也共用同一个事务。
/// 切连接 / 切库时必须显式处理（见 `connectionDidChange()`）。
public struct TransactionSession: Equatable, Sendable {

    public private(set) var mode: TransactionMode
    public private(set) var phase: TransactionPhase

    public init(mode: TransactionMode = .autoCommit, phase: TransactionPhase = .idle) {
        self.mode = mode
        self.phase = phase
    }

    // MARK: - 模式切换

    /// 切换自动提交 / 手工事务。
    ///
    /// 有进行中的事务时**拒绝**切回自动提交：此时要么静默提交（数据事故），
    /// 要么静默丢弃（用户以为已保存）。两种都不该由一次开关点击决定。
    public mutating func setMode(_ newMode: TransactionMode) -> TransactionAction {
        guard newMode != mode else { return .nothing }
        if newMode == .autoCommit, phase.isOpen {
            return .refuse(.hasOpenTransaction)
        }
        mode = newMode
        return .nothing
    }

    // MARK: - 语句执行

    /// 执行一条语句**之前**调用：手工模式下第一条语句前要发 BEGIN。
    public mutating func prepareStatement() -> TransactionAction {
        switch mode {
        case .autoCommit:
            return .nothing
        case .manual:
            switch phase {
            case .idle:
                // 懒开启：没跑语句就不发 BEGIN，日志与连接状态都不被污染。
                phase = .open(statementCount: 1)
                return .begin
            case .open(let count):
                phase = .open(statementCount: count + 1)
                return .nothing
            case .aborted:
                // 失败的事务里继续执行只会再报一次错，明确拒绝更好懂。
                return .refuse(.aborted)
            }
        }
    }

    /// 语句失败 / 被取消后调用：手工事务进入「只能回滚」。
    public mutating func statementFailed(reason: String) {
        guard mode.isManual, phase.isOpen else { return }
        phase = .aborted(reason: reason)
    }

    // MARK: - 提交与回滚

    public mutating func commit() -> TransactionAction {
        guard mode.isManual else { return .refuse(.notInManualMode) }
        switch phase {
        case .open:
            phase = .idle
            return .commit
        case .aborted:
            return .refuse(.aborted)
        case .idle:
            return .refuse(.nothingToDo)
        }
    }

    public mutating func rollback() -> TransactionAction {
        guard mode.isManual else { return .refuse(.notInManualMode) }
        switch phase {
        case .open, .aborted:
            phase = .idle
            return .rollback
        case .idle:
            return .refuse(.nothingToDo)
        }
    }

    /// 服务端命令（BEGIN / COMMIT / ROLLBACK）本身失败：连接断了或事务已被服务端结束。
    ///
    /// PostgreSQL 的 COMMIT 失败（如延迟约束冲突）会把事务**回滚掉**，连接级失败则事务随连接消失 ——
    /// 两种情况下"事务已结束"都是事实，所以状态退回 idle，绝不显示成"已提交"。
    public mutating func serverCommandFailed() {
        phase = .idle
    }

    // MARK: - 连接 / 数据库变化

    /// 连接或数据库变了：进行中的事务必须**回滚**并告知用户。
    ///
    /// 为什么不是自动提交：未提交的事务在新连接上根本不存在，而"替你提交"是数据事故；
    /// 回滚 + 明说是唯一可预期的处置。
    public mutating func connectionDidChange() -> TransactionAction {
        guard phase.isOpen else { return .nothing }
        phase = .idle
        return .rollback
    }
}
