import XCTest
@testable import DoyahCore

/// 全库对象搜索（FR-META-12）：一次元数据查询、客户端匹配排序。
final class ObjectSearchTests: XCTestCase {

    private let hits: [ObjectSearch.Hit] = [
        .init(kind: .table, schema: "public", name: "orders", detail: "BASE TABLE"),
        .init(kind: .table, schema: "public", name: "order_items", detail: "BASE TABLE"),
        .init(kind: .view, schema: "reporting", name: "order_summary", detail: "VIEW"),
        .init(kind: .column, schema: "public", name: "orders.email", detail: "text"),
        .init(kind: .column, schema: "public", name: "customers.email", detail: "text"),
        .init(kind: .function, schema: "public", name: "order_total", detail: "integer"),
    ]

    private func names(_ query: String, limit: Int = 50) -> [String] {
        ObjectSearch.search(query, in: hits, limit: limit).map(\.hit.name)
    }

    // MARK: 查询

    /// **一次查询**取回四类对象（不是每类各查一次）。
    func testQueryIsASingleStatementCoveringAllKinds() throws {
        let sql = try XCTUnwrap(ObjectSearch.query())
        XCTAssertEqual(sql.components(separatedBy: "UNION ALL").count, 3, "四段用三个 UNION ALL 连起来")
        for marker in ["information_schema.tables", "information_schema.columns", "pg_proc", "pg_get_function_arguments"] {
            XCTAssertTrue(sql.contains(marker), "缺少 \(marker)")
        }
        XCTAssertTrue(sql.contains("LIMIT 10000"), "必须带 R-11 的 10,000 行上限")
        // 系统 schema 的**排除条件本身**当然要出现 `'pg_catalog'` —— 我第一版写成
        // "不该包含 pg_catalog"，是断言写反了。正确的断言是"排除条件在三段里都在"。
        let exclusion = "NOT IN ('pg_catalog', 'information_schema')"
        XCTAssertGreaterThanOrEqual(
            sql.components(separatedBy: exclusion).count - 1, 2,
            "tables 与 columns 两段都要排除系统 schema"
        )
    }

    /// 指定 schema 时只搜它（用户已经缩小范围，没必要扫全库）。
    func testQueryHonoursSchemaFilter() throws {
        let sql = try XCTUnwrap(ObjectSearch.query(schema: "reporting", limit: 100))
        XCTAssertTrue(sql.contains("t.table_schema = 'reporting'"), sql)
        XCTAssertTrue(sql.contains("c.table_schema = 'reporting'"))
        XCTAssertTrue(sql.contains("n.nspname = 'reporting'"))
        XCTAssertTrue(sql.contains("LIMIT 100"))
    }

    func testSchemaLiteralIsEscaped() throws {
        let sql = try XCTUnwrap(ObjectSearch.query(schema: "we'ird"))
        XCTAssertTrue(sql.contains("'we''ird'"), "单引号要双写，否则是一条语法错误的查询")
    }

    // MARK: 解析

    func testParsingHits() {
        let result = QueryResult(
            columns: [ColumnMeta(id: 0, name: "kind"), ColumnMeta(id: 1, name: "schema_name"),
                      ColumnMeta(id: 2, name: "object_name"), ColumnMeta(id: 3, name: "detail")],
            rows: [
                ["view", "reporting", "order_summary", "VIEW"],
                ["table", "public", "orders", "BASE TABLE"],
                ["column", "public", "orders.email", "text"],
                ["function", "public", "order_total", "integer"],
                [nil, "public", "没有类型要丢掉", nil],
            ]
        )
        let parsed = ObjectSearch.hits(from: result)
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(parsed.map(\.kind), [.view, .table, .column, .function])
        XCTAssertEqual(parsed[0].qualifiedName, "reporting.order_summary")
    }

    // MARK: 匹配

