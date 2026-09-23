import XCTest
@testable import DoyahCore

/// 慢查询排行（FR-DIAG-03）：版本差异、扩展缺失的可读提示、解析与格式化。
final class SlowQueryReportTests: XCTestCase {

    // MARK: 版本差异（这是本项最容易做错的地方）

    /// PostgreSQL 13 起把 `total_time` / `mean_time` 改名为 `*_exec_time`：
    /// 一套 SQL 打天下会在 12 或 18 上直接报列不存在。
    func testColumnNamesFollowServerVersion() {
        let modern = SlowQueryReport.query(sort: .totalTime, serverMajor: 18)
        XCTAssertTrue(modern.contains("total_exec_time AS total_millis"), modern)
        XCTAssertTrue(modern.contains("mean_exec_time AS mean_millis"), modern)
        XCTAssertTrue(modern.contains("ORDER BY total_exec_time DESC"), modern)

        let legacy = SlowQueryReport.query(sort: .totalTime, serverMajor: 12)
        XCTAssertTrue(legacy.contains("total_time AS total_millis"), legacy)
        XCTAssertTrue(legacy.contains("mean_time AS mean_millis"), legacy)
        XCTAssertFalse(legacy.contains("exec_time"), "PG 12 上没有 *_exec_time 列：\(legacy)")
        XCTAssertTrue(legacy.contains("ORDER BY total_time DESC"), legacy)
    }

    func testSortOrderingFollowsSelectedMetric() {
        XCTAssertTrue(SlowQueryReport.query(sort: .meanTime, serverMajor: 18).contains("ORDER BY mean_exec_time DESC"))
        XCTAssertTrue(SlowQueryReport.query(sort: .calls, serverMajor: 18).contains("ORDER BY calls DESC"))
        XCTAssertTrue(SlowQueryReport.query(sort: .calls, serverMajor: 12).contains("ORDER BY calls DESC"))
    }

    func testLimitIsClampedToAtLeastOne() {
        XCTAssertTrue(SlowQueryReport.query(limit: 0, serverMajor: 18).contains("LIMIT 1"))
        XCTAssertTrue(SlowQueryReport.query(limit: 50, serverMajor: 18).contains("LIMIT 50"))
    }

    /// 排行里不该出现 `pg_stat_statements` 自己的查询（那会挤掉真业务查询）。
    func testOwnQueriesAreFilteredOut() {
        XCTAssertTrue(SlowQueryReport.query(serverMajor: 18).contains("query NOT LIKE '%pg_stat_statements%'"))
    }

    // MARK: 扩展存在性

    func testExtensionInstalledDetection() {
        let columns = [ColumnMeta(id: 0, name: "extension"), ColumnMeta(id: 1, name: "relation_exists")]

        // 扩展已安装
        XCTAssertTrue(SlowQueryReport.isExtensionInstalled(QueryResult(columns: columns, rows: [["pg_stat_statements", "t"]])))
        // 没有扩展，但有同名关系（本机精简构建 + 同名视图就能走到这条 → 让 SQL 可被真跑验证）
        XCTAssertTrue(SlowQueryReport.isExtensionInstalled(QueryResult(columns: columns, rows: [[nil, "t"]])))
        // 都没有
        XCTAssertFalse(SlowQueryReport.isExtensionInstalled(QueryResult(columns: columns, rows: [[nil, "f"]])))
        XCTAssertFalse(SlowQueryReport.isExtensionInstalled(QueryResult(columns: columns, rows: [])))
        XCTAssertTrue(SlowQueryReport.extensionCheckQuery.contains("pg_extension"))
        XCTAssertTrue(SlowQueryReport.extensionCheckQuery.contains("to_regclass"),
                      "要看同名关系，否则这条 SQL 在没装扩展的环境里永远没被真跑过")
    }

    /// 缺失提示必须**说出怎么装**，而且要把"要重启"写上 ——
    /// 只 `CREATE EXTENSION` 会得到一个"装了但查不到数据"的困惑状态。
    func testMissingExtensionMessageIsActionable() {
        let message = SlowQueryReport.missingExtensionMessage
        XCTAssertTrue(message.contains("shared_preload_libraries"), message)
        XCTAssertTrue(message.contains("重启"), message)
        XCTAssertTrue(message.contains("CREATE EXTENSION"), message)
        XCTAssertTrue(message.contains("权限"), "要提醒普通用户可能没权限：\(message)")
    }

    // MARK: 解析

