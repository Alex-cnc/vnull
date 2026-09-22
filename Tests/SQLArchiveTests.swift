import XCTest
@testable import DoyahCore

/// 查询自动归档（FR-EDIT-32）：格式、按天合并、往返可解析、落盘。
final class SQLArchiveTests: XCTestCase {

    private let zone = TimeZone(identifier: "Asia/Shanghai")!

    private func date(_ text: String) -> Date {
        SQLArchive.date(from: text, timeZone: zone)!
    }

    private func entry(
        _ sql: String,
        at text: String = "2026-09-23 09:12:33",
        connection: String = "DemoPG",
        database: String = "app",
        duration: Double? = 0.031,
        affected: Int? = nil,
        succeeded: Bool = true,
        note: String? = nil
    ) -> SQLArchiveEntry {
        let stamp = date(text)
        return SQLArchiveEntry(
            sql: sql,
            firstExecutedAt: stamp,
            lastExecutedAt: stamp,
            connection: connection,
            database: database,
            durationSeconds: duration,
            affectedRows: affected,
            succeeded: succeeded,
            note: note
        )
    }

    // MARK: 命名与规范化

    func testFileNameIsDayBasedSQL() {
        XCTAssertEqual(SQLArchive.fileName(for: date("2026-09-23 09:12:33")), "2026-09-23.sql")
    }

    /// 规范化只做保守归一：压空白、去行尾分号；**不改大小写**（标识符大小写敏感）。
    func testNormalizedSQLCollapsesWhitespaceAndTrailingSemicolons() {
        XCTAssertEqual(
            SQLArchive.normalizedSQL("  SELECT  a,\n  b\n FROM t ;  "),
            "SELECT a, b FROM t"
        )
        XCTAssertNotEqual(
            SQLArchive.normalizedSQL("select a from t"),
            SQLArchive.normalizedSQL("SELECT a FROM t")
        )
    }

    // MARK: 合并

    func testDifferentSQLAppendsNewEntry() {
        let a = entry("SELECT 1")
        let b = entry("SELECT 2")
        XCTAssertEqual(SQLArchive.merged([a], adding: b), [a, b])
    }

    /// 同一条 SQL 重复执行：只累计次数、刷新最近时间与结果，**不重复抄写**。
    func testSameSQLIncrementsRunCountAndKeepsFirstTime() {
        let first = entry("SELECT 1", at: "2026-09-23 09:00:00", duration: 0.5)
        let again = entry("SELECT 1", at: "2026-09-23 10:30:00", duration: 0.02)

        let merged = SQLArchive.merged([first], adding: again)
        XCTAssertEqual(merged.count, 1, "同一条 SQL 不该变成两条")
        XCTAssertEqual(merged[0].runCount, 2)
        XCTAssertEqual(merged[0].firstExecutedAt, first.firstExecutedAt, "首次时间要保留")
        XCTAssertEqual(merged[0].lastExecutedAt, again.lastExecutedAt, "最近时间要刷新")
        XCTAssertEqual(merged[0].durationSeconds, 0.02, "耗时取最近一次")
    }

