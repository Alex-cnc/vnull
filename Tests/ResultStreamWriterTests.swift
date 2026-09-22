import XCTest
@testable import DoyahCore

/// FR-RES-13：大结果流式落盘（分块一致 + 中断清理）。
final class ResultStreamWriterTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    private let columns = [
        ColumnMeta(id: 0, name: "id", typeName: "int4"),
        ColumnMeta(id: 1, name: "name", typeName: "text")
    ]

    private let rows: [[String?]] = [
        ["1", "Alice"],
        ["2", "Bob, Jr."],
        ["3", nil],
        ["4", "换行\n值"],
        ["5", "引号\"值"]
    ]

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResultStreamWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func readText(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// 逐字节比对：`String(contentsOf:)` 会吃掉 CSV 开头的 BOM，不能用来验「完全一致」。
    private func assertFileBytes(
        _ url: URL,
        equalTo text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8), file: file, line: line)
    }

    /// 目录里残留的临时文件（正常情况应该没有）。
    private func partialFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".partial-") }
    }

    private func oneShot(_ format: ResultExportFormat, tableName: String = "table_name") -> String {
        ResultExporter.text(
            for: QueryResult(columns: columns, rows: rows),
            format: format,
            tableName: tableName,
            dialect: PostgresDialect()
        )
    }

    // MARK: - 分块写入与一次性导出逐字节一致

    func testChunkedCsvMatchesOneShotExport() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")

        let writer = ResultStreamWriter(targetURL: url, format: .csv, columns: columns)
        try writer.begin()
        try writer.write(Array(rows[0..<2]))
        try writer.write(Array(rows[2..<5]))
        let report = try writer.finish()

        try assertFileBytes(url, equalTo: oneShot(.csv))
        XCTAssertEqual(report.rowCount, rows.count)
        XCTAssertEqual(report.byteCount, try Data(contentsOf: url).count)
        XCTAssertGreaterThanOrEqual(report.flushCount, 1)
    }

    func testChunkedTsvMatchesOneShotExport() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.tsv")

        let writer = ResultStreamWriter(targetURL: url, format: .tsv, columns: columns)
        try writer.begin()
        for row in rows {
            try writer.write([row])
        }
        try writer.finish()

        try assertFileBytes(url, equalTo: oneShot(.tsv))
    }

    func testChunkedMarkdownMatchesOneShotExport() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.md")

        let writer = ResultStreamWriter(targetURL: url, format: .markdown, columns: columns)
        try writer.begin()
        try writer.write(Array(rows[0..<3]))
        try writer.write(Array(rows[3..<5]))
        try writer.finish()

        try assertFileBytes(url, equalTo: oneShot(.markdown))
    }

    func testChunkedInsertMatchesOneShotExport() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.sql")

        let writer = ResultStreamWriter(
            targetURL: url,
            format: .sqlInsert,
            columns: columns,
            tableName: "people",
            dialect: PostgresDialect()
        )
        try writer.begin()
        try writer.write(Array(rows[0..<1]))
        try writer.write(Array(rows[1..<5]))
        try writer.finish()

        try assertFileBytes(url, equalTo: oneShot(.sqlInsert, tableName: "people"))
    }

    /// 把刷新阈值压到 1 字节，逼出多次落盘：结果必须仍然逐字节一致。
    func testTinyFlushLimitForcesManyFlushesWithoutChangingOutput() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")

        let writer = ResultStreamWriter(
            targetURL: url,
            format: .csv,
            columns: columns,
            flushByteLimit: 1
        )
        try writer.begin()
        try writer.write(rows)
        let report = try writer.finish()

        try assertFileBytes(url, equalTo: oneShot(.csv))
        XCTAssertGreaterThan(report.flushCount, rows.count, "阈值 1 字节时应当多次落盘")
    }

    // MARK: - 中断清理

    /// 原子性：`finish()` 之前目标路径不应存在（只有隐藏的临时文件）。
    func testTargetFileDoesNotExistBeforeFinish() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")

        let writer = ResultStreamWriter(targetURL: url, format: .csv, columns: columns)
        try writer.begin()
        try writer.write(rows)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try partialFiles(in: directory).count, 1)

        try writer.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try partialFiles(in: directory).isEmpty)
    }

    func testAbortRemovesPartialFileAndLeavesNoTarget() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")

        let writer = ResultStreamWriter(targetURL: url, format: .csv, columns: columns)
        try writer.begin()
        try writer.write(rows)
        writer.abort()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try partialFiles(in: directory).isEmpty)

        // 幂等：重复 abort 不抛错，也不影响目标路径。
        writer.abort()
        XCTAssertTrue(try partialFiles(in: directory).isEmpty)
    }

    /// 导出对象被释放而没走完 `finish()`：`deinit` 负责清掉半成品。
    func testDeinitCleansUpPartialFile() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")

        var writer: ResultStreamWriter? = ResultStreamWriter(
            targetURL: url, format: .csv, columns: columns
        )
        try writer?.begin()
        try writer?.write(rows)
        XCTAssertEqual(try partialFiles(in: directory).count, 1)

        writer = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try partialFiles(in: directory).isEmpty)
    }

    // MARK: - 分页驱动（不驻留全量内存）

    func testPagedWriteFetchesPagesIncrementally() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")

        var requestedOffsets: [Int] = []
        let report = try ResultStreamWriter.write(
            to: url,
            format: .csv,
            columns: columns,
            pageSize: 2,
            fetchPage: { offset, limit in
                requestedOffsets.append(offset)
                guard offset < self.rows.count else { return [] }
                return Array(self.rows[offset..<min(offset + limit, self.rows.count)])
            }
        )

        XCTAssertEqual(requestedOffsets, [0, 2, 4])
        XCTAssertEqual(report.rowCount, rows.count)
        try assertFileBytes(url, equalTo: oneShot(.csv))
    }

    /// 取页过程中抛错：不留下半个文件。
    func testFetchPageFailureCleansUp() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")

        struct FetchFailure: Error {}

        XCTAssertThrowsError(
            try ResultStreamWriter.write(
                to: url,
                format: .csv,
                columns: columns,
                pageSize: 2,
                fetchPage: { offset, limit in
                    if offset >= 2 { throw FetchFailure() }
                    return Array(self.rows[offset..<min(offset + limit, self.rows.count)])
                }
            )
        ) { error in
            XCTAssertTrue(error is FetchFailure)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try partialFiles(in: directory).isEmpty)
    }

    // MARK: - JSON

    /// 流式 JSON 与一次性 JSON 的**解析结果**一致（键顺序不同，语义相同）。
    func testStreamingJSONParsesToSameContent() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.json")

        let writer = ResultStreamWriter(targetURL: url, format: .json, columns: columns)
        try writer.begin()
        try writer.write(Array(rows[0..<2]))
        try writer.write(Array(rows[2..<5]))
        try writer.finish()

        let streamed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let oneShot = try JSONSerialization.jsonObject(
            with: Data(oneShot(.json).utf8)
        ) as? [String: Any]

        XCTAssertEqual(streamed?["rowCount"] as? Int, rows.count)
        XCTAssertEqual((streamed?["rows"] as? [[String: Any]])?.count, rows.count)
        XCTAssertEqual((streamed?["columns"] as? [[String: String]])?.count, columns.count)
        XCTAssertEqual(NSDictionary(dictionary: streamed ?? [:]),
                       NSDictionary(dictionary: oneShot ?? [:]))
    }

    func testStreamingJSONWithNoRowsIsStillValid() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("empty.json")

        let writer = ResultStreamWriter(targetURL: url, format: .json, columns: columns)
        try writer.begin()
        try writer.finish()

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(parsed?["rowCount"] as? Int, 0)
        XCTAssertEqual((parsed?["rows"] as? [Any])?.count, 0)
    }

    // MARK: - 空结果与覆盖

    func testEmptyCSVKeepsByteOrderMarkOnly() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("empty.csv")

        let writer = ResultStreamWriter(targetURL: url, format: .csv, columns: columns)
        try writer.begin()
        let report = try writer.finish()

        // 0 行时仍有表头：CSV 的表头与行数无关。
        try assertFileBytes(url, equalTo: "\u{FEFF}id,name\r\n")
        XCTAssertEqual(report.rowCount, 0)
        XCTAssertTrue(try partialFiles(in: directory).isEmpty)
    }

    func testExistingTargetFileIsReplaced() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")
        try "旧内容".write(to: url, atomically: true, encoding: .utf8)

        let writer = ResultStreamWriter(targetURL: url, format: .csv, columns: columns)
        try writer.begin()
        try writer.write(rows)
        try writer.finish()

        try assertFileBytes(url, equalTo: oneShot(.csv))
        XCTAssertTrue(try partialFiles(in: directory).isEmpty)
    }

    // MARK: - 状态机

    func testWriteAndFinishWithoutBeginThrow() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")
        let writer = ResultStreamWriter(targetURL: url, format: .csv, columns: columns)

        XCTAssertThrowsError(try writer.write([["1", "a"]])) {
            XCTAssertEqual($0 as? ResultStreamError, .notStarted)
        }
        XCTAssertThrowsError(try writer.finish()) {
            XCTAssertEqual($0 as? ResultStreamError, .notStarted)
        }
        // 没 begin 过也不该留下任何文件。
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testBeginTwiceThrows() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")
        let writer = ResultStreamWriter(targetURL: url, format: .csv, columns: columns)
        try writer.begin()

        XCTAssertThrowsError(try writer.begin()) {
            XCTAssertEqual($0 as? ResultStreamError, .alreadyStarted)
        }
        writer.abort()
    }

    func testFinishTwiceThrows() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")
        let writer = ResultStreamWriter(targetURL: url, format: .csv, columns: columns)
        try writer.begin()
        try writer.finish()

        XCTAssertThrowsError(try writer.finish()) {
            XCTAssertEqual($0 as? ResultStreamError, .alreadyFinished)
        }
    }

    func testNonPositiveFlushLimitIsRejected() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("out.csv")
        let writer = ResultStreamWriter(
            targetURL: url, format: .csv, columns: columns, flushByteLimit: 0
        )

        XCTAssertThrowsError(try writer.begin()) {
            XCTAssertEqual($0 as? ResultStreamError, .invalidFlushLimit(0))
        }
    }
}
