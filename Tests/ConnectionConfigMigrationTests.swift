import XCTest
@testable import DoyahCore

/// 连接配置迁移（FR-CONN-10 / DR-03）：老格式能读、幂等、**不碰更高版本**。
final class ConnectionConfigMigrationTests: XCTestCase {

    private func configured(version: Int, port: Int = 5432, timeout: Int = 5) -> ConnectionConfig {
        ConnectionConfig(
            name: "本地",
            dbType: .postgresql,
            host: "127.0.0.1",
            port: port,
            database: "postgres",
            username: "postgres",
            timeout: timeout,
            schemaVersion: version
        )
    }

    // MARK: 幂等与正常化

    func testCurrentVersionIsUnchanged() {
        let config = configured(version: ConnectionConfig.currentSchemaVersion)
        let (result, outcome) = ConnectionConfigMigrator.migrate(config)
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(result, config, "当前版本必须原样返回（反复加载不能来回改）")
    }

    /// v0（没有 schemaVersion 字段的老文件）补到当前版本，并正常化零值字段。
    func testLegacyVersionIsNormalized() {
        let legacy = configured(version: 0, port: 0, timeout: 0)
        let (result, outcome) = ConnectionConfigMigrator.migrate(legacy)

        XCTAssertEqual(outcome, .migrated(from: 0))
        XCTAssertEqual(result.schemaVersion, ConnectionConfig.currentSchemaVersion)
        XCTAssertEqual(result.port, DatabaseType.postgresql.defaultPort, "零端口落回该类型默认端口")
        XCTAssertEqual(result.timeout, 5)
        // 只补能确定的字段：主机 / 用户名 / 库名不能猜。
        XCTAssertEqual(result.host, legacy.host)
        XCTAssertEqual(result.username, legacy.username)
        XCTAssertEqual(result.database, legacy.database)
        XCTAssertEqual(result.id, legacy.id, "迁移不得换 id（否则凭据会对不上）")
    }

    /// 迁移是幂等的：迁两次结果一样。
    func testMigrationIsIdempotent() {
        let legacy = configured(version: 0, port: 0)
        let (once, _) = ConnectionConfigMigrator.migrate(legacy)
        let (twice, outcome) = ConnectionConfigMigrator.migrate(once)
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(once, twice)
    }

    func testValidPortIsKept() {
        let legacy = configured(version: 0, port: 6543)
        let (result, _) = ConnectionConfigMigrator.migrate(legacy)
        XCTAssertEqual(result.port, 6543, "合法端口不能被'正常化'掉")
    }

    func testOutOfRangePortFallsBackToDefault() {
        let legacy = configured(version: 0, port: 70_000)
        let (result, _) = ConnectionConfigMigrator.migrate(legacy)
        XCTAssertEqual(result.port, DatabaseType.postgresql.defaultPort)
    }

    // MARK: 更高版本

    /// 来自更新版本的配置**原样保留**：不迁移、不降级、不假装懂它。
    func testNewerVersionIsKeptAsIs() {
        let future = configured(version: ConnectionConfig.currentSchemaVersion + 3)
        let (result, outcome) = ConnectionConfigMigrator.migrate(future)
        XCTAssertEqual(outcome, .skippedNewerVersion(found: ConnectionConfig.currentSchemaVersion + 3))
        XCTAssertEqual(result, future)
    }

    // MARK: 批量与摘要

    func testBatchSummaryCountsEveryCase() {
        let configs = [
            configured(version: 0),
            configured(version: 0),
            configured(version: ConnectionConfig.currentSchemaVersion),
            configured(version: ConnectionConfig.currentSchemaVersion + 1),
        ]
        let (migrated, summary) = ConnectionConfigMigrator.migrate(configs)

        XCTAssertEqual(summary.migrated.count, 2)
        XCTAssertEqual(summary.migratedFromVersions[0], 2)
        XCTAssertEqual(summary.skippedNewerVersions[ConnectionConfig.currentSchemaVersion + 1], 1)
        XCTAssertTrue(summary.didMigrate)
        XCTAssertTrue(summary.didSkipNewer)
        XCTAssertFalse(summary.isNoop)

        XCTAssertEqual(migrated.count, configs.count, "迁移不增减条目")
        XCTAssertEqual(migrated[2], configs[2], "已是当前版本的条目逐字段不变")
        XCTAssertEqual(migrated[3], configs[3], "更新版本的条目逐字段不变")
    }

    func testEmptySummaryIsNoop() {
        let (_, summary) = ConnectionConfigMigrator.migrate([configured(version: ConnectionConfig.currentSchemaVersion)])
        XCTAssertTrue(summary.isNoop)
        XCTAssertFalse(summary.didMigrate)
        XCTAssertFalse(summary.didSkipNewer)
    }

