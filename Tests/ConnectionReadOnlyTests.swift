import XCTest
@testable import DoyahCore

/// 只读连接与启动 SQL（FR-CONN-17）。
///
/// 这一项的关键口径有两个，都容易做松：
/// ① 只读是**连接属性**而不是提醒 —— 关掉 Safe Mode 也必须拦得住（否则"只读"就成了一句装饰）；
/// ② 启动 SQL 要**逐条**执行与报错 —— 一条失败吞掉后面，`search_path` 没设上会让后续所有查询找错表。
final class ConnectionReadOnlyTests: XCTestCase {

    private func configuration(
        isReadOnly: Bool = false,
        startupSQL: String? = nil
    ) -> ConnectionConfig {
        ConnectionConfig(
            id: UUID(),
            name: "测试连接",
            dbType: .postgresql,
            host: "127.0.0.1",
            port: 5432,
            database: "postgres",
            username: "tester",
            sslMode: .disable,
            timeout: 5,
            isReadOnly: isReadOnly,
            startupSQL: startupSQL
        )
    }

    // MARK: 配置持久化

    func testConfigRoundTripCarriesReadOnlyAndStartupSQL() throws {
        let original = configuration(isReadOnly: true, startupSQL: "SET search_path TO public;")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)

        XCTAssertTrue(decoded.isReadOnly)
        XCTAssertEqual(decoded.startupSQL, "SET search_path TO public;")
        XCTAssertEqual(decoded.schemaVersion, original.schemaVersion, "纯新增可选字段不该抬高版本")
    }

    /// 老配置（没有这两个字段）必须照常读出来：**缺失就是默认值**，不触发迁移。
    func testOldConfigWithoutNewFieldsGetsDefaults() throws {
        let json = """
        {"id":"D264B21B-1880-4E73-A2D0-59A3F8E4D7EC","name":"老配置","host":"127.0.0.1",
         "database":"postgres","username":"tester","schemaVersion":1}
        """
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isReadOnly, "没标记就是可写（默认值）")
        XCTAssertNil(decoded.startupSQL)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testStartupStatementsAreSplitAndFiltered() {
        XCTAssertEqual(
            configuration(startupSQL: "SET search_path TO public; SET statement_timeout = '5s';").startupStatements.count,
            2
        )
        XCTAssertTrue(configuration(startupSQL: "   ").startupStatements.isEmpty)
        XCTAssertTrue(configuration(startupSQL: nil).startupStatements.isEmpty)
        XCTAssertTrue(configuration(startupSQL: "-- 只是注释").startupStatements.isEmpty)
        // 末尾分号不该产生一条空语句
        XCTAssertEqual(configuration(startupSQL: "SET search_path TO public;").startupStatements, ["SET search_path TO public"])
    }

    // MARK: 只读强制

    func testReadOnlyRefusesWriteStatements() {
        let policy = ExecutionSafetyPolicy(isEnabled: false, isReadOnly: true)
        for sql in [
            "INSERT INTO t VALUES (1)",
            "UPDATE t SET a = 1",
            "DELETE FROM t",
            "DROP TABLE t",
            "TRUNCATE t",
            "CREATE TABLE t (id int)"
        ] {
            let decision = ExecutionSafety.check(sql: sql, policy: policy)
            guard case .refused(let reasons, let statements) = decision else {
                return XCTFail("\(sql) 应被只读连接拒绝，实际 \(decision)")
            }
            XCTAssertFalse(decision.isAllowed)
            XCTAssertTrue(reasons.contains { $0.contains("只读") }, "\(reasons)")
            XCTAssertEqual(statements.count, 1, "\(statements)")
            XCTAssertTrue(decision.message.contains("只读"), decision.message)
        }
    }

    func testReadOnlyAllowsReadsAndSessionSettings() {
        let policy = ExecutionSafetyPolicy(isEnabled: false, isReadOnly: true)
        for sql in [
            "SELECT 1",
            "SELECT * FROM orders WHERE id = 1",
            "SHOW search_path",
            "SET search_path TO public",
            "SET statement_timeout = '5s'",
            "EXPLAIN SELECT 1"
        ] {
            XCTAssertTrue(
                ExecutionSafety.check(sql: sql, policy: policy).isAllowed,
                "\(sql) 在只读连接上应当允许"
            )
        }
    }

    /// **不可绕过**：关掉 Safe Mode 也照样拒绝（只读是连接属性，不是提醒）。
    func testReadOnlyCannotBeBypassedBySafeModeToggle() {
        for enabled in [true, false] {
            let policy = ExecutionSafetyPolicy(
                isEnabled: enabled,
                confirmAllWrites: false,
                forcesConfirmationForHighRisk: false,
                isReadOnly: true
            )
            guard case .refused = ExecutionSafety.check(sql: "DROP TABLE t", policy: policy) else {
                return XCTFail("enabled=\(enabled) 时仍应拒绝")
            }
        }
    }

    /// 多语句里只有写的那条被点名（别把整段都算成违规，那样用户不知道该改哪句）。
    func testReadOnlyNamesOnlyOffendingStatements() {
        let policy = ExecutionSafetyPolicy(isEnabled: false, isReadOnly: true)
        let decision = ExecutionSafety.check(sql: "SELECT 1; DROP TABLE t; SELECT 2;", policy: policy)
        guard case .refused(_, let statements) = decision else { return XCTFail("应拒绝") }
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].contains("DROP"), "\(statements)")
    }

    func testNonReadOnlyConnectionIsUnaffected() {
        let policy = ExecutionSafetyPolicy(isEnabled: false, isReadOnly: false)
        XCTAssertTrue(ExecutionSafety.check(sql: "DROP TABLE t", policy: policy).isAllowed,
                      "非只读连接 + Safe Mode 关闭 → 照旧放行（只读判定不该顺手改变别处行为）")
    }

    func testPolicyFactoryCarriesReadOnlyAndProductionFlag() {
        let production = ConnectionAppearance(environment: .production, colorTag: nil)
        let policy = ExecutionSafetyPolicy.policy(for: production, isEnabled: false, isReadOnly: true)
        XCTAssertTrue(policy.isReadOnly)
        XCTAssertTrue(policy.forcesConfirmationForHighRisk, "生产标签仍要强制确认")
    }

    /// 启动 SQL 在只读连接上：写语句整体跳过（App 侧用同一个判定，这里钉住 Core 语义）。
    func testStartupSQLWritesAreRefusedOnReadOnlyConnection() {
        let config = configuration(isReadOnly: true, startupSQL: "SET search_path TO public; DELETE FROM t;")
        let policy = ExecutionSafetyPolicy(isEnabled: false, isReadOnly: config.isReadOnly)
        let decision = ExecutionSafety.check(
            statements: config.startupStatements,
            databaseType: config.dbType,
            policy: policy
        )
        guard case .refused(_, let statements) = decision else { return XCTFail("应拒绝") }
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].contains("DELETE"), "\(statements)")
    }
}
