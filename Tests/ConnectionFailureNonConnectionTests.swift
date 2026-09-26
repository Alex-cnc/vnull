import XCTest
@testable import DoyahCore

/// **驱动报错但非连接类**的中性归因（R-60，开发循环第 8 轮）。
///
/// 这一族此前一律落进 `describe(psqlError:)` 的 `default:` 分支，被说成
/// 「连接数据库失败／确认主机、端口、库名、用户名」—— 用户按这句话去查网络与口令，
/// 而真实原因常常与它们无关（用户自己取消、我们主动关页签、对端不是 PostgreSQL…）。
///
/// 这里钉住四条：
/// 1. 台账里声明为「中性归因」的**每个码都有自己的话**，且带上码名（可搜可上报）；
/// 2. 任何一句里**不许再出现**那套指错方向的措辞（「连接数据库失败」「确认主机」）；
/// 3. 表里没有的码 → 「尚未归类」，并且**明说不给方向判断**（不猜）；
/// 4. 英文界面下这些文案真的换了语言（不是只有中文一份）。
final class ConnectionFailureNonConnectionTests: XCTestCase {

    /// 那套会把用户引去查网络与口令的旧措辞 —— 一句都不许再出现（R-60 的现场就是它）。
    private let misdirectingPhrases = ["连接数据库失败", "确认主机", "服务端是否在运行"]

    // MARK: - 逐码一句自己的话

    func testDeclaredCodesAreListed() {
        XCTAssertEqual(
            ConnectionFailure.nonConnectionDriverCodes,
            [
                "clientClosedConnection", "invalidCommandTag", "listenFailed",
                "messageDecodingFailure", "poolClosed", "queryCancelled",
                "tooManyParameters", "unexpectedBackendMessage", "unlistenFailed",
            ],
            "台账与这张表要逐条对得上（门禁同口径）；改动这里就要改 Scripts/connection-failure-dispositions.json"
        )
    }

    func testEveryDeclaredCodeHasItsOwnWords() {
        let unknown = ConnectionFailure.describeNonConnection(code: "brandNewCode")
        var summaries: Set<String> = []

        for code in ConnectionFailure.nonConnectionDriverCodes {
            let described = ConnectionFailure.describeNonConnection(code: code)
            XCTAssertTrue(described.summary.contains(code), "摘要要带上码名：\(described.summary)")
            XCTAssertNotEqual(described.summary, unknown.summary, "\(code) 落到了「尚未归类」—— 表里缺它的话")
            let suggestion = described.suggestion ?? ""
            XCTAssertFalse(suggestion.isEmpty, "\(code) 没有建议")
            XCTAssertNotEqual(suggestion, unknown.suggestion, "\(code) 的建议是「尚未归类」那一句")
            XCTAssertEqual(described.code, code, "码要原样带出来")
            XCTAssertTrue(summaries.insert(described.summary).inserted, "\(code) 的摘要与别的码重复了")
        }
    }

    // MARK: - 不许指错方向

    func testNoDeclaredCodeIsToldAsAConnectionFailure() {
        var texts: [String] = []
        for code in ConnectionFailure.nonConnectionDriverCodes {
            let described = ConnectionFailure.describeNonConnection(code: code)
            texts.append(described.summary)
            if let suggestion = described.suggestion { texts.append(suggestion) }
        }
        for text in texts {
            for phrase in misdirectingPhrases {
                XCTAssertFalse(text.contains(phrase), "这一族不该出现「\(phrase)」：\(text)")
            }
        }
    }

    /// 未知码：说「尚未归类」并**明说不给方向判断**，同样不许指错方向。
    func testUnknownCodeGivesNoDirectionVerdict() {
        let described = ConnectionFailure.describeNonConnection(code: "brandNewCode")
        XCTAssertTrue(described.summary.contains("brandNewCode"), described.summary)
        XCTAssertTrue(described.summary.contains("尚未归类"), described.summary)
        let suggestion = described.suggestion ?? ""
        XCTAssertTrue(suggestion.contains("不给方向判断"), suggestion)
        for phrase in misdirectingPhrases {
            XCTAssertFalse(described.summary.contains(phrase), described.summary)
            XCTAssertFalse(suggestion.contains(phrase), suggestion)
        }
        XCTAssertEqual(described.code, "brandNewCode")
    }

    // MARK: - 不抢别的错误

    func testNonDriverErrorsAreNotClaimed() {
        struct SomeOther: Error {}
        XCTAssertNil(ConnectionFailure.describeNonConnection(SomeOther()))
        // 网络层错误由 `describeNetworkMessage` 那条线管，这里不许接过去说一遍。
        struct Wrapper: LocalizedError {
            var errorDescription: String? { "connect(2) failed: Connection refused" }
        }
        XCTAssertNil(ConnectionFailure.describeNonConnection(Wrapper()))
    }

    /// **SQLSTATE 的纪律**：带 SQLSTATE 的错误归调用方自己的路 —— 这里只接住**已知与连接无关**的
    /// 那一个（`57014` 查询被取消）。
    ///
    /// 2026-09-26 实测的形状：`pg_cancel_backend(pg_backend_pid())` 回来的是
    /// `PSQLError(code: server, serverInfo: [sqlState: 57014, message: "canceling statement due to
    /// user request", …])` —— 不接住它，界面上就会退回一句英文类型转储（改动前则是
    /// 「连接数据库失败」，那是指错方向）。
    func testServerCancelIsSpokenForButQueryErrorsAreNot() throws {
        let cancelled = try XCTUnwrap(ConnectionFailure.describeNonConnection(sqlState: "57014"))
        XCTAssertTrue(cancelled.summary.contains("57014"), cancelled.summary)
        XCTAssertTrue(cancelled.summary.contains("取消"), cancelled.summary)
        XCTAssertEqual(cancelled.code, "57014")
        for phrase in misdirectingPhrases {
            XCTAssertFalse((cancelled.suggestion ?? "").contains(phrase), cancelled.suggestion ?? "")
        }

        // 查询类 / 连接类 SQLSTATE 一律不接（各自有各自的路）
        XCTAssertNil(ConnectionFailure.describeNonConnection(sqlState: "42P01"), "表不存在是查询错误")
        XCTAssertNil(ConnectionFailure.describeNonConnection(sqlState: "42601"), "语法错误是查询错误")
        XCTAssertNil(ConnectionFailure.describeNonConnection(sqlState: "08006"), "连接类由 describe 说话")
        XCTAssertNil(ConnectionFailure.describeNonConnection(sqlState: "28P01"), "认证类由 describe 说话")
    }

    // MARK: - 真的换了语言

    func testEnglishTextIsActuallyEnglish() throws {
        func hasHan(_ text: String) -> Bool {
            text.unicodeScalars.contains { scalar in (0x4E00...0x9FFF).contains(scalar.value) }
        }

        func assertEnglish(_ described: ConnectionFailure.Description, _ label: String) {
            for text in [described.summary, described.suggestion ?? ""] {
                XCTAssertFalse(hasHan(text), "\(label) 的英文版里还有汉字：\(text)")
            }
        }

        for code in ConnectionFailure.nonConnectionDriverCodes {
            assertEnglish(ConnectionFailure.describeNonConnection(code: code, language: .english), code)
        }
        assertEnglish(ConnectionFailure.describeNonConnection(code: "brandNewCode", language: .english), "未知码")
        assertEnglish(
            try XCTUnwrap(ConnectionFailure.describeNonConnection(sqlState: "57014", language: .english)),
            "57014"
        )
    }
}
