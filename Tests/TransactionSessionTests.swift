import XCTest
@testable import DoyahCore

/// 事务状态机（FR-EXEC-15）：懒开启、失败后只能回滚、切连接必回滚且不静默提交。
final class TransactionSessionTests: XCTestCase {

    // MARK: 自动提交

    func testAutoCommitSendsNoTransactionCommands() {
        var session = TransactionSession()
        XCTAssertEqual(session.prepareStatement(), .nothing)
        XCTAssertEqual(session.prepareStatement(), .nothing)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.commit(), .refuse(.notInManualMode))
        XCTAssertEqual(session.rollback(), .refuse(.notInManualMode))
    }

    // MARK: 手工事务：懒开启

    /// 第一条语句前才发 BEGIN；没跑语句就不开事务（日志与连接状态都不被污染）。
    func testManualModeBeginsLazilyOnFirstStatement() {
        var session = TransactionSession()
        XCTAssertEqual(session.setMode(.manual), .nothing)
        XCTAssertEqual(session.phase, .idle, "切到手工模式本身不该开启事务")

        XCTAssertEqual(session.prepareStatement(), .begin)
        XCTAssertEqual(session.phase, .open(statementCount: 1))

        // 后续语句不再重复 BEGIN，只累计条数。
        XCTAssertEqual(session.prepareStatement(), .nothing)
        XCTAssertEqual(session.phase, .open(statementCount: 2))
    }

    func testCommitClosesTransactionAndResetsCount() {
        var session = TransactionSession(mode: .manual)
        _ = session.prepareStatement()
        _ = session.prepareStatement()

        XCTAssertEqual(session.commit(), .commit)
        XCTAssertEqual(session.phase, .idle)

        // 提交之后又是一条新事务：下一条语句重新 BEGIN。
        XCTAssertEqual(session.prepareStatement(), .begin)
        XCTAssertEqual(session.phase, .open(statementCount: 1))
    }

    func testCommitWithoutStatementsIsRefused() {
        var session = TransactionSession(mode: .manual)
        XCTAssertEqual(session.commit(), .refuse(.nothingToDo))
        XCTAssertEqual(session.rollback(), .refuse(.nothingToDo))
    }

    // MARK: 失败与取消

    /// 事务内语句失败后：只能回滚；继续执行会被明确拒绝（而不是再报一次服务端错误）。
    func testFailedStatementAbortsTransaction() {
        var session = TransactionSession(mode: .manual)
        _ = session.prepareStatement()
        session.statementFailed(reason: "duplicate key")

        XCTAssertEqual(session.phase, .aborted(reason: "duplicate key"))
        XCTAssertEqual(session.prepareStatement(), .refuse(.aborted))
        XCTAssertEqual(session.commit(), .refuse(.aborted), "失败的事务不能提交")

        XCTAssertEqual(session.rollback(), .rollback)
        XCTAssertEqual(session.phase, .idle)
        // 回滚后恢复可用。
        XCTAssertEqual(session.prepareStatement(), .begin)
    }

    /// 自动提交模式下语句失败不该留下事务状态。
    func testFailedStatementInAutoCommitKeepsIdle() {
        var session = TransactionSession()
        _ = session.prepareStatement()
        session.statementFailed(reason: "boom")
        XCTAssertEqual(session.phase, .idle)
    }

    /// 取消 = 失败：PostgreSQL 里被取消的语句同样会让事务进入失败态。
    func testCancelledStatementAbortsManualTransaction() {
        var session = TransactionSession(mode: .manual)
        _ = session.prepareStatement()
        session.statementFailed(reason: "已取消")
        XCTAssertEqual(session.phase, .aborted(reason: "已取消"))
    }

    // MARK: 模式切换

    /// 有进行中的事务时不许直接切回自动提交 —— 静默提交与静默丢弃都是事故。
    func testCannotSwitchToAutoCommitWithOpenTransaction() {
        var session = TransactionSession(mode: .manual)
        _ = session.prepareStatement()

        XCTAssertEqual(session.setMode(.autoCommit), .refuse(.hasOpenTransaction))
        XCTAssertEqual(session.mode, .manual, "拒绝后模式必须保持不变")

        _ = session.rollback()
        XCTAssertEqual(session.setMode(.autoCommit), .nothing)
        XCTAssertEqual(session.mode, .autoCommit)
    }

    /// 失败态同样算「有事务」：不能靠切模式把它当没发生。
    func testCannotSwitchToAutoCommitWithAbortedTransaction() {
        var session = TransactionSession(mode: .manual)
        _ = session.prepareStatement()
        session.statementFailed(reason: "boom")
        XCTAssertEqual(session.setMode(.autoCommit), .refuse(.hasOpenTransaction))
    }

    // MARK: 连接 / 数据库切换

    func testConnectionChangeRollsBackOpenTransaction() {
        var session = TransactionSession(mode: .manual)
        _ = session.prepareStatement()
        _ = session.prepareStatement()

        XCTAssertEqual(session.connectionDidChange(), .rollback)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.mode, .manual, "回滚不该顺手把用户的模式偏好改掉")
        XCTAssertEqual(session.connectionDidChange(), .nothing, "没有事务时无需动作")
    }

    func testConnectionChangeRollsBackAbortedTransactionToo() {
        var session = TransactionSession(mode: .manual)
        _ = session.prepareStatement()
        session.statementFailed(reason: "boom")
        XCTAssertEqual(session.connectionDidChange(), .rollback)
        XCTAssertEqual(session.phase, .idle)
    }

    /// 提交 / 回滚命令本身失败（连接断、延迟约束冲突）：事务在服务端已结束 ——
    /// 状态必须退回 idle，绝不能显示成「已提交」。
    func testServerCommandFailureEndsTransaction() {
        var session = TransactionSession(mode: .manual)
        _ = session.prepareStatement()
        XCTAssertEqual(session.commit(), .commit)
        XCTAssertEqual(session.phase, .idle)

        // 模拟 COMMIT 在服务端失败后的处置。
        _ = session.prepareStatement()
        session.serverCommandFailed()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.mode, .manual, "模式偏好不该被一次失败改掉")
        XCTAssertEqual(session.prepareStatement(), .begin, "还能重新开始一条事务")
    }

    // MARK: 阶段辅助

    func testPhaseHelpers() {
        XCTAssertFalse(TransactionPhase.idle.isOpen)
        XCTAssertTrue(TransactionPhase.open(statementCount: 1).isOpen)
        XCTAssertTrue(TransactionPhase.aborted(reason: "x").isOpen)
        XCTAssertEqual(TransactionPhase.open(statementCount: 7).statementCount, 7)
        XCTAssertEqual(TransactionPhase.aborted(reason: "x").statementCount, 0)
    }

    /// 每个拒绝原因都要能区分 —— 界面据此给出不同提示，合并成一个就等于让用户猜。
    func testRefusalReasonsAreDistinct() {
        let reasons: [TransactionRefusal] = [.notInManualMode, .nothingToDo, .aborted, .hasOpenTransaction]
        XCTAssertEqual(Set(reasons.map { "\($0)" }).count, reasons.count)
    }

    func testModeRoundTrip() {
        var session = TransactionSession()
        XCTAssertFalse(session.mode.isManual)
        session.setMode(.manual)
        XCTAssertTrue(session.mode.isManual)
        XCTAssertEqual(TransactionMode.allCases.count, 2)
    }
}
