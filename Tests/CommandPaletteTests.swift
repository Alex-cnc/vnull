import XCTest
@testable import DoyahCore

/// 命令面板的匹配与排序（FR-EDIT-25）。
///
/// 面板好不好用几乎全在这层：缩写要能命中、中文要能命中、**顺序要稳定**
/// （用户会记"按两下 ↓ 再回车"这条最省事的路径）。
final class CommandPaletteTests: XCTestCase {

    private let items: [CommandPalette.Item] = [
        .init(id: "newQuery", title: "新建查询", keywords: ["new query", "nq"], category: "查询"),
        .init(id: "execute", title: "执行", keywords: ["execute", "run"], category: "查询"),
        .init(id: "check", title: "语法检查", keywords: ["check", "explain"], category: "查询"),
        .init(id: "format", title: "格式化 SQL", keywords: ["format", "fmt"], category: "查询"),
        .init(id: "exportCSV", title: "导出 CSV", keywords: ["export", "csv"], category: "结果"),
        .init(id: "switchConnection", title: "切换连接", keywords: ["connection", "conn"], category: "连接"),
        .init(id: "openTable", title: "打开表…", keywords: ["open table", "browse"], category: "对象"),
        .init(id: "agentSQL", title: "用自然语言生成 SQL", keywords: ["agent", "nl2sql"], category: "智能体"),
    ]

    private func ids(_ query: String, limit: Int = 50) -> [String] {
        CommandPalette.search(query, in: items, limit: limit).map(\.item.id)
    }

    // MARK: 命中

    /// 空查询返回全部（面板刚打开要能看到有什么可用），且顺序稳定。
    func testEmptyQueryReturnsEverythingInOrder() {
        XCTAssertEqual(ids(""), items.map(\.id))
        XCTAssertEqual(ids("   "), items.map(\.id))
    }

    func testExactTitleComesFirst() {
        XCTAssertEqual(ids("执行").first, "execute")
        XCTAssertEqual(ids("格式化 SQL").first, "format")
    }

    /// 前缀优先于子串：输入「导」时「导出 CSV」应在前。
    func testPrefixBeatsSubstring() {
        let result = ids("导出")
        XCTAssertEqual(result.first, "exportCSV")
    }

    func testChineseSubstringMatches() {
        XCTAssertTrue(ids("语言").contains("agentSQL"), "「语言」应当命中「用自然语言生成 SQL」")
        XCTAssertTrue(ids("检查").contains("check"))
    }

    /// 英文缩写：`nq` → 新建查询（关键词）、`fmt` → 格式化。
    func testAcronymAndKeywordMatching() {
        XCTAssertEqual(ids("nq").first, "newQuery")
        XCTAssertEqual(ids("fmt").first, "format")
        XCTAssertEqual(ids("csv").first, "exportCSV")
    }

    /// 子序列：跳字输入也要有结果（否则用户会觉得"搜不到"）。
    /// 用真实能命中的例子，而不是随手编的字母（我第一版编了 `gsh`，没有任何标题含这三个字符）。
    func testSubsequenceMatching() {
        XCTAssertTrue(ids("格S").contains("format"), "「格」+「S」是「格式化 SQL」的子序列")
        XCTAssertTrue(ids("切连").contains("switchConnection"), "「切」+「连」是「切换连接」的子序列")
        // `格S` 实际命中的是**首字母缩写档**：`格` 是「格式化」的词首、`S` 是 `SQL` 的词首 ——
        // 缩写规则比子序列更贴切，所以先命中它（我第一版期望"子序列档"，又是期望写错）。
        let match = try? XCTUnwrap(CommandPalette.search("格S", in: items).first { $0.item.id == "format" })
        XCTAssertEqual(match?.score, CommandPalette.Score.acronym)
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(ids("zzzzzz").isEmpty)
    }

    /// 大小写不敏感。
    func testCaseInsensitive() {
        XCTAssertEqual(ids("FMT").first, "format")
        XCTAssertEqual(ids("Csv").first, "exportCSV")
    }

    // MARK: 排序稳定性

    /// 同分时按标题再按 id 排序 —— 不能依赖数组顺序（那是实现细节，用户看到的是"每次不一样"）。
    func testOrderIsStableForEqualScores() {
        let sameScore: [CommandPalette.Item] = [
            .init(id: "b", title: "导出 B"),
            .init(id: "a", title: "导出 A"),
            .init(id: "c", title: "导出 A"),
        ]
        XCTAssertEqual(CommandPalette.search("导出", in: sameScore).map(\.item.id), ["a", "c", "b"])

        // 打乱输入顺序，结果仍然一致
        XCTAssertEqual(CommandPalette.search("导出", in: sameScore.reversed()).map(\.item.id), ["a", "c", "b"])
    }

    func testScoreOrderingAcrossKinds() {
        let query = "格式"
        let match = CommandPalette.search(query, in: items).first
        XCTAssertEqual(match?.item.id, "format")
        // 「格式化 SQL」以「格式」**开头** → 前缀档（比子串更高）。我第一版写成"子串档"，
        // 是期望写错了 —— 实现给的档位更准。
        XCTAssertEqual(match?.score, CommandPalette.Score.prefix)
    }

    func testLimitIsRespected() {
        XCTAssertEqual(CommandPalette.search("", in: items, limit: 3).count, 3)
        XCTAssertEqual(CommandPalette.search("查询", in: items, limit: 1).count, 1)
    }

    // MARK: 高亮

    /// 高亮位置要能对上（界面据此加粗）：子串命中是连续区间。
    func testHighlightPositionsForSubstring() throws {
        let match = try XCTUnwrap(CommandPalette.search("格式", in: items).first { $0.item.id == "format" })
        XCTAssertEqual(match.highlighted, [0, 1], "「格式化 SQL」的前两个字符")

        let acronym = try XCTUnwrap(CommandPalette.search("fmt", in: items).first { $0.item.id == "format" })
        XCTAssertEqual(acronym.highlighted, [], "关键词命中时标题没有可高亮的位置")
    }

    /// 面板上要按需求列出的那几类命令**都能被搜到** —— 这是需求覆盖度的可测形式。
    func testRequiredCommandsAreReachable() {
        for (query, expected) in [
            ("新建查询", "newQuery"), ("执行", "execute"), ("检查", "check"),
            ("格式化", "format"), ("导出", "exportCSV"), ("切换连接", "switchConnection"), ("打开表", "openTable"),
        ] {
            XCTAssertEqual(ids(query).first, expected, "「\(query)」应当命中 \(expected)")
        }
    }
}
