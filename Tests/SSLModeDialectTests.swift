import XCTest
@testable import DoyahCore

/// SSL 模式**按方言收窄**（R-53）：2026-09-25 界面实测「MySQL 连接上出现了 PG 专属的 Allow」。
///
/// 这条缺陷的要害不是"多了一个选项"，而是**标签与行为不一致**：
/// `MySQLService.makeTLSConfiguration()` 把 `.allow` 与 `.prefer` / `.require` 放在同一分支
/// （加密但不校验证书），所以 MySQL 上选 `Allow` 实际做的是 `Require`。
/// 因此这里钉三件事：① 清单按方言分开；② 名字按方言分开（`verify-full` ↔ `VERIFY_IDENTITY`）；
/// ③ 老配置里的越界值会被收敛**并报告**（不静默改）。
final class SSLModeDialectTests: XCTestCase {

    /// PostgreSQL 六个模式齐全 —— 收窄不能把 PG 自己也削了。
    func testPostgreSQLKeepsEveryMode() {
        XCTAssertEqual(
            DatabaseType.postgresql.sslModes,
            [.disable, .allow, .prefer, .require, .verifyCA, .verifyFull]
        )
        XCTAssertEqual(DatabaseType.postgresql.sslModes.count, SSLMode.allCases.count)
    }

    /// MySQL / GBase 没有 `allow`：那是 PostgreSQL 独有的模式。
    func testMySQLFamilyHasNoAllowMode() {
        for type in [DatabaseType.mysql, .gbase8a] {
            XCTAssertFalse(type.sslModes.contains(.allow), "\(type.rawValue) 不该出现 PG 专属的 allow")
            XCTAssertFalse(type.supports(.allow))
            XCTAssertEqual(
                type.sslModes,
                [.disable, .prefer, .require, .verifyCA, .verifyFull],
                "\(type.rawValue) 的支持清单变了 —— 变了就要同时改这条测试与界面文案"
            )
        }
    }

    /// **每个方言的默认值必须在自己的清单里**：否则 Picker 的选中值不在列表里，
    /// 界面会显示成一个空白选项（那种"选了个不存在的模式"的 bug 最难查）。
    func testDefaultModeIsAlwaysInItsOwnList() {
        for type in DatabaseType.allCases {
            XCTAssertTrue(
                type.sslModes.contains(type.defaultSSLMode),
                "\(type.rawValue) 的默认 SSL 模式 \(type.defaultSSLMode.rawValue) 不在它的支持清单里"
            )
            XCTAssertEqual(type.sslModes.first, .disable, "清单第一项应当是 Disable（关闭在前，最保守）")
        }
    }

    /// 清单里不能有重复项（Picker 的 id 是 rawValue，重复会让 SwiftUI 抱怨并画错）。
    func testListsHaveNoDuplicates() {
        for type in DatabaseType.allCases {
            XCTAssertEqual(type.sslModes.count, Set(type.sslModes).count, "\(type.rawValue) 的清单有重复项")
        }
    }

    /// 同一个枚举、两个名字：PostgreSQL 叫 `verify-full`，MySQL 叫 `VERIFY_IDENTITY`。
    func testVerifyFullIsNamedPerDialect() {
        XCTAssertEqual(SSLMode.verifyFull.displayName(for: .postgresql), "Verify Full")
        XCTAssertEqual(SSLMode.verifyFull.displayName(for: .mysql), "Verify Identity")
        XCTAssertEqual(SSLMode.verifyFull.displayName(for: .gbase8a), "Verify Identity")
        // 其余名字与方言无关，不许因为"顺手"改掉
        for mode in [SSLMode.disable, .allow, .prefer, .require, .verifyCA] {
            for type in DatabaseType.allCases {
                XCTAssertEqual(mode.displayName(for: type), mode.displayName)
            }
        }
    }

    /// 收敛：越界的值改成方言默认值，**并说"改过"**。
    func testNormalizingReportsWhetherItChanged() {
        let adjusted = DatabaseType.mysql.normalizedSSLMode(.allow)
        XCTAssertEqual(adjusted.mode, .prefer)
        XCTAssertTrue(adjusted.didChange, "改过就得报告 —— 否则用户以为是自己记错了")

        let untouched = DatabaseType.mysql.normalizedSSLMode(.require)
        XCTAssertEqual(untouched.mode, .require)
        XCTAssertFalse(untouched.didChange)

        // PostgreSQL 自己支持 allow，不许把它收敛掉
        let pgAllow = DatabaseType.postgresql.normalizedSSLMode(.allow)
        XCTAssertEqual(pgAllow.mode, .allow)
        XCTAssertFalse(pgAllow.didChange)
    }

