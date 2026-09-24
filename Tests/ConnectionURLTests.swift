import XCTest
@testable import DoyahCore

/// 连接 URL 导入 / 导出（FR-CONN-19）。
///
/// 两条纪律要钉住：**密码不进配置包**（DR-02）、**解析失败说清哪里不对**（不给半个配置）。
final class ConnectionURLTests: XCTestCase {

    private func imported(_ text: String) throws -> ConnectionURL.Imported {
        switch ConnectionURL.parse(text) {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    // MARK: 解析

    func testParsesFullURL() throws {
        let result = try imported("postgres://alice:s3cret@db.example.com:6543/orders?sslmode=require")
        XCTAssertEqual(result.configuration.host, "db.example.com")
        XCTAssertEqual(result.configuration.port, 6543)
        XCTAssertEqual(result.configuration.database, "orders")
        XCTAssertEqual(result.configuration.username, "alice")
        XCTAssertEqual(result.configuration.sslMode, .require)
        XCTAssertEqual(result.password, "s3cret", "URL 里的密码要**交回调用方**（由它放进密钥存储）")
    }

    func testDefaultsWhenPortAndSSLModeAreOmitted() throws {
        let result = try imported("postgres://bob@10.0.0.5/analytics")
        XCTAssertEqual(result.configuration.port, 5432)
        XCTAssertEqual(result.configuration.sslMode, DatabaseType.postgresql.defaultSSLMode)
        XCTAssertNil(result.password)
    }

    /// `postgresql://` 是同一个协议的另一种写法。
    func testPostgresqlSchemeIsAccepted() throws {
        XCTAssertEqual(try imported("postgresql://bob@10.0.0.5/db").configuration.dbType, .postgresql)
        XCTAssertEqual(try imported("gbase://bob@10.0.0.5/db").configuration.dbType, .gbase8a)
    }

    func testPercentEncodedCredentialsAndDatabase() throws {
        let result = try imported("postgres://user%40corp:p%3Ass@host/db%20name")
        XCTAssertEqual(result.configuration.username, "user@corp")
        XCTAssertEqual(result.password, "p:ss")
        XCTAssertEqual(result.configuration.database, "db name")
    }

    func testIPv6HostRequiresBrackets() throws {
        // 加了方括号 → 正常解析（含端口）
        let withPort = try imported("postgres://[fe80::1]:6543/db").configuration
        XCTAssertEqual(withPort.host, "fe80::1")
        XCTAssertEqual(withPort.port, 6543)
        // 不加方括号 → **明确拒绝**（按"最后一个冒号是端口"切会把 host 切成 ":"）
        guard case .failure(let error) = ConnectionURL.parse("postgres://::1/db") else {
            return XCTFail("裸 IPv6 应当被拒绝")
        }
        XCTAssertEqual(error, .invalidIPv6Host("::1"))
    }

    func testUnknownQueryParametersAreReportedNotSwallowed() throws {
        let result = try imported("postgres://bob@host/db?sslmode=disable&application_name=x&connect_timeout=10")
        XCTAssertEqual(result.ignoredParameters, ["application_name=x", "connect_timeout=10"])
    }

    func testDefaultNameIsReadable() throws {
        XCTAssertEqual(try imported("postgres://bob@db.internal/orders").configuration.name, "db.internal/orders")
        guard case .success(let named) = ConnectionURL.parse("postgres://bob@db.internal/orders", name: "生产") else {
            return XCTFail("应当解析成功")
        }
        XCTAssertEqual(named.configuration.name, "生产")
    }

    // MARK: 导入合并规则（FR-CONN-19 的界面接线依赖它们）

    func testMergeKeepsUserTypedName() {
        XCTAssertEqual(
            ConnectionURL.FormMerge.resolvedName(current: "我的生产库", imported: "db.internal/orders"),
            "我的生产库"
        )
    }

    func testMergeFillsNameWhenBlank() {
        XCTAssertEqual(ConnectionURL.FormMerge.resolvedName(current: "   ", imported: "db.internal/orders"), "db.internal/orders")
        XCTAssertEqual(ConnectionURL.FormMerge.resolvedName(current: "", imported: "db.internal/orders"), "db.internal/orders")
    }

    func testMergeKeepsPasswordWhenURLHasNone() {
        // URL 里没写密码 => 保持用户已输入的，**不清空**。
        XCTAssertEqual(ConnectionURL.FormMerge.resolvedPassword(current: "typed", imported: nil), "typed")
    }

    func testMergeUsesPasswordFromURLWhenPresent() {
        XCTAssertEqual(ConnectionURL.FormMerge.resolvedPassword(current: "typed", imported: "from-url"), "from-url")
    }

    // MARK: 解析失败

    func testFailuresAreSpecific() {
        func error(_ text: String) -> ConnectionURL.ParseError? {
            if case .failure(let error) = ConnectionURL.parse(text) { return error }
            return nil
        }
        XCTAssertEqual(error(""), .empty)
        XCTAssertEqual(error("mysql://bob@host/db"), .unsupportedScheme("mysql"))
        XCTAssertEqual(error("postgres://"), .missingHost)
        XCTAssertEqual(error("postgres://host"), .missingDatabase)
        XCTAssertEqual(error("postgres://host:abc/db"), .invalidPort("abc"))
        XCTAssertNil(error("postgres://bob@host/db"))
    }

    // MARK: 导出

    /// **导出的 URL 不含密码**（需求原文 + DR-02）。
    func testExportedURLHasNoPassword() {
        let configuration = ConnectionConfig(
            name: "订单库", dbType: .postgresql, host: "db.example.com", port: 6543,
            database: "orders", username: "alice", sslMode: .verifyFull, timeout: 5
        )
        let url = ConnectionURL.url(for: configuration)
        XCTAssertFalse(url.contains("s3cret"))
        XCTAssertFalse(url.contains(":" + "s3cret"))
        XCTAssertTrue(url.hasPrefix("postgres://alice@db.example.com:6543/orders"), url)
        XCTAssertTrue(url.contains("sslmode=verify-full"), url)
    }

    /// 往返：导出的 URL 再解析回来，关键字段一致。
    func testURLRoundTrip() throws {
        let original = ConnectionConfig(
            name: "n", dbType: .postgresql, host: "10.0.0.9", port: 5432,
            database: "db", username: "u ser", sslMode: .disable, timeout: 5
        )
        let result = try imported(ConnectionURL.url(for: original))
        XCTAssertEqual(result.configuration.host, original.host)
        XCTAssertEqual(result.configuration.port, original.port)
        XCTAssertEqual(result.configuration.database, original.database)
        XCTAssertEqual(result.configuration.username, original.username)
        XCTAssertEqual(result.configuration.sslMode, original.sslMode)
        XCTAssertNil(result.password)
    }

    // MARK: 配置包

    func testBundleRoundTripAndNoPasswordField() throws {
        let configuration = ConnectionConfig(
            name: "订单库", dbType: .postgresql, host: "h", port: 5432,
            database: "d", username: "u", sslMode: .prefer, timeout: 5
        )
        let bundle = ConnectionBundle(connections: [configuration])
        let data = try bundle.encoded()
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.lowercased().contains("password"), "配置包里不该有密码字段：\(text)")

        let decoded = try ConnectionBundle.decode(from: data)
        XCTAssertEqual(decoded.connections, [configuration])
        XCTAssertEqual(decoded.formatVersion, ConnectionBundle.currentFormatVersion)
    }

    /// 版本比当前新的包**拒绝解析**（别把读不懂的字段悄悄丢掉）。
    func testBundleRefusesNewerFormat() throws {
        let newer = ConnectionBundle(formatVersion: ConnectionBundle.currentFormatVersion + 1, connections: [])
        let data = try newer.encoded()
        XCTAssertThrowsError(try ConnectionBundle.decode(from: data)) { error in
            XCTAssertEqual(error as? ConnectionBundle.BundleError, .tooNew(ConnectionBundle.currentFormatVersion + 1))
        }
    }
}
