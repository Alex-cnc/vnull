import XCTest
@testable import DoyahCore

/// 对象树的**自动展开策略**（FR-META-01）。
///
/// 为什么值得单测：这条规则决定"连上之后第一眼看到什么"。它一旦猜错，用户看到的是
/// **别人的库 / 别的 schema**，而自己那张表还是找不到 —— 比"不展开"更糟。
/// 所以边界（连不上、没权限、名字写错、多 schema 且没有 `public`）都要钉住。
final class ObjectTreeAutoExpansionTests: XCTestCase {

    /// 需求提出者实测的那一台：23 个库，连接自己的库是 `doyah_manual_test`。
    /// 要展开的只能是它 —— 展开别的库等于替用户做了一个他没做的选择。
    func testPicksConnectionDatabaseOutOfMany() {
        let databases = [
            "dbgimp", "doyah_copy_check", "doyah_er_check", "doyah_manual_test",
            "doyah_probe_left", "postgres", "template1",
        ]
        XCTAssertEqual(
            ObjectTreeAutoExpansion.database(in: databases, connectionDatabase: "doyah_manual_test"),
            "doyah_manual_test"
        )
    }

    /// 列表里没有连接自己那个库（连不上 / 没权限 / 名字写错）→ **不展开任何库**，留给人点。
    func testDoesNotGuessWhenConnectionDatabaseIsAbsent() {
        XCTAssertNil(ObjectTreeAutoExpansion.database(in: ["postgres", "template1"], connectionDatabase: "nope"))
        XCTAssertNil(ObjectTreeAutoExpansion.database(in: ["postgres"], connectionDatabase: nil))
        XCTAssertNil(ObjectTreeAutoExpansion.database(in: ["postgres"], connectionDatabase: ""))
        XCTAssertNil(ObjectTreeAutoExpansion.database(in: [], connectionDatabase: "postgres"))
    }

    /// schema：`public` 优先（PostgreSQL 的默认，也是用户建表的地方）。
    func testPrefersPublicSchema() {
        XCTAssertEqual(ObjectTreeAutoExpansion.schema(in: ["other", "public"]), "public")
        XCTAssertEqual(ObjectTreeAutoExpansion.schema(in: ["public"]), "public")
    }

    /// 只有一个 schema → 就是它（哪怕不叫 public）。
    func testSingleSchemaIsExpanded() {
        XCTAssertEqual(ObjectTreeAutoExpansion.schema(in: ["analysis"]), "analysis")
    }

    /// 多个 schema 又没有 `public` → **不猜**：猜错会把用户带到另一个 schema 里。
    func testDoesNotGuessAmongSeveralSchemas() {
        XCTAssertNil(ObjectTreeAutoExpansion.schema(in: ["a", "b"]))
        XCTAssertNil(ObjectTreeAutoExpansion.schema(in: []))
    }
}

/// **空结果不算"查过了"**（R-59，2026-09-25 需求提出者实测）。
///
/// 症状：别的客户端在库里建了表，树里一直停在「该数据库下暂无表 / 视图」；
/// 折叠再展开也不重查 —— 因为"空数组"被当成了"已加载"。
final class ObjectTreeReloadPolicyTests: XCTestCase {

    private func object(_ name: String) -> DatabaseObject {
        DatabaseObject(id: "db:\(name)", name: name, kind: .database, database: name)
    }

    func testNeverLoadedShouldLoad() {
        XCTAssertTrue(ObjectTreeReloadPolicy.shouldLoad(cached: nil, isLoading: false))
    }

    /// **这条就是缺陷本身**：空缓存也要再查一次。
    func testEmptyResultIsNotTreatedAsLoaded() {
        XCTAssertTrue(ObjectTreeReloadPolicy.shouldLoad(cached: [], isLoading: false))
    }

    /// 非空缓存算数：不再无谓地打服务端。
    func testNonEmptyCacheIsAuthoritative() {
        XCTAssertFalse(ObjectTreeReloadPolicy.shouldLoad(cached: [object("t")], isLoading: false))
    }

    /// 正在查的时候不重复发起（与原来的幂等包装同一条纪律）。
    func testInFlightIsNotDuplicated() {
        XCTAssertFalse(ObjectTreeReloadPolicy.shouldLoad(cached: nil, isLoading: true))
        XCTAssertFalse(ObjectTreeReloadPolicy.shouldLoad(cached: [], isLoading: true))
    }
}
