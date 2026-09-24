import XCTest
@testable import DoyahCore

/// 数据库统计指标（FR-DIAG-04）。
///
/// 这一项最容易做错的是**比率的空值语义**：刚建的库没有任何扫描/访问，
/// "命中率"没有定义 —— 显示成 0% 会让人以为"索引完全没被用上"，那是误导。
final class DatabaseStatsTests: XCTestCase {

    private func result(_ columns: [String], _ rows: [[String?]]) -> QueryResult {
        QueryResult(
            columns: columns.enumerated().map { ColumnMeta(id: $0.offset, name: $0.element) },
            rows: rows
        )
    }

    // MARK: 表大小

    func testTableSizesAreSortedAndLimited() {
        let sizes = DatabaseStats.tableSizes(
            from: result(["name", "bytes"], [
                ["public.small", "1024"],
                ["public.big", "10485760"],
                ["public.mid", "2048"]
            ]),
            limit: 2
        )
        XCTAssertEqual(sizes.map(\.name), ["public.big", "public.mid"], "按大小降序并截断")
        XCTAssertEqual(sizes[0].displaySize, "10.0 MB")
    }

    /// 大小相同时按名字升序（稳定）—— 否则面板每次刷新顺序都可能变。
    func testTableSizesTieBreaksByName() {
        let sizes = DatabaseStats.tableSizes(
            from: result(["name", "bytes"], [["b", "100"], ["a", "100"]]),
            limit: 10
        )
        XCTAssertEqual(sizes.map(\.name), ["a", "b"])
    }

    func testTableSizesToleratesMissingColumns() {
        // 列名不同（别名写成 table/size）、缺列、非数字都不该崩
        let sizes = DatabaseStats.tableSizes(from: result(["table", "size"], [["t", nil], ["u", "abc"]]))
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(sizes.map(\.bytes), [0, 0])
    }

    // MARK: 索引命中率

    func testIndexHitRatioMath() {
        let scans = DatabaseStats.tableScans(
            from: result(["name", "seq_scan", "idx_scan"], [["t", "30", "70"]]),
            limit: 5
        )
        XCTAssertEqual(scans[0].indexHitRatio ?? 0, 0.7, accuracy: 0.0001)
        XCTAssertEqual(scans[0].displayRatio, "70.0%")
    }

    /// **总扫描为 0 → 没有定义，不是 0%**（这是本项最容易做错的口径）。
    func testIndexHitRatioIsNilWithoutScans() {
        let scans = DatabaseStats.tableScans(
            from: result(["name", "seq_scan", "idx_scan"], [["t", "0", "0"]]),
            limit: 5
        )
        XCTAssertNil(scans[0].indexHitRatio)
        XCTAssertEqual(scans[0].displayRatio, "无扫描数据")
    }

    func testTableScansOrderIsStable() {
        let scans = DatabaseStats.tableScans(
            from: result(["name", "seq_scan", "idx_scan"], [
                ["b", "0", "0"],
                ["a", "0", "0"],
                ["busy", "5", "5"]
            ]),
            limit: 5
        )
        XCTAssertEqual(scans.map(\.name), ["busy", "a", "b"], "扫描多的在前，其余按名字")
    }

    // MARK: 连接数

    func testConnectionSummaryGroupsByState() {
        let summary = DatabaseStats.connections(
            from: result(["state", "count"], [["active", "2"], ["idle", "3"], ["active", "1"]])
        )
        XCTAssertEqual(summary.total, 6)
        XCTAssertEqual(summary.byState["active"], 3)
        XCTAssertEqual(summary.ordered.map(\.state), ["active", "idle"], "顺序稳定")
    }

    // MARK: 缓存命中率

    func testCacheHitRatioMath() {
        let hit = DatabaseStats.cacheHit(from: result(["hits", "reads"], [["990", "10"]]))
        XCTAssertEqual(hit?.ratio ?? 0, 0.99, accuracy: 0.0001)
        XCTAssertEqual(hit?.displayRatio, "99.00%")
    }