    /// GBase 的默认值是 `disable`：收敛到默认值时要收敛成**它自己的**默认值，不是 MySQL 的。
    func testNormalizationUsesEachDialectOwnDefault() {
        XCTAssertEqual(DatabaseType.gbase8a.normalizedSSLMode(.allow).mode, .disable)
        XCTAssertEqual(DatabaseType.mysql.normalizedSSLMode(.allow).mode, .prefer)
    }
}

/// 数据库节点的**空态文案**按"有没有 schema 层"选（2026-09-25 需求提出者实测）。
///
/// 症状：在 MySQL 上打开一个空库，树里写「该数据库下暂无 schema」——
/// 而 MySQL **根本没有 schema 概念**（库即 schema），这句话会让用户以为是自己建错了。
final class DatabaseNodeEmptyTextTests: XCTestCase {

    func testSchemaLessDialectsSayTablesNotSchemas() {
        XCTAssertEqual(DatabaseType.mysql.databaseNodeEmptyKey, .treeEmptyDatabaseGBase)
        XCTAssertEqual(DatabaseType.gbase8a.databaseNodeEmptyKey, .treeEmptyDatabaseGBase)
    }

    func testPostgreSQLStillTalksAboutSchemas() {
        XCTAssertEqual(DatabaseType.postgresql.databaseNodeEmptyKey, .treeEmptyDatabase)
    }

    /// 判据是"有没有 schema 层"这件事本身（`defaultSchema`），不是逐个方言特判 ——
    /// 这样将来加一个没有 schema 层的方言，空态文案自动就是对的。
    func testRuleFollowsSchemaLayerCapability() {
        for type in DatabaseType.allCases {
            let expected: LKey = type.defaultSchema == nil ? .treeEmptyDatabaseGBase : .treeEmptyDatabase
            XCTAssertEqual(type.databaseNodeEmptyKey, expected, type.rawValue)
        }
    }
}

/// 空态文案的**方言来源**（2026-09-25 需求提出者两次报同一幕：MySQL 上点开空库，
/// 却写着「该数据库下暂无 schema」）。
///
/// 结构原因：文案原先按 `appState.selectedConnection?.dbType` 选，而**首连 / 切连接的瞬间，
/// "选中的连接"与"树上这份数据"可以不是同一件事** —— 于是用了另一个连接的方言说话。
/// 修法是在加载这份树时把方言记下来（`ObjectTreeView.treeDatabaseType`），文案只认它。
/// 这里钉住 Core 侧那条判据与三种可能的输入。
final class DatabaseNodeEmptyKeySourceTests: XCTestCase {

    /// 方言已知：按"有没有 schema 层"给话（MySQL / GBase 说表，PG 说 schema）。
    func testKnownDialects() {
        XCTAssertEqual(DatabaseType.mysql.databaseNodeEmptyKey, .treeEmptyDatabaseGBase)
        XCTAssertEqual(DatabaseType.gbase8a.databaseNodeEmptyKey, .treeEmptyDatabaseGBase)
        XCTAssertEqual(DatabaseType.postgresql.databaseNodeEmptyKey, .treeEmptyDatabase)
    }

    /// **方言未知时不许冒充 PostgreSQL**：兜底那句话里不能出现 "schema"。
    func testUnknownDialectDoesNotPretendToBePostgreSQL() {
        let zh = LocalizedStrings.text(.treeEmptyDatabaseUnknown, language: .simplifiedChinese)
        let en = LocalizedStrings.text(.treeEmptyDatabaseUnknown, language: .english)
        XCTAssertFalse(zh.contains("schema"), zh)
        XCTAssertFalse(en.lowercased().contains("schema"), en)
        XCTAssertNotEqual(zh, en, "中英文一样等于没翻译")
    }

    /// 三句话必须**互不相同** —— 否则"改对了"与"改错了"在界面上分不出来。
    func testThreeEmptyTextsAreDistinct() {
        let keys: [LKey] = [.treeEmptyDatabase, .treeEmptyDatabaseGBase, .treeEmptyDatabaseUnknown]
        let zh = keys.map { LocalizedStrings.text($0, language: .simplifiedChinese) }
        XCTAssertEqual(Set(zh).count, keys.count, "\(zh)")
    }
}
