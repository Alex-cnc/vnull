import XCTest
@testable import DoyahCore

/// 连接颜色与环境标签（FR-CONN-16）。
///
/// 这一条的价值全在两处：**所有显示连接名的地方一致**（否则等于没标）、
/// 以及**生产标签参与安全判定**（否则标签只是装饰）。
final class ConnectionAppearanceTests: XCTestCase {

    // MARK: 外观与优先级

    /// 环境标签优先于自选色 —— **安全信息不能被自定义色盖掉**。
    func testEnvironmentToneWinsOverCustomColor() {
        let appearance = ConnectionAppearance(environment: .production, colorTag: .teal)
        XCTAssertEqual(appearance.tone, .danger, "生产必须是危险色")
        XCTAssertEqual(appearance.accent, .status(.danger))
    }

    func testCustomColorUsedWhenNoEnvironment() {
        let appearance = ConnectionAppearance(environment: nil, colorTag: .teal)
        XCTAssertEqual(appearance.accent, .categorical(.teal))
        XCTAssertNil(appearance.tone)
    }

    func testNoTagMeansNoAccent() {
        XCTAssertNil(ConnectionAppearance().accent)
        XCTAssertFalse(ConnectionAppearance().showsEnvironmentBadge)
    }

    func testEnvironmentTonesAreDistinctAndMeaningful() {
        XCTAssertEqual(ConnectionEnvironment.production.tone, .danger)
        XCTAssertEqual(ConnectionEnvironment.staging.tone, .warning)
        XCTAssertNotEqual(ConnectionEnvironment.testing.tone, .danger, "测试环境不该是危险色")
        XCTAssertTrue(ConnectionEnvironment.production.isProduction)
        XCTAssertFalse(ConnectionEnvironment.staging.isProduction)
        XCTAssertTrue(ConnectionEnvironment.production.recommendsReadOnly)
        XCTAssertFalse(ConnectionEnvironment.development.recommendsReadOnly)
    }

    /// 下拉顺序里生产在最前（生产不该藏在列表最后）。
    func testProductionIsFirstInPickOrder() {
        XCTAssertEqual(ConnectionEnvironment.orderedForPick.first, .production)
        XCTAssertEqual(Set(ConnectionEnvironment.orderedForPick), Set(ConnectionEnvironment.allCases))
    }

    // MARK: 安全联动

    /// **核心断言**：生产标签下，即使 Safe Mode 总开关关掉，高危语句**仍然要确认**。
    func testProductionForcesConfirmationEvenWhenSafeModeIsOff() {
        let policy = ExecutionSafetyPolicy.policy(for: ConnectionAppearance(environment: .production), isEnabled: false)
        XCTAssertTrue(policy.forcesConfirmationForHighRisk)

        let decision = ExecutionSafety.check(sql: "DROP TABLE users;", policy: policy)
        guard case .needsConfirmation = decision else {
            return XCTFail("生产连接上关掉总开关后仍应确认高危语句，实际 \(decision)")
        }
    }

    /// 非生产连接上关掉总开关 = 放行（尊重用户的选择）。
    func testNonProductionHonoursDisabledSafeMode() {
        for environment: ConnectionEnvironment? in [nil, .staging, .testing, .development] {
            let policy = ExecutionSafetyPolicy.policy(for: ConnectionAppearance(environment: environment), isEnabled: false)
            XCTAssertFalse(policy.forcesConfirmationForHighRisk, "\(environment?.rawValue ?? "nil") 不该强制")
            XCTAssertEqual(ExecutionSafety.check(sql: "DROP TABLE users;", policy: policy), .allow)
        }
    }

    /// 多语句入口与单条入口**口径一致**（这条一致性我第一版漏了，靠测试才发现）。
    func testForcedConfirmationAlsoAppliesToStatementList() {
        let policy = ExecutionSafetyPolicy.policy(for: ConnectionAppearance(environment: .production), isEnabled: false)
        let decision = ExecutionSafety.check(statements: ["SELECT 1", "TRUNCATE TABLE t"], policy: policy)
        guard case .needsConfirmation = decision else {
            return XCTFail("多语句入口也应强制确认，实际 \(decision)")
        }
    }

    /// 生产连接上普通语句不该被拦（只对高危强制，不是"什么都弹窗"）。
    func testProductionDoesNotConfirmHarmlessStatements() {
        let policy = ExecutionSafetyPolicy.policy(for: ConnectionAppearance(environment: .production), isEnabled: false)
        XCTAssertEqual(ExecutionSafety.check(sql: "SELECT * FROM orders;", policy: policy), .allow)
    }

    // MARK: 配置持久化

    /// 标签与颜色要能存下来读回来（按**名字**存，不存色值）。
    func testConfigRoundTripKeepsAppearance() throws {
        let configuration = ConnectionConfig(
            name: "生产库",
            host: "10.0.0.5",
            database: "app",
            username: "app",
            environment: .production,
            colorTag: .magenta
        )
        let data = try JSONEncoder().encode([configuration])
        let decoded = try JSONDecoder().decode([ConnectionConfig].self, from: data)

        XCTAssertEqual(decoded.first?.environment, .production)
        XCTAssertEqual(decoded.first?.colorTag, .magenta)
        XCTAssertEqual(decoded.first?.appearance.accent, .status(.danger))
    }

    /// **老配置（没有这两个字段）必须照常读出来**，且不因为新增字段被误判成"更新版本"。
    func testLegacyConfigWithoutAppearanceStillDecodes() throws {
        let json = """
        [{"id":"D264B21B-1880-4E73-A2D0-59A3F8E4D7EC","name":"老配置","host":"192.168.5.217",
          "database":"zxvmax","username":"zxvmax","schemaVersion":1}]
        """
        let decoded = try JSONDecoder().decode([ConnectionConfig].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded.first?.environment)
        XCTAssertNil(decoded.first?.colorTag)
        // 不提升 schemaVersion：可选字段的纯新增不该让老版本把这些配置当成"来自更新版本"。
        XCTAssertEqual(decoded.first?.schemaVersion, 1)
        XCTAssertEqual(ConnectionConfig.currentSchemaVersion, 1)
    }

    /// 存储层往返（真文件）：写进去、读出来、外观还在。
    func testStoreKeepsAppearance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionAppearanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConnectionStore(directoryURL: directory)
        let configuration = ConnectionConfig(
            name: "预发", host: "10.0.0.6", database: "app", username: "app",
            environment: .staging, colorTag: .blue
        )
        try await store.save([configuration])

        let (loaded, summary) = try await store.loadWithReport()
        XCTAssertEqual(loaded.first?.environment, .staging)
        XCTAssertEqual(loaded.first?.colorTag, .blue)
        XCTAssertTrue(summary.isNoop, "同版本读写不该触发迁移")
    }
}