    /// 同一 SQL 换行 / 多空格 / 多个分号，仍算同一条。
    func testNormalizationMakesWhitespaceVariantsTheSameEntry() {
        let merged = SQLArchive.merged(
            [entry("SELECT  a\nFROM t")],
            adding: entry("SELECT a FROM t;")
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].runCount, 2)
    }

    /// 同一条 SQL 在**不同库**上执行是不同条目 —— "在哪跑的"是关键信息。
    func testSameSQLOnDifferentDatabasesStaysSeparate() {
        let merged = SQLArchive.merged(
            [entry("SELECT 1", database: "a")],
            adding: entry("SELECT 1", database: "b")
        )
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: 渲染 / 解析往返

    func testRoundTripPreservesEveryField() {
        let entries = [
            entry("SELECT id, name\nFROM users\nWHERE id = 1;", affected: 3),
            entry("UPDATE t SET a = 1", at: "2026-09-23 11:00:00", duration: nil, succeeded: false,
                  note: "permission denied\n第二行")
        ]
        let text = SQLArchive.render(entries, day: date("2026-09-23 00:00:00"), timeZone: zone)
        XCTAssertEqual(SQLArchive.parse(text, timeZone: zone), entries)
    }

    /// SQL 里带 `--` 注释行不能被当成元信息（否则解析会吃掉语句）。
    func testRoundTripSurvivesCommentLikeSQLLines() {
        let sql = "-- 这是语句里的注释\nSELECT 1;\n-- 又一行注释"
        let text = SQLArchive.render([entry(sql)], day: date("2026-09-23 00:00:00"), timeZone: zone)
        XCTAssertEqual(SQLArchive.parse(text, timeZone: zone).first?.sql, sql)
    }

    func testRoundTripIsStableAcrossRepeatedParsing() {
        let text = SQLArchive.render([entry("SELECT 1")], day: date("2026-09-23 00:00:00"), timeZone: zone)
        let once = SQLArchive.parse(text, timeZone: zone)
        let twice = SQLArchive.parse(SQLArchive.render(once, day: date("2026-09-23 00:00:00"), timeZone: zone), timeZone: zone)
        XCTAssertEqual(once, twice)
    }

    func testRenderHeaderNamesTheDay() {
        let text = SQLArchive.render([], day: date("2026-09-23 00:00:00"), timeZone: zone)
        XCTAssertTrue(text.contains("2026-09-23"), text)
    }

    func testParseOfGarbageReturnsEmpty() {
        XCTAssertTrue(SQLArchive.parse("这不是归档文件\nSELECT 1;", timeZone: zone).isEmpty)
    }

    /// 时间只精确到秒：否则每次读回来都会被判成"变了"而反复写盘。
    func testTimesAreTruncatedToWholeSeconds() {
        let precise = SQLArchiveEntry(
            sql: "SELECT 1",
            firstExecutedAt: Date(timeIntervalSince1970: 1_789_000_000.987),
            lastExecutedAt: Date(timeIntervalSince1970: 1_789_000_000.987),
            connection: "c", database: "d"
        )
        let merged = SQLArchive.merged([], adding: precise)
        XCTAssertEqual(merged[0].firstExecutedAt.timeIntervalSince1970, 1_789_000_000)
    }
}

/// 落盘层：目录创建、按天文件、原子写、合并后回读。
final class SQLArchiveStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sql-archive-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> SQLArchiveStore {
        SQLArchiveStore(directory: directory, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    }

    private func entry(_ sql: String, at stamp: Date) -> SQLArchiveEntry {
        SQLArchiveEntry(
            sql: sql,
            firstExecutedAt: stamp,
            lastExecutedAt: stamp,
            connection: "DemoPG",
            database: "app",
            durationSeconds: 0.01
        )
    }

    func testAppendCreatesDirectoryAndFile() throws {
        let day = Date(timeIntervalSince1970: 1_789_000_000)
        let count = try store().append(entry("SELECT 1", at: day), on: day)
        XCTAssertEqual(count, 1)

        let url = store().fileURL(on: day)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "应自动建目录并落盘")
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".sql"))
    }

    func testAppendSameSQLAccumulatesInOneFile() throws {
        let day = Date(timeIntervalSince1970: 1_789_000_000)
        _ = try store().append(entry("SELECT 1", at: day), on: day)
        _ = try store().append(entry("SELECT 1", at: day), on: day)
        _ = try store().append(entry("SELECT 2", at: day), on: day)

        let entries = try store().entries(on: day)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.sql == "SELECT 1" }?.runCount, 2)
    }

    func testEntriesForMissingDayIsEmptyNotError() throws {
        XCTAssertTrue(try store().entries(on: Date()).isEmpty)
    }

    func testDifferentDaysGoToDifferentFiles() throws {
        let first = Date(timeIntervalSince1970: 1_789_000_000)
        let second = first.addingTimeInterval(86_400)
        _ = try store().append(entry("SELECT 1", at: first), on: first)
        _ = try store().append(entry("SELECT 2", at: second), on: second)

        XCTAssertNotEqual(store().fileURL(on: first), store().fileURL(on: second))
        XCTAssertEqual(try store().entries(on: first).count, 1)
        XCTAssertEqual(try store().entries(on: second).count, 1)
    }

    /// 原子写：写完目录里只应有归档文件本身，没有临时残留。
    func testNoTemporaryFilesLeftBehind() throws {
        let day = Date(timeIntervalSince1970: 1_789_000_000)
        _ = try store().append(entry("SELECT 1", at: day), on: day)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents.count, 1, "目录里不该有临时文件残留：\(contents)")
    }
}
