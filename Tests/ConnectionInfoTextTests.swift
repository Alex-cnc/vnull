import XCTest
@testable import DoyahCore

/// 上下文栏右侧「连接信息」tooltip 的文本组成（FR-CONN-12 / FR-EDIT-08）。
///
/// 这段文字有**两个随连接变的来源**（类型名来自 `DatabaseType`、分隔符来自方言），
/// 而且缺项时不能留下多余的分隔符 —— 三条都钉住。
final class ConnectionInfoTextTests: XCTestCase {

    func testFullSummaryForPostgres() {
        let text = ConnectionInfoText.summary(
            databaseType: .postgresql,
            database: "doyah_manual_test",
            username: "postgres",
            endpoint: "127.0.0.1:55433",
            language: .simplifiedChinese
        )
        XCTAssertEqual(text, "PostgreSQL · 分隔符 ; · doyah_manual_test · postgres · 127.0.0.1:55433")
    }

    /// 需求提出者问过「会随 GBase 变吗」—— 这里把答案钉住：**类型名会变**。
    func testTypeNameFollowsTheConnection() {
        let gbase = ConnectionInfoText.summary(
            databaseType: .gbase8a,
            database: "dw",
            username: "etl",
            endpoint: "10.0.0.9:5258",
            language: .simplifiedChinese
        )
        XCTAssertTrue(gbase.hasPrefix("GBase 8a · 分隔符 ;"), gbase)
        XCTAssertFalse(gbase.contains("PostgreSQL"))
    }

    /// 英文界面下连"分隔符"这个词也要跟着变（不能只有类型名是英文）。
    func testEnglishLanguageUsesEnglishLabels() {
        let text = ConnectionInfoText.summary(
            databaseType: .postgresql,
            database: "app",
            username: "u",
            endpoint: "h:1",
            language: .english
        )
        XCTAssertEqual(text, "PostgreSQL · Delimiter ; · app · u · h:1")
    }

    /// 库 / 用户还没拿到（未连接）时**跳过而不是留空槽** —— 否则会出现「· · 」这种残迹。
    func testMissingPartsDoNotLeaveEmptySlots() {
        let text = ConnectionInfoText.summary(
            databaseType: .postgresql,
            database: nil,
            username: "",
            endpoint: "",
            language: .simplifiedChinese
        )
        XCTAssertEqual(text, "PostgreSQL · 分隔符 ;")
        XCTAssertFalse(text.contains("·  ·"), text)
    }
}