    // MARK: 解码容忍

    /// 老 JSON 里没有 `schemaVersion`（也没有 `port` / `timeout`）：必须能读出来并当作 v0，
    /// 而不是整个文件解析失败 —— 否则"预留迁移能力"等于让用户升级后连接列表打不开。
    func testDecodingJsonWithoutSchemaVersionYieldsVersionZero() throws {
        let json = """
        [{
          "id": "D264B21B-1880-4E73-A2D0-59A3F8E4D7EC",
          "name": "老配置",
          "host": "192.168.5.217",
          "database": "zxvmax",
          "username": "zxvmax"
        }]
        """
        let decoded = try JSONDecoder().decode([ConnectionConfig].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)

        let config = try XCTUnwrap(decoded.first)
        XCTAssertEqual(config.schemaVersion, 0)
        XCTAssertEqual(config.dbType, .postgresql, "缺 dbType 时按默认类型")
        XCTAssertEqual(config.port, DatabaseType.postgresql.defaultPort)
        XCTAssertEqual(config.timeout, 5)
        XCTAssertEqual(config.sslMode, DatabaseType.postgresql.defaultSSLMode)

        // 交给迁移器后就是当前版本。
        let (migrated, outcome) = ConnectionConfigMigrator.migrate(config)
        XCTAssertEqual(outcome, .migrated(from: 0))
        XCTAssertEqual(migrated.schemaVersion, ConnectionConfig.currentSchemaVersion)
    }

    // MARK: 存储层：升级真的落到文件上

    private func makeStore() throws -> (store: ConnectionStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionConfigMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ConnectionStore(directoryURL: directory), directory)
    }

    /// 老文件读得出来，并且**被升级写回**（否则每次启动都白迁一遍）。
    func testStoreRewritesLegacyFileToCurrentVersion() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let directoryURL = await store.fileLocation().deletingLastPathComponent()
        let legacyJSON = """
        [{"id":"D264B21B-1880-4E73-A2D0-59A3F8E4D7EC","name":"老配置","host":"192.168.5.217",
          "database":"zxvmax","username":"zxvmax"}]
        """
        try Data(legacyJSON.utf8).write(to: directoryURL.appendingPathComponent("connections.json"))

        let (configs, summary) = try await store.loadWithReport()
        XCTAssertEqual(configs.count, 1)
        XCTAssertTrue(summary.didMigrate)
        XCTAssertEqual(configs.first?.schemaVersion, ConnectionConfig.currentSchemaVersion)

        let rewritten = try String(contentsOf: directoryURL.appendingPathComponent("connections.json"), encoding: .utf8)
        XCTAssertTrue(rewritten.contains("\"schemaVersion\""), "升级后的文件应当带上 schemaVersion：\(rewritten)")
    }

    /// 来自更新版本的文件**不得被改写** —— 本版本不认识那些新字段，重写就是丢数据。
    func testStoreDoesNotRewriteNewerVersionFile() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let directoryURL = await store.fileLocation().deletingLastPathComponent()
        let futureJSON = """
        [{"id":"D264B21B-1880-4E73-A2D0-59A3F8E4D7EC","name":"新版本配置","host":"127.0.0.1",
          "database":"postgres","username":"postgres","schemaVersion":\(ConnectionConfig.currentSchemaVersion + 5),
          "未来字段":"必须原样保留"}]
        """
        let path = directoryURL.appendingPathComponent("connections.json")
        try Data(futureJSON.utf8).write(to: path)

        let (configs, summary) = try await store.loadWithReport()
        XCTAssertEqual(configs.first?.schemaVersion, ConnectionConfig.currentSchemaVersion + 5)
        XCTAssertTrue(summary.didSkipNewer)

        let onDisk = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(onDisk, futureJSON, "更新版本的文件必须逐字节保持不变")
    }

    /// 编码仍走合成实现：往返后逐字段一致（自定义解码不能把编码弄丢字段）。
    func testEncodeDecodeRoundTripKeepsAllFields() throws {
        let original = configured(version: ConnectionConfig.currentSchemaVersion)
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([ConnectionConfig].self, from: data)
        XCTAssertEqual(decoded, [original])
    }

    /// 迁移后的编码里必须带 schemaVersion（否则下次启动又被当 v0）。
    func testMigratedConfigEncodesSchemaVersion() throws {
        let legacy = configured(version: 0)
        let (migrated, _) = ConnectionConfigMigrator.migrate(legacy)
        let data = try JSONEncoder().encode([migrated])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schemaVersion\""), text)
        XCTAssertTrue(text.contains("\(ConnectionConfig.currentSchemaVersion)"))
    }
}
