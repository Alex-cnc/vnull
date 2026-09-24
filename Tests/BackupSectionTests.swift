import XCTest
@testable import DoyahCore

/// `pg_restore` 的 `--section` / `--exit-on-error` 接线（FR-IO-05 的第一步）。
///
/// 这一步本身不构成 FR-IO-05（续跑流程与脚本验证仍未做），但它是续跑的前提：
/// 没有分段与"遇错即停"，失败后根本不知道该从哪一段接着做。
final class BackupSectionTests: XCTestCase {

    private func plan(section: String?, exitOnError: Bool = false, clean: Bool = false) -> BackupPlan {
        BackupPlan(
            kind: .restore,
            target: BackupCommand.Target(host: "127.0.0.1", port: 5432, user: "postgres", database: "target_db"),
            format: .custom,
            filePath: "/tmp/archive.dump",
            clean: clean,
            section: section,
            exitOnError: exitOnError,
            executableName: "pg_restore"
        )
    }

    func testSectionFlagIsPassedThrough() {
        let argv = plan(section: "data").arguments
        XCTAssertEqual(argv?.suffix(3), ["--section", "data", "/tmp/archive.dump"], "\(argv ?? [])")
    }

    func testExitOnErrorFlagIsPassedThrough() {
        let argv = plan(section: nil, exitOnError: true).arguments
        XCTAssertTrue(argv?.contains("--exit-on-error") == true, "\(argv ?? [])")
        XCTAssertFalse(plan(section: nil, exitOnError: false).arguments?.contains("--exit-on-error") == true)
    }

    /// 分段与目标库一起出现：恢复的去向必须是目标库（这是 FR-IO-05 的"恢复到指定库"）。
    func testRestoreTargetsSpecifiedDatabase() {
        let argv = plan(section: "pre-data").arguments ?? []
        XCTAssertTrue(argv.contains("--dbname"), "\(argv)")
        XCTAssertTrue(argv.contains("target_db"), "\(argv)")
        XCTAssertTrue(argv.contains("--section"), "\(argv)")
    }

    func testCleanAndJobsStillWorkAlongsideSection() {
        let argv = plan(section: "post-data", clean: true).arguments ?? []
        XCTAssertTrue(argv.contains("--clean"), "\(argv)")
        XCTAssertFalse(argv.contains("--exit-on-error"), "\(argv)")
    }

    /// 恢复必须给出目标库：没有库名的 restore 命令是无效的（不是"默认当前库"那么随便）。
    func testRestoreWithoutDatabaseProducesNoArguments() {
        let broken = BackupPlan(
            kind: .restore,
            target: BackupCommand.Target(host: "127.0.0.1", port: 5432, user: nil, database: nil),
            format: .custom,
            filePath: "/tmp/archive.dump",
            executableName: "pg_restore"
        )
        XCTAssertNil(broken.arguments)
    }
}
