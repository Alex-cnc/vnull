import XCTest
@testable import PostgresClientCore

/// FR-IO-04：备份 / 恢复命令行构建。
final class BackupCommandTests: XCTestCase {

    private let target = BackupCommand.Target(host: "db.internal", port: 5432, user: "alice", database: "appdb")

    // MARK: - pg_dumpall（集群级）

    func testDumpAllProducesClusterLevelCommand() {
        let argv = BackupCommand.dumpAll(target: BackupCommand.Target(host: "db.internal", port: 5432, user: "alice"),
                                         filePath: "/tmp/cluster.sql")
        XCTAssertEqual(argv, ["pg_dumpall", "--host", "db.internal", "--port", "5432",
                              "--username", "alice", "--file", "/tmp/cluster.sql"])
    }

    func testDumpAllRolesOnlyWithNoRolePasswords() {
        let argv = BackupCommand.dumpAll(
            target: BackupCommand.Target(host: "h", port: 5433),
            rolesOnly: true,
            noRolePasswords: true
        )
        XCTAssertEqual(argv, ["pg_dumpall", "--host", "h", "--port", "5433", "--roles-only", "--no-role-passwords"])
    }

    func testDumpAllRejectsConflictingScopeFlags() {
        // PostgreSQL 不允许 --roles-only 与 --globals-only 同时出现。
        XCTAssertNil(BackupCommand.dumpAll(target: target, rolesOnly: true, globalsOnly: true))
    }

    func testDumpAllRejectsInvalidPort() {
        XCTAssertNil(BackupCommand.dumpAll(target: BackupCommand.Target(host: "h", port: 0)))
        XCTAssertNil(BackupCommand.dumpAll(target: BackupCommand.Target(host: "h", port: 70000)))
    }

    // MARK: - pg_dump（单库）

    func testDumpPlainWithFile() {
        let argv = BackupCommand.dump(target: target, format: .plain, filePath: "/tmp/appdb.sql")
        XCTAssertEqual(argv, ["pg_dump", "--host", "db.internal", "--port", "5432", "--username", "alice",
                              "--format", "plain", "--file", "/tmp/appdb.sql", "appdb"])
    }

    func testDumpDirectorySupportsParallelJobs() {
        let argv = BackupCommand.dump(target: target, format: .directory, filePath: "/tmp/dumpdir", jobs: 4, noOwner: true)
        XCTAssertEqual(argv, ["pg_dump", "--host", "db.internal", "--port", "5432", "--username", "alice",
                              "--format", "directory", "--no-owner", "--jobs", "4",
                              "--file", "/tmp/dumpdir", "appdb"])
    }

    func testDumpRejectsJobsForNonDirectoryFormats() {
        // 只有 directory 格式支持并行导出。
        XCTAssertNil(BackupCommand.dump(target: target, format: .custom, jobs: 4))
        XCTAssertNil(BackupCommand.dump(target: target, format: .plain, jobs: 2))
    }

    func testDumpRequiresDatabaseAndValidPort() {
        XCTAssertNil(BackupCommand.dump(target: BackupCommand.Target(host: "h"), format: .plain))
        XCTAssertNil(BackupCommand.dump(target: BackupCommand.Target(host: "h", port: -1, database: "db")))
    }

    // MARK: - 参数安全

    func testArgumentsAreNotShellInterpolated() {
        // 恶意库名只会成为「一个 argv 元素」，不会被拆成多条命令 —— 这正是用 argv 而非拼串的意义。
        let evil = "appdb\"; rm -rf / #"
        let argv = BackupCommand.dump(target: BackupCommand.Target(host: "h", port: 5432, database: evil))
        XCTAssertEqual(argv?.last, evil)
        XCTAssertEqual(argv?.count, 8)   // 未被拆开：pg_dump --host h --port 5432 --format plain <db>
        XCTAssertFalse(argv?.contains("rm") ?? true)
    }

    // MARK: - pg_restore

    func testRestorePutsArchiveLastAndSupportsCleanAndJobs() {
        let argv = BackupCommand.restore(target: target, archivePath: "/tmp/appdb.dump", clean: true, jobs: 2, section: "data")
        XCTAssertEqual(argv, ["pg_restore", "--host", "db.internal", "--port", "5432", "--username", "alice",
                              "--dbname", "appdb", "--clean", "--jobs", "2", "--section", "data", "/tmp/appdb.dump"])
    }

    func testRestoreRejectsInvalidInputs() {
        XCTAssertNil(BackupCommand.restore(target: target, archivePath: "", clean: true))
        XCTAssertNil(BackupCommand.restore(target: target, archivePath: "/tmp/x.dump", jobs: 0))
        XCTAssertNil(BackupCommand.restore(target: BackupCommand.Target(host: "h", port: 5432), archivePath: "/tmp/x.dump"))
    }
}
