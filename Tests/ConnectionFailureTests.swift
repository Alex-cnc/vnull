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

/// **pg_hba.conf 拒绝** 与 **乱码服务端消息**（2026-09-25 需求提出者实测的两处）。
///
/// 报的原话：`连接失败：未能完成操作。（PostgresNIO.PSQLError错误1。）` +
/// 技术细节里一串 `û���������� "192.168.5.223" … no encryption … pg_hba.conf`。
///
/// 两件事都要修：① 28000 不许一律说成"口令不对"（他的口令没变，是服务端没放行本机）；
/// ② 服务端消息是 GBK 字节被当 UTF-8 解出来的，中文读不出来 —— 至少要把能懂的 ASCII 部分
/// 捞出来，并**如实说明**中文为什么看不见。
final class ConnectionFailurePGHBATests: XCTestCase {

    /// 真实抓到的那句（乱码原样，含 U+FFFD）。
    private let garbled = "û���������� \"192.168.5.223\", �û� \"zxvmax\", ���ݿ� \"zxvmax\", no encryption �� pg_hba.conf ��¼"

    private let target = ConnectionFailure.Target(
        host: "192.168.5.217", port: 5432, database: "zxvmax", username: "zxvmax"
    )

    /// 28000 + `pg_hba.conf` → 说清是**服务端规则**问题，并给一条能照抄的 pg_hba 记录。
    func testPGHBARejectionIsNotReportedAsWrongPassword() throws {
        let described = try XCTUnwrap(
            ConnectionFailure.describe(sqlState: "28000", message: garbled, target: target)
        )
        XCTAssertTrue(described.summary.contains("pg_hba.conf"), described.summary)
        XCTAssertFalse(described.summary.contains("口令"), "不许把它说成口令问题：\(described.summary)")
        let suggestion = try XCTUnwrap(described.suggestion)
        // 提取到服务端视角的客户端地址 —— 建议里要能直接照抄
        XCTAssertTrue(suggestion.contains("192.168.5.223/32"), suggestion)
        XCTAssertTrue(suggestion.contains("zxvmax"), suggestion)
        // 明文连接要给"改客户端 SSL 模式"这条备选路径
        XCTAssertTrue(suggestion.contains("no encryption") || suggestion.contains("不加密"), suggestion)
        XCTAssertEqual(described.code, "28000")
    }

    /// 加密连接被拒时，规则要用 `hostssl`（别让人去加一条 `host` 然后还是连不上）。
    func testPGHBARejectionMentionsHostsslWhenEncrypted() throws {
        let message = "no pg_hba.conf entry for host \"10.0.0.5\", user \"u\", database \"d\", SSL encryption"
        let described = try XCTUnwrap(
            ConnectionFailure.describe(sqlState: "28000", message: message, target: nil)
        )
        XCTAssertTrue(try XCTUnwrap(described.suggestion).contains("hostssl"))
    }

    /// 真正的口令错误（消息里没有 pg_hba）仍走原来那条。
    func testPasswordFailureKeepsItsOwnMessage() throws {
        let described = try XCTUnwrap(
            ConnectionFailure.describe(
                sqlState: "28P01",
                message: "password authentication failed for user \"u\"",
                target: target
            )
        )
        XCTAssertTrue(described.summary.contains("认证失败"), described.summary)
        XCTAssertFalse(described.summary.contains("pg_hba"), described.summary)
    }

    /// 乱码消息：抽出能看懂的 ASCII，并明说中文读不出来（**不假装修好了**）。
    func testGarbledServerTextKeepsReadablePartsAndSaysWhy() {
        let readable = ConnectionFailure.readableServerText(garbled)
        XCTAssertTrue(readable.contains("192.168.5.223"), readable)
        XCTAssertTrue(readable.contains("zxvmax"), readable)
        XCTAssertTrue(readable.contains("no encryption"), readable)
        XCTAssertTrue(readable.contains("pg_hba.conf"), readable)
        XCTAssertTrue(readable.contains("非 UTF-8"), readable)
        XCTAssertFalse(readable.contains("\u{FFFD}"), "不该把替换字符原样留在给人看的文本里")
    }

    /// 干净消息**原样返回** —— 不许给正常文案套一层"乱码"的帽子。
    func testCleanServerTextIsUntouched() {
        let clean = "relation \"t\" does not exist"
        XCTAssertEqual(ConnectionFailure.readableServerText(clean), clean)
        XCTAssertEqual(ConnectionFailure.readableServerText("  "), "")
    }
}
