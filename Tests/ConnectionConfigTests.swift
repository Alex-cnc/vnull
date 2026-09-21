import XCTest
@testable import PostgresClientCore

final class ConnectionConfigTests: XCTestCase {
    func testDefaultPorts() {
        XCTAssertEqual(DatabaseType.postgresql.defaultPort, 5432)
        XCTAssertEqual(DatabaseType.gbase8a.defaultPort, 5258)
    }

    func testCodableRoundTrip() throws {
        let original = ConnectionConfig(
            name: "本地 PostgreSQL",
            dbType: .postgresql,
            host: "127.0.0.1",
            database: "postgres",
            username: "postgres",
            sslMode: .disable,
            timeout: 8
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ConnectionConfig.self, from: data)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.dbType, original.dbType)
        XCTAssertEqual(restored.port, 5432)
        XCTAssertEqual(restored.sslMode, .disable)
    }

    func testValidation() {
        let invalid = ConnectionConfig(name: "", host: "", username: "")
        XCTAssertFalse(invalid.isValid)

        let valid = ConnectionConfig(
            name: "GBase",
            dbType: .gbase8a,
            host: "10.0.0.8",
            database: "test",
            username: "gbase"
        )
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.port, 5258)
    }

    // MARK: - 连接显示名（FR-CONN-14）

    func testDisplayTitleIncludesLoginUser() {
        let configuration = ConnectionConfig(
            name: "DemoPG",
            dbType: .postgresql,
            host: "192.0.2.10",
            database: "postgres",
            username: "postgres"
        )

        XCTAssertEqual(configuration.displayTitle(untitled: "未命名"), "DemoPG (postgres)")
    }

    func testDisplayTitleUsesPlaceholderWhenNameEmpty() {
        let configuration = ConnectionConfig(
            name: "   ",
            dbType: .postgresql,
            host: "127.0.0.1",
            database: "postgres",
            username: "alex"
        )

        XCTAssertEqual(configuration.displayTitle(untitled: "未命名"), "未命名 (alex)")
    }

    func testDisplayTitleWithoutUserHasNoEmptyParentheses() {
        let configuration = ConnectionConfig(
            name: "DemoPG",
            dbType: .postgresql,
            host: "127.0.0.1",
            database: "postgres",
            username: ""
        )

        XCTAssertEqual(configuration.displayTitle(untitled: "未命名"), "DemoPG")
    }
}
