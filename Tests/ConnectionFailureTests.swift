import XCTest
@testable import DoyahCore

/// 连接失败的可读化（R-46 / FR-META-10）：SQLSTATE 与网络层错误串 → 人话 + 建议 + 错误码。
///
/// 这里钉住两条纪律：
/// 1. **不丢信息**：`code` 与原始串要留着（排查时"到底是哪个码"才是关键）；
/// 2. **不抢别的错误**：SQL 类错误（例如 42P01 表不存在）**不能**被说成连接问题 ——
///    把"表名写错"翻译成"网络不通"会把排查带偏。
final class ConnectionFailureTests: XCTestCase {

    private let target = ConnectionFailure.Target(host: "db.internal", port: 5432, database: "orders", username: "app")

    // MARK: - SQLSTATE

    func testAuthenticationFailure() throws {
        let description = try XCTUnwrap(
            ConnectionFailure.describe(sqlState: "28P01", message: "password authentication failed", target: target)
        )
        XCTAssertTrue(description.summary.contains("认证失败"), description.summary)
        XCTAssertTrue(description.summary.contains("db.internal:5432/orders"), "要带上目标，跨库时才知道是哪个")
        XCTAssertNotNil(description.suggestion)
    }

    func testMissingDatabase() throws {
        let description = try XCTUnwrap(ConnectionFailure.describe(sqlState: "3D000", message: "", target: target))
        XCTAssertTrue(description.summary.contains("orders"), description.summary)
        XCTAssertTrue(description.summary.contains("不存在"))
    }

    func testConnectionSlotsExhaustedAndStartingUp() throws {
        XCTAssertTrue(try XCTUnwrap(ConnectionFailure.describe(sqlState: "53300", message: "", target: nil)).summary.contains("连接数"))
        XCTAssertTrue(try XCTUnwrap(ConnectionFailure.describe(sqlState: "57P03", message: "", target: nil)).summary.contains("启动"))
    }

    func testPermissionDenied() throws {
        let description = try XCTUnwrap(ConnectionFailure.describe(sqlState: "42501", message: "", target: nil))
        XCTAssertTrue(description.summary.contains("权限不足"))
    }

    /// **关键负例**：表不存在（42P01）不是连接问题，映射必须让路。
    func testQueryErrorsAreNotClaimedAsConnectionFailures() {
        XCTAssertNil(ConnectionFailure.describe(sqlState: "42P01", message: "relation \"x\" does not exist"))
        XCTAssertNil(ConnectionFailure.describe(sqlState: "42601", message: "syntax error"))
    }

    func testUnknownZeroEightStateStillMapsAsConnectionProblem() throws {
        let description = try XCTUnwrap(ConnectionFailure.describe(sqlState: "08099", message: "", target: nil))
        XCTAssertTrue(description.summary.contains("连接"), description.summary)
        XCTAssertTrue(description.summary.contains("08099"), "未知码要原样带出来")
    }

    // MARK: - 网络层错误串

    func testNetworkMessagesAreTranslated() throws {
        let cases: [(String, String)] = [
            ("Connection refused", "拒绝"),
            ("nodename nor servname provided, or not known", "解析"),
            ("Connection timed out", "超时"),
            ("Network is unreachable", "不可达"),
            ("Connection reset by peer", "重置"),
            ("SSL handshake failed", "SSL"),
        ]
        for (raw, expected) in cases {
            let description = try XCTUnwrap(
                ConnectionFailure.describeNetworkMessage(raw, target: target),
                "这句话没被识别：\(raw)"
            )
            XCTAssertTrue(description.summary.contains(expected), "\(raw) → \(description.summary)")
            XCTAssertTrue(description.summary.contains("db.internal:5432"), "要带目标：\(description.summary)")
        }
    }

    func testUnrelatedMessageIsNotClaimed() {
        XCTAssertNil(ConnectionFailure.describeNetworkMessage("syntax error at or near \"select\""))
        XCTAssertNil(ConnectionFailure.describeNetworkMessage(""))
    }

    // MARK: - 整体入口

    func testUnrelatedErrorReturnsNil() {
        struct SomeOther: Error {}
        XCTAssertNil(ConnectionFailure.describe(SomeOther()))
    }

    /// 剥掉驱动外壳后仍是网络问题：整个入口也要能识别（NIO 会把 POSIX 串包在 underlying 里）。
    func testErrorWrappedInAnotherErrorIsStillRecognized() {
        struct Wrapper: LocalizedError {
            var errorDescription: String? { "connect(2) failed: Connection refused" }
        }
        let description = ConnectionFailure.describe(Wrapper(), target: target)
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.summary.contains("拒绝") ?? false)
    }

    func testFullTextCarriesSuggestionAndCode() {
        let description = ConnectionFailure.Description(
            summary: "连不上",
            suggestion: "检查服务",
            code: "08006",
            technicalDetail: "PSQLError(...)"
        )
        XCTAssertEqual(description.fullText, "连不上\n建议：检查服务\n错误码：08006")
    }

    // MARK: 「服务端在要口令吗」（无口令认证的库能不能连）

    /// 认证类 SQLSTATE 才算「要口令」；别的失败（库不存在 / 表不存在 / 权限）**不能**被认成要口令，
    /// 否则用户会拿到一句误导的「缺少口令」。
    func testRequiresPasswordOnlyForAuthSQLStates() {
        XCTAssertTrue(ConnectionFailure.requiresPassword(sqlState: "28P01"))
        XCTAssertTrue(ConnectionFailure.requiresPassword(sqlState: "28000"))
        XCTAssertFalse(ConnectionFailure.requiresPassword(sqlState: "3D000"), "库不存在不是要口令")
        XCTAssertFalse(ConnectionFailure.requiresPassword(sqlState: "42P01"))
        XCTAssertFalse(ConnectionFailure.requiresPassword(sqlState: nil))
    }

    /// 不是 PSQLError（网络层 / 包装错误）时一律 false：这些情况下的「缺少口令」是误报。
    func testRequiresPasswordIsFalseForNonDriverErrors() {
        struct Wrapper: LocalizedError {
            var errorDescription: String? { "connect(2) failed: Connection refused" }
        }
        XCTAssertFalse(ConnectionFailure.requiresPassword(Wrapper()))
    }
}