    func testCacheHitIsNilWithoutAccess() {
        let hit = DatabaseStats.cacheHit(from: result(["hits", "reads"], [["0", "0"]]))
        XCTAssertNil(hit?.ratio)
        XCTAssertEqual(hit?.displayRatio, "无访问数据")
    }

    func testCacheHitFromEmptyResultIsNil() {
        XCTAssertNil(DatabaseStats.cacheHit(from: result(["hits", "reads"], [])))
    }

    // MARK: 方言能力

    /// 统计指标是**方言能力**：PG 有查询，别的方言明确不支持（null → 界面说人话）。
    func testStatsQueriesAreDialectCapability() {
        let postgres = PostgresDialect()
        for metric in DatabaseStats.Metric.allCases {
            XCTAssertNotNil(postgres.databaseStatsQuery(metric, limit: 5), metric.rawValue)
        }
        XCTAssertNil(GBaseDialect().databaseStatsQuery(.tableSizes, limit: 5))
    }

    /// 四类指标只依赖 PG 12 起就有的视图 —— 需求原文点名"按版本兼容"。
    /// 这里钉住**不出现 `pg_stat_io`**（那是 16+）。
    func testStatsQueriesAvoidNewerViews() {
        let dialect = PostgresDialect()
        for metric in DatabaseStats.Metric.allCases {
            let sql = dialect.databaseStatsQuery(metric, limit: 5) ?? ""
            XCTAssertFalse(sql.contains("pg_stat_io"), "不该用 16+ 的视图：\(sql)")
        }
    }

    func testByteFormatting() {
        XCTAssertEqual(DatabaseStats.formatBytes(0), "0 B")
        XCTAssertEqual(DatabaseStats.formatBytes(1536), "1.5 KB")
        XCTAssertEqual(DatabaseStats.formatBytes(1_073_741_824), "1.0 GB")
    }

    // MARK: 报告组装（FR-DIAG-04 的界面面板走它）

    func testReportAssemblesAllFourMetrics() {
        let report = DatabaseStats.report(
            tableSizes: result(["name", "bytes"], [["public.orders", "2048"]]),
            tableScans: result(["name", "seq_scan", "idx_scan"], [["public.orders", "10", "90"]]),
            connections: result(["state", "count"], [["active", "3"]]),
            cacheHit: result(["hits", "reads"], [["990", "10"]]),
            limit: 5
        )
        XCTAssertTrue(report.isSupported)
        XCTAssertEqual(report.tableSizes.map(\.name), ["public.orders"])
        XCTAssertEqual(report.tableScans.count, 1)
        XCTAssertEqual(report.connections.byState["active"], 3)
        XCTAssertEqual(report.cacheHit?.hits, 990)
    }

    /// 只拿到一部分也要出报告 —— 少一类不该把整块面板判成"不支持"。
    func testReportToleratesPartialMetrics() {
        let report = DatabaseStats.report(
            tableSizes: nil,
            tableScans: nil,
            connections: result(["state", "count"], [["idle", "2"]]),
            cacheHit: nil
        )
        XCTAssertTrue(report.isSupported)
        XCTAssertTrue(report.tableSizes.isEmpty)
        XCTAssertNil(report.cacheHit)
        XCTAssertEqual(report.connections.byState["idle"], 2)
    }

    /// 四类全空 = 这个方言不支持统计（界面据此说人话，而不是显示四个空表格）。
    func testReportIsUnsupportedWhenNothingCameBack() {
        let report = DatabaseStats.report(tableSizes: nil, tableScans: nil, connections: nil, cacheHit: nil)
        XCTAssertFalse(report.isSupported)
        XCTAssertTrue(report.tableSizes.isEmpty)
        XCTAssertTrue(report.tableScans.isEmpty)
        XCTAssertNil(report.cacheHit)
    }
}
