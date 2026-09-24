import XCTest
@testable import DoyahCore

/// 连接分组（FR-CONN-15）。
///
/// 两个容易做错的地方：**顺序**（分组顺序一抖动，用户刚展开的组就跑位）与
/// **老配置兼容**（不能因为新增字段就读不出旧文件）。
final class ConnectionGroupingTests: XCTestCase {

    private func connection(
        _ name: String,
        group: String? = nil,
        id: UUID = UUID()
    ) -> ConnectionConfig {
        ConnectionConfig(
            id: id,
            name: name,
            dbType: .postgresql,
            host: "127.0.0.1",
            port: 5432,
            database: "postgres",
            username: "tester",
            sslMode: .disable,
            timeout: 5,
            group: group
        )
    }

    // MARK: 配置字段

    func testConfigRoundTripCarriesGroup() throws {
        let original = connection("生产订单库", group: "生产环境")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)
        XCTAssertEqual(decoded.group, "生产环境")
        XCTAssertEqual(decoded.schemaVersion, original.schemaVersion, "纯新增可选字段不该抬高版本")
    }

    /// 老 `connections.json`（没有 group 字段）必须照常解码 —— 这是需求原文点名的验收点。
    func testOldConfigWithoutGroupDecodesAsUngrouped() throws {
        let json = """
        {"id":"D264B21B-1880-4E73-A2D0-59A3F8E4D7EC","name":"老配置","host":"127.0.0.1",
         "database":"postgres","username":"tester","schemaVersion":1}
        """
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        XCTAssertNil(decoded.group)
        XCTAssertNil(decoded.normalizedGroup)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testNormalizedGroupTreatsBlankAsUngrouped() {
        XCTAssertNil(connection("a", group: "").normalizedGroup)
        XCTAssertNil(connection("a", group: "   \n ").normalizedGroup)
        XCTAssertEqual(connection("a", group: "  生产  ").normalizedGroup, "生产")
    }

    // MARK: 分组与顺序

    func testSectionsPutUngroupedLast() {
        let sections = ConnectionGrouping.sections([
            connection("无组 A"),
            connection("测试库", group: "测试环境"),
            connection("生产库", group: "生产环境"),
            connection("无组 B")
        ])
        // 不硬编码中文顺序（那取决于 locale 的排序规则）：断言"命名组在前后未分组最后"这个语义。
        XCTAssertEqual(Set(sections.compactMap(\.group)), ["生产环境", "测试环境"])
        XCTAssertNil(sections.last?.group, "未分组永远最后")
        XCTAssertEqual(sections.last?.connections.map(\.name), ["无组 A", "无组 B"])
        XCTAssertTrue(sections.last?.isUngrouped == true)
    }

    /// 组内**保持传入顺序**（用户自己排的顺序不该被刷新打乱）。
    func testWithinGroupOrderIsPreserved() {
        let sections = ConnectionGrouping.sections([
            connection("z 库", group: "生产环境"),
            connection("a 库", group: "生产环境")
        ])
        XCTAssertEqual(sections[0].connections.map(\.name), ["z 库", "a 库"])
    }

    /// 同一组名的不同大小写写法归到一组，但**显示用用户先写的那个**。
    func testCaseInsensitiveGroupingKeepsFirstDisplayName() {
        let sections = ConnectionGrouping.sections([
            connection("一库", group: "Prod"),
            connection("二库", group: "prod")
        ])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].group, "Prod")
        XCTAssertEqual(sections[0].connections.count, 2)
    }

    /// 同一份输入两次聚合结果必须逐字一致（顺序不能依赖字典遍历）。
    func testSectionsAreDeterministic() {
        let input = [
            connection("a", group: "乙组"),
            connection("b", group: "甲组"),
            connection("c"),
            connection("d", group: "丙组")
        ]
        XCTAssertEqual(ConnectionGrouping.sections(input), ConnectionGrouping.sections(input))
    }

    func testEmptyInputGivesNoSections() {
        XCTAssertTrue(ConnectionGrouping.sections([]).isEmpty)
    }

    func testAllUngroupedGivesSingleSection() {
        let sections = ConnectionGrouping.sections([connection("a"), connection("b")])
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].group)
        XCTAssertEqual(sections[0].id, "__ungrouped__")
    }

    // MARK: 组名列表（表单下拉建议）

    func testGroupNamesAreDedupedAndSorted() {
        let names = ConnectionGrouping.groupNames([
            connection("a", group: "生产环境"),
            connection("b", group: "测试环境"),
            connection("c", group: "PROD"),
            connection("d", group: "prod"),
            connection("e")
        ])
        // 断言"去重 + 与聚合同口径有序"，不硬编码中英文混排的具体次序（那取决于 locale）
        XCTAssertEqual(Set(names.map { $0.lowercased() }), ["prod", "生产环境", "测试环境"])
        let resorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(names, resorted, "组名列表要与聚合用同一套排序口径")
        XCTAssertFalse(names.contains(ConnectionGrouping.ungroupedTitle))
    }
}
