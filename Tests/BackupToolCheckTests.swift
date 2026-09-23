import XCTest
@testable import DoyahCore

/// 备份工具与服务器的版本兼容性（FR-IO-04 的前置检查）。
///
/// 规则来自 PostgreSQL 本身：**pg_dump 只能处理不比自己新的服务器**。
/// 这组测试把规则与"可读诊断"钉住 —— 本机实测撞到过客户端 16.2 / 服务端 18.6 被拒。
final class BackupToolCheckTests: XCTestCase {

    private func version(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> DatabaseVersion {
        DatabaseVersion(major: major, minor: minor, patch: patch, raw: "\(major).\(minor)")
    }

    // MARK: 判定

    func testSameMajorIsCompatible() {
        XCTAssertEqual(
            BackupToolCheck.evaluate(toolVersion: version(16, 2), serverVersion: version(16, 9)),
            .compatible
        )
        XCTAssertTrue(BackupToolCheck.evaluate(toolVersion: version(16), serverVersion: version(16)).isUsable)
    }

    /// **工具比服务器新是允许的**（能导出更老的服务器）—— 别把这条误判成问题。
    func testToolNewerThanServerIsAllowed() {
        let result = BackupToolCheck.evaluate(toolVersion: version(18, 6), serverVersion: version(16, 2))
        XCTAssertEqual(result, .toolNewerThanServer(toolMajor: 18, serverMajor: 16))
        XCTAssertTrue(result.isUsable)
        XCTAssertNil(BackupToolCheck.diagnosis(for: result, toolName: "pg_dump"), "允许的情况不该打扰用户")
    }

    /// 工具比服务器旧：**不可用**，且诊断要说清"为什么"与"怎么办"。
    func testToolOlderThanServerIsBlockedWithActionableDiagnosis() throws {
        let result = BackupToolCheck.evaluate(toolVersion: version(16, 2), serverVersion: version(18, 6))
        XCTAssertEqual(result, .toolOlderThanServer(toolMajor: 16, serverMajor: 18))
        XCTAssertFalse(result.isUsable)

        let diagnosis = try XCTUnwrap(BackupToolCheck.diagnosis(for: result, toolName: "pg_dump"))
        XCTAssertTrue(diagnosis.contains("16"), diagnosis)
        XCTAssertTrue(diagnosis.contains("18"), diagnosis)
        XCTAssertTrue(diagnosis.contains("--tool"), "要告诉用户怎么指定工具路径：\(diagnosis)")
    }

    /// 拿不到版本时**不假装兼容**：说"不确定"，让用户自己判断。
    func testUnknownVersionIsNotTreatedAsCompatible() throws {
        let result = BackupToolCheck.evaluate(toolVersion: nil, serverVersion: version(18))
        guard case .unknown(let reason) = result else { return XCTFail("应当是 unknown，实际 \(result)") }
        XCTAssertFalse(result.isUsable)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNotNil(BackupToolCheck.diagnosis(for: result, toolName: "pg_dump"))

        // 服务器版本拿不到同理。
        guard case .unknown = BackupToolCheck.evaluate(toolVersion: version(16), serverVersion: nil) else {
            return XCTFail("服务端版本未知时应当是同一种结论")
        }
    }

    // MARK: 版本解析

    func testParseToolVersionFromRealOutput() {
        // 本机实测输出
        XCTAssertEqual(BackupToolCheck.parseToolVersion("pg_dump (PostgreSQL) 16.2")?.major, 16)
        XCTAssertEqual(BackupToolCheck.parseToolVersion("pg_dump (PostgreSQL) 16.2")?.minor, 2)
        let detailed = BackupToolCheck.parseToolVersion("pg_restore (PostgreSQL) 18.6 (Debian 18.6-1.pgdg120+1)")
        XCTAssertEqual(detailed?.major, 18)
        XCTAssertEqual(detailed?.minor, 6)
        XCTAssertEqual(BackupToolCheck.parseToolVersion("pg_dump (PostgreSQL) 17\n")?.major, 17)
    }

    func testParseToolVersionReturnsNilForGarbage() {
        XCTAssertNil(BackupToolCheck.parseToolVersion("command not found"))
        XCTAssertNil(BackupToolCheck.parseToolVersion(""))
    }

    /// 端到端的小组合：真实输出 → 解析 → 判定。
    func testParseThenEvaluate() throws {
        let tool = try XCTUnwrap(BackupToolCheck.parseToolVersion("pg_dump (PostgreSQL) 16.2"))
        let server = version(18, 6)
        XCTAssertFalse(BackupToolCheck.evaluate(toolVersion: tool, serverVersion: server).isUsable)

        let newerTool = try XCTUnwrap(BackupToolCheck.parseToolVersion("pg_dump (PostgreSQL) 18.6"))
        XCTAssertTrue(BackupToolCheck.evaluate(toolVersion: newerTool, serverVersion: server).isUsable)
    }
}
