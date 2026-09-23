import XCTest
import DoyahCore

/// 备份 / 恢复的**执行编排**（FR-IO-04 的执行半边）。
///
/// 真起进程不适合单测（依赖本机有没有 `pg_dump`），所以这里用一个假执行器把
/// **编排逻辑**钉死：argv 怎么拼、环境怎么传、输出怎么逐行记、退出码怎么判。
/// 真进程那条路由 `Scripts/test-backup-restore.sh` 在真机上跑（对 217 做一次往返）。
final class BackupExecutionTests: XCTestCase {

    /// 记录调用并按预置脚本回放输出的假执行器。
    final class FakeRunner: ExternalProcessRunner, @unchecked Sendable {
        struct Call: Equatable {
            var executable: String
            var arguments: [String]
            var environment: [String: String]
        }

        private let lock = NSLock()
        private(set) var calls: [Call] = []
        private var outputs: [String] = []
        private var exitCode: Int32 = 0
        private var error: Error?

        init(outputs: [String] = [], exitCode: Int32 = 0, error: Error? = nil) {
            self.outputs = outputs
            self.exitCode = exitCode
            self.error = error
        }

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            onOutput: @Sendable (String) -> Void
        ) async throws -> Int32 {
            lock.lock()
            calls.append(Call(executable: executable, arguments: arguments, environment: environment))
            let outputs = self.outputs
            let exitCode = self.exitCode
            let error = self.error
            lock.unlock()

            if let error { throw error }
            for line in outputs { onOutput(line) }
            return exitCode
        }
    }

    private let target = BackupCommand.Target(host: "192.168.5.217", port: 5432, user: "zxvmax", database: "zxvmax")

    private func makePlan(
        kind: BackupPlan.Kind = .dump,
        format: BackupCommand.Format = .plain,
        filePath: String? = "/tmp/out.sql",
        jobs: Int? = nil
    ) -> BackupPlan {
        BackupPlan(
            kind: kind,
            target: target,
            format: format,
            filePath: filePath,
            jobs: jobs,
            executableName: "pg_dump"
        )
    }

    // MARK: argv 与环境

    /// **密码只走环境变量**：进程列表里看不到它（argv 是公开的）。
    func testPasswordGoesToEnvironmentNotArguments() async throws {
        let runner = FakeRunner()
        let executor = BackupExecutor(runner: runner)
        _ = try await executor.execute(makePlan(), password: "ZXvmax_2017", onOutput: { _ in })

        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.environment["PGPASSWORD"], "ZXvmax_2017")
        XCTAssertFalse(call.arguments.contains("ZXvmax_2017"), "密码绝不能进 argv：\(call.arguments)")
        XCTAssertFalse(call.arguments.joined(separator: " ").contains("ZXvmax_2017"))
    }

    /// argv 直接交给进程，**不经过 shell**：所以危险字符只是普通参数。
    func testArgumentsArePassedVerbatimWithoutShell() async throws {
        let runner = FakeRunner()
        let executor = BackupExecutor(runner: runner)
        let nasty = BackupCommand.Target(host: "127.0.0.1", port: 5432, user: "u", database: "db; rm -rf /")
        let plan = BackupPlan(kind: .dump, target: nasty, format: .plain, filePath: "/tmp/x.sql", executableName: "pg_dump")

        _ = try await executor.execute(plan, password: nil, onOutput: { _ in })

        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, "pg_dump")
        XCTAssertTrue(call.arguments.contains("db; rm -rf /"), "整串应当作为一个参数原样传入：\(call.arguments)")
        XCTAssertFalse(call.arguments.contains("-c"), "不该出现 shell 的 -c")
    }

    func testPlanRejectsInvalidConfiguration() {
        // 没有库名的单库备份生成不出命令
        let noDatabase = BackupCommand.Target(host: "127.0.0.1", port: 5432, database: nil)
        XCTAssertNil(BackupPlan(kind: .dump, target: noDatabase, executableName: "pg_dump").arguments)
        // jobs 只对 directory 合法
        XCTAssertNil(BackupPlan(
            kind: .dump, target: target, format: .plain, filePath: "/tmp/x", jobs: 4, executableName: "pg_dump"
        ).arguments)
        XCTAssertNotNil(BackupPlan(
            kind: .dump, target: target, format: .directory, filePath: "/tmp/dir", jobs: 4, executableName: "pg_dump"
        ).arguments)
    }

    // MARK: 输出与退出码

    /// 输出**逐行、按到达顺序**记下来（备份日志的价值就在顺序里）。
    func testOutputLinesAreStreamedInOrder() async throws {
        let runner = FakeRunner(outputs: ["pg_dump: dumping contents of table \"orders\"", "pg_dump: done"])
        let executor = BackupExecutor(runner: runner)
        var lines: [String] = []

        let result = try await executor.execute(makePlan(), password: nil, onOutput: { lines.append($0) })

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(lines, ["pg_dump: dumping contents of table \"orders\"", "pg_dump: done"])
        XCTAssertEqual(result.outputLineCount, 2)
    }

    /// 非零退出码是**失败**，并把最后几行当线索带出来 —— 不能只说"失败了"。
    func testNonZeroExitIsFailureWithReadableReason() async throws {
        let runner = FakeRunner(outputs: ["pg_dump: error: connection to server failed"], exitCode: 1)
        let executor = BackupExecutor(runner: runner)

        let result = try await executor.execute(makePlan(), password: nil, onOutput: { _ in })

        XCTAssertTrue(result.isFailure)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.failureSummary?.contains("connection to server failed") ?? false,
                      "失败摘要要带上最后几行输出：\(result.failureSummary ?? "nil")")
    }

    func testFailureSummaryIsNilOnSuccess() async throws {
        let runner = FakeRunner(outputs: ["ok"], exitCode: 0)
        let result = try await BackupExecutor(runner: runner).execute(makePlan(), password: nil, onOutput: { _ in })
        XCTAssertFalse(result.isFailure)
        XCTAssertNil(result.failureSummary)
    }

    /// 启动失败（程序不存在）要抛可读错误，不是"退出码 -1"这种没法排查的东西。
    func testLaunchFailureSurfacesReadableError() async throws {
        let runner = FakeRunner(error: ExternalProcessError.launchFailed(executable: "pg_dump", reason: "在 PATH 里找不到"))
        do {
            _ = try await BackupExecutor(runner: runner).execute(makePlan(), password: nil, onOutput: { _ in })
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pg_dump"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("PATH"), error.localizedDescription)
        }
    }

    // MARK: 计划的命令展示

    /// 展示给用户的命令行**不得包含密码**（写进日志/截图都不该泄漏）。
    func testDisplayCommandHidesPassword() {
        let text = makePlan().displayCommand(password: "secret-value")
        XCTAssertFalse(text.contains("secret-value"), text)
        XCTAssertTrue(text.contains("PGPASSWORD=***"), text)
        XCTAssertTrue(text.contains("pg_dump"), text)
    }

    /// 恢复（`pg_restore`）走同一条编排，只是可执行文件与参数不同。
    func testRestorePlanUsesRestoreExecutable() async throws {
        let runner = FakeRunner()
        let executor = BackupExecutor(runner: runner)
        let restore = BackupPlan(
            kind: .restore,
            target: target,
            format: .custom,
            filePath: "/tmp/backup.dump",
            executableName: "pg_restore"
        )

        _ = try await executor.execute(restore, password: "p", onOutput: { _ in })

        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, "pg_restore")
        XCTAssertTrue(call.arguments.contains("--dbname") || call.arguments.contains(target.database ?? ""),
                      "\(call.arguments)")
    }
}