    /// 空查询返回空：全库对象可能上万条，列前 N 条既没用又误导。
    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(ObjectSearch.search("", in: hits).isEmpty)
        XCTAssertTrue(ObjectSearch.search("   ", in: hits).isEmpty)
    }

    func testExactNameComesFirst() {
        XCTAssertEqual(names("orders").first, "orders")
    }

    /// 前缀优先于子串：`order` → `orders` / `order_items` 在前，`order_total`（函数）在后。
    func testPrefixBeatsSubstringAndKindPriorityApplies() {
        let result = names("order")
        XCTAssertEqual(result.prefix(2), ["order_items", "orders"], "同为前缀档时按名称排")
        XCTAssertTrue(result.contains("order_summary"))
    }

    /// 列命中的名称是 `表.列`：搜 `email` 应当同时命中两张表的列。
    func testColumnSearchBySuffix() {
        let result = names("email")
        XCTAssertEqual(Set(result), ["customers.email", "orders.email"])
    }

    /// 点号后的词首优先于中间子串。
    func testWordPrefixAfterDotIsPreferred() {
        let localHits: [ObjectSearch.Hit] = [
            .init(kind: .column, schema: "public", name: "t.xemailx"),   // 中间子串
            .init(kind: .column, schema: "public", name: "t.email"),     // 点后词首
        ]
        XCTAssertEqual(ObjectSearch.search("email", in: localHits).first?.hit.name, "t.email")
    }

    /// 类型优先级：分值相同时 表 > 视图 > 列 > 函数。
    func testKindPriorityBreaksTies() {
        let sameScore: [ObjectSearch.Hit] = [
            .init(kind: .function, schema: "s", name: "abcd"),
            .init(kind: .column, schema: "s", name: "abcd"),
            .init(kind: .view, schema: "s", name: "abcd"),
            .init(kind: .table, schema: "s", name: "abcd"),
        ]
        XCTAssertEqual(
            ObjectSearch.search("abcd", in: sameScore).map(\.hit.kind),
            [.table, .view, .column, .function]
        )
    }

    /// 排序稳定：打乱输入顺序，结果一致。
    func testOrderIsStableRegardlessOfInputOrder() {
        XCTAssertEqual(names("order"), ObjectSearch.search("order", in: hits.reversed()).map(\.hit.name))
    }

    func testSubsequenceMatching() {
        XCTAssertTrue(names("oim").contains("order_items"), "`oim` 是 order_items 的子序列")
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(names("zzzzz").isEmpty)
    }

    func testLimitIsRespected() {
        XCTAssertEqual(ObjectSearch.search("order", in: hits, limit: 2).count, 2)
    }

    /// 高亮位置对得上（界面据此加粗）。
    func testHighlightPositions() throws {
        let match = try XCTUnwrap(ObjectSearch.search("orders", in: hits).first { $0.hit.name == "orders" })
        XCTAssertEqual(match.highlighted, [0, 1, 2, 3, 4, 5])

        let suffix = try XCTUnwrap(ObjectSearch.search("email", in: hits).first { $0.hit.name == "orders.email" })
        XCTAssertEqual(suffix.highlighted, [7, 8, 9, 10, 11], "`orders.email` 里 email 从第 7 个字符开始")
    }

    // MARK: 结果快照（Outcome）

    /// 空关键词：不列结果，但"在多少个对象里搜"仍要如实给出 ——
    /// 界面据此显示"在 N 个对象里没搜到"，而不是假装库里空空如也。
    func testOutcomeWithEmptyKeywordKeepsTotalHits() {
        let outcome = ObjectSearch.outcome(keyword: "   ", in: hits)
        XCTAssertTrue(outcome.matches.isEmpty)
        XCTAssertEqual(outcome.totalHits, hits.count)
        XCTAssertFalse(outcome.isTruncated)
    }

    /// 元数据行数到顶 → 标出"可能不完整"，不假装搜遍了全库。
    func testOutcomeMarksTruncationAtMetadataLimit() {
        let truncated = ObjectSearch.outcome(keyword: "order", in: hits, metadataLimit: hits.count)
        XCTAssertTrue(truncated.isTruncated, "行数 **等于**上限也算到顶")

        let abundant = ObjectSearch.outcome(keyword: "order", in: hits, metadataLimit: hits.count + 1)
        XCTAssertFalse(abundant.isTruncated)
    }

    /// 命中数按 `limit` 截断，但 `totalHits` 说的是**过滤前**的元数据总数。
    func testOutcomeTotalHitsIsPreFilterCount() {
        let outcome = ObjectSearch.outcome(keyword: "order", in: hits, limit: 2)
        XCTAssertEqual(outcome.matches.count, 2)
        XCTAssertEqual(outcome.totalHits, hits.count)
    }

    /// 排序沿用 `search` 的稳定顺序：打乱输入顺序，快照里的命中次序不变。
    func testOutcomeKeepsSearchOrder() {
        let forward = ObjectSearch.outcome(keyword: "order", in: hits)
        let reversed = ObjectSearch.outcome(keyword: "order", in: hits.reversed())
        XCTAssertEqual(forward.matches, reversed.matches)
        XCTAssertEqual(forward.matches, ObjectSearch.search("order", in: hits))
    }
}