    private func result(_ columns: [String], _ rows: [[String?]]) -> QueryResult {
        QueryResult(
            columns: columns.enumerated().map { ColumnMeta(id: $0.offset, name: $0.element) },
            rows: rows
        )
    }

    func testParsingEntries() {
        let parsed = SlowQueryReport.entries(from: result(
            ["query", "calls", "total_millis", "mean_millis", "rows"],
            [
                ["SELECT * FROM orders WHERE id = $1", "120", "8400.5", "70.0", "120"],
                ["UPDATE t SET a = 1", "3", "900", "300", "3"],
                [nil, "1", "1", "1", "1"],
            ]
        ))
        XCTAssertEqual(parsed.count, 2, "没有查询文本的行要丢掉")
        XCTAssertEqual(parsed[0].calls, 120)
        XCTAssertEqual(parsed[0].totalMillis, 8400.5, accuracy: 0.001)
        XCTAssertEqual(parsed[0].meanMillis, 70, accuracy: 0.001)
    }

    /// 列名不敏感：换个包装查询（或别的版本）改了列名也要能解析。
    func testParsingIsColumnNameInsensitive() {
        let parsed = SlowQueryReport.entries(from: result(
            ["QUERY", "CALLS", "TOTAL_TIME", "MEAN_TIME", "ROWS"],
            [["SELECT 1", "5", "10", "2", "5"]]
        ))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].totalMillis, 10)
        XCTAssertEqual(parsed[0].meanMillis, 2)
    }

    func testMissingNumbersDefaultToZero() {
        let parsed = SlowQueryReport.entries(from: result(
            ["query", "calls", "total_millis", "mean_millis", "rows"],
            [["SELECT 1", nil, nil, nil, nil]]
        ))
        XCTAssertEqual(parsed[0].calls, 0)
        XCTAssertEqual(parsed[0].totalMillis, 0)
    }

    // MARK: 展示

    /// 长查询文本按**字符**截断（不切碎多字节字符），且截断要能看出来。
    func testQueryDisplayTruncatesByCharacters() {
        // 按**指定上限**截断：20 个字符 + 省略号，且不切碎多字节字符。
        let short = SlowQueryReport.Entry(
            query: "SELECT " + String(repeating: "鲸", count: 30),
            calls: 1, totalMillis: 1, meanMillis: 1, rows: 1
        )
        let display = short.display(maxLength: 20)
        XCTAssertEqual(display.count, 21, "20 个字符 + 省略号")
        XCTAssertTrue(display.hasSuffix("…"))

        // `isQueryTruncated` 用的是**默认上限**（160）—— 所以只有超过它才为真。
        // 我第一版拿 107 字符的用例去断言"已截断"，是期望与口径不一致（测试当场指出）。
        XCTAssertFalse(short.isQueryTruncated, "107 字符未超过默认上限 160")

        let long = SlowQueryReport.Entry(
            query: "SELECT " + String(repeating: "x", count: 400),
            calls: 1, totalMillis: 1, meanMillis: 1, rows: 1
        )
        XCTAssertTrue(long.isQueryTruncated)
        XCTAssertEqual(long.display().count, SlowQueryReport.defaultQueryDisplayLimit + 1)
    }

    /// 多行 / 多余空白压成一行（排行里一行一条才有可读性）。
    func testQueryDisplayCollapsesWhitespace() {
        let entry = SlowQueryReport.Entry(
            query: "SELECT *\n  FROM t\n   WHERE a = 1",
            calls: 1, totalMillis: 1, meanMillis: 1, rows: 1
        )
        XCTAssertEqual(entry.display(), "SELECT * FROM t WHERE a = 1")
        XCTAssertFalse(entry.isQueryTruncated)
    }

    func testDurationFormatting() {
        XCTAssertEqual(SlowQueryReport.formatDuration(millis: 12_340), "12.34 s")
        XCTAssertEqual(SlowQueryReport.formatDuration(millis: 1_500), "1.50 s")
        XCTAssertEqual(SlowQueryReport.formatDuration(millis: 850), "850 ms")
        XCTAssertEqual(SlowQueryReport.formatDuration(millis: 0.42), "0.42 ms")
    }

    func testSortDisplayNamesCoverAllCases() {
        XCTAssertEqual(SlowQueryReport.Sort.allCases.count, 3)
        XCTAssertEqual(Set(SlowQueryReport.Sort.allCases.map(\.displayName)),
                       ["总耗时", "平均耗时", "调用次数"])
    }
}
