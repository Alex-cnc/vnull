import XCTest
@testable import DoyahCore

/// FR-AI-05 / FR-AI-06 / FR-AI-08：数据任务的 SQL 编译、护栏判定与授权目录产物导出。
final class DataTaskRunTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataTaskRunTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTask(
        columns: [String] = ["id", "customer_id", "total"],
        transformations: [DataTaskDefinition.Transformation] = [],
        writeMode: DataTaskDefinition.Target.WriteMode = .append,
        keyColumns: [String] = [],
        filter: String? = nil,
        output: DataTaskDefinition.ExportSettings? = nil,
        specs: String = "把订单搬到归档表。"
    ) -> DataTaskDefinition {
        DataTaskDefinition(
            name: "订单归档",
            specs: specs,
            source: .init(schema: "public", table: "orders", columns: columns, filter: filter),
            transformations: transformations,
            target: .init(schema: "public", table: "orders_archive", writeMode: writeMode, keyColumns: keyColumns),
            schedule: .manual,
            output: output,
            createdAt: epoch,
            updatedAt: epoch
        )
    }

    /// 用假书签走一遍「选目录 → 书签 → 取用」，拿到真实结构的 `DirectoryGrant`。
    private func makeGrant(directory: URL) throws -> DirectoryGrant {
        let bookmarking = FakeScopeBookmarking()
        let bookmark = try SecureDirectoryAccess.makeBookmark(for: directory, bookmarking: bookmarking)
        return try SecureDirectoryAccess.open(bookmark, bookmarking: bookmarking)
    }

    // MARK: - 读取语句（FR-AI-05）

    func testSelectAppliesTransformationsInOrder() throws {
        let task = makeTask(columns: ["id", "customer_id", "total", "note"], transformations: [
            .init(kind: .rename, column: "id", targetColumn: "order_id"),
            .init(kind: .cast, column: "total", expression: "numeric(12,2)"),
            .init(kind: .mask, column: "customer_id", expression: "'***'"),
            .init(kind: .drop, column: "note"),
            .init(kind: .derive, targetColumn: "loaded_at", expression: "now()")
        ])

        let select = try DataTaskRunner.select(for: task)

        // 改名后的列名进入输出清单；类型转换编译成 CAST；派生列追加在最后；被丢弃的列消失。
        XCTAssertEqual(select.columnNames, ["order_id", "customer_id", "total", "loaded_at"])
        XCTAssertTrue(select.sql.hasPrefix("SELECT "))
        XCTAssertTrue(select.sql.contains("CAST(\"total\" AS numeric(12,2)) AS \"total\""))
        XCTAssertTrue(select.sql.contains("\"id\" AS \"order_id\""))
        XCTAssertTrue(select.sql.contains("('***') AS \"customer_id\""))
        XCTAssertTrue(select.sql.contains("(now()) AS \"loaded_at\""))
        XCTAssertTrue(select.sql.contains("FROM \"public\".\"orders\""))
        XCTAssertFalse(select.sql.contains("\"note\""))
    }

    func testSelectKeepsWildcardWhenSourceColumnsAreEmpty() throws {
        let task = makeTask(columns: [], transformations: [
            .init(kind: .derive, targetColumn: "loaded_at", expression: "now()")
        ])

        let select = try DataTaskRunner.select(for: task)

        XCTAssertNil(select.columnNames)
        XCTAssertTrue(select.sql.contains("SELECT *, (now()) AS \"loaded_at\""))
    }

    func testSelectCarriesFilterAndLimit() throws {
        let task = makeTask(filter: "created_at < now() - interval '30 days'")

        let sql = try DataTaskRunner.selectStatement(for: task, limit: 10)

        XCTAssertTrue(sql.contains("WHERE created_at < now() - interval '30 days'"))
        XCTAssertTrue(sql.hasSuffix("LIMIT 10 OFFSET 0"))
    }

    func testDropWithoutColumnListIsRejectedReadably() {
        let task = makeTask(columns: [], transformations: [.init(kind: .drop, column: "id")])

        // 定义校验先拦一道（源列清单为空 + 丢弃列）。
        XCTAssertTrue(task.issues.contains { $0.contains("丢弃列") })

        XCTAssertThrowsError(try DataTaskRunner.select(for: task)) { error in
            guard case DataTaskRunError.invalidDefinition = error else {
                return XCTFail("应抛 invalidDefinition，实际：\(error)")
            }
        }
    }

    func testUnknownColumnIsRejectedReadably() {
        let task = makeTask(transformations: [.init(kind: .rename, column: "nope", targetColumn: "x")])

        XCTAssertTrue(task.issues.contains { $0.contains("不在源列清单里") })
        XCTAssertThrowsError(try DataTaskRunner.select(for: task)) { error in
            guard case DataTaskRunError.invalidDefinition = error else {
                return XCTFail("应抛 invalidDefinition，实际：\(error)")
            }
        }
    }

    func testMissingTransformationFieldIsRejectedReadably() {
        // 绕开 `issues`（它按「定义填得对不对」给问题），直接验编译期的可读错误。
        let task = DataTaskDefinition(
            name: "缺字段",
            specs: "派生列但没给目标列名。",
            source: .init(table: "orders", columns: ["id"]),
            transformations: [.init(kind: .derive, expression: "now()")],
            target: .init(table: "archive"),
            createdAt: epoch,
            updatedAt: epoch
        )
        XCTAssertTrue(task.issues.contains { $0.contains("缺少目标列名") })

        XCTAssertThrowsError(try DataTaskRunner.projections(for: task, dialect: PostgresDialect())) { error in
            guard case DataTaskRunError.missingTransformationField(let kind, let field) = error else {
                return XCTFail("应抛 missingTransformationField，实际：\(error)")
            }
            XCTAssertEqual(kind, "派生列")
            XCTAssertEqual(field, "目标列名")
        }
    }

    // MARK: - 写入语句（FR-AI-06 的执行形态）

    func testAppendWriteIsSingleInsertSelect() throws {
        let statements = try DataTaskRunner.writeStatements(for: makeTask())

        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(
            statements[0].hasPrefix("INSERT INTO \"public\".\"orders_archive\" (\"id\", \"customer_id\", \"total\") SELECT")
        )
        XCTAssertTrue(statements[0].hasSuffix(";"))
        XCTAssertFalse(statements[0].contains("TRUNCATE"))
    }

    func testOverwriteWriteTruncatesBeforeInsert() throws {
        let statements = try DataTaskRunner.writeStatements(for: makeTask(writeMode: .overwrite))

        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0], "TRUNCATE TABLE \"public\".\"orders_archive\";")
        XCTAssertTrue(statements[1].hasPrefix("INSERT INTO "))
    }

    func testUpsertWriteUsesConflictKeysAndExcludesThemFromUpdate() throws {
        let task = makeTask(writeMode: .upsert, keyColumns: ["id"])

        let sql = try DataTaskRunner.writeStatementText(for: task)

        XCTAssertTrue(sql.contains("ON CONFLICT (\"id\") DO UPDATE SET "))
        XCTAssertTrue(sql.contains("\"total\" = EXCLUDED.\"total\""))
        // 冲突键自己不进更新列表。
        XCTAssertFalse(sql.contains("\"id\" = EXCLUDED.\"id\""))
    }

    func testUpsertWriteFallsBackToDoNothingWhenAllColumnsAreKeys() throws {
        let task = makeTask(writeMode: .upsert, keyColumns: ["id", "customer_id", "total"])

        let sql = try DataTaskRunner.writeStatementText(for: task)

        XCTAssertTrue(sql.contains("DO NOTHING"))
    }

    func testUpsertOnGBaseIsRejectedInsteadOfPretending() {
        let task = makeTask(writeMode: .upsert, keyColumns: ["id"])

        XCTAssertThrowsError(
            try DataTaskRunner.writeStatements(for: task, dialect: GBaseDialect())
        ) { error in
            guard case DataTaskRunError.upsertUnsupported = error else {
                return XCTFail("应抛 upsertUnsupported，实际：\(error)")
            }
            XCTAssertTrue((error as? DataTaskRunError)?.errorDescription?.contains("不支持") ?? false)
        }
    }

    func testWriteStatementIsRejectedInReadOnlyModeByGuardrail() throws {
        let task = makeTask()

        let assessment = try XCTUnwrap(DataTaskRunner.guardAssessment(for: task, policy: .readOnlyDefault))

        XCTAssertFalse(assessment.verdict.isAllowed)
        XCTAssertTrue(assessment.verdict.message.contains("只读"))
    }

    func testWriteStatementNeedsApprovalOnceReadOnlyIsOff() throws {
        let task = makeTask()

        // App 侧用的是配置里的策略（`requireApprovalForWrites` 默认开，FR-AI-09）。
        let assessment = try XCTUnwrap(
            DataTaskRunner.guardAssessment(for: task, policy: AgentGuardPolicy(readOnly: false))
        )

        guard case .requireApproval(let findings) = assessment.verdict else {
            return XCTFail("写语句应需要审批，实际：\(assessment.verdict)")
        }
        XCTAssertTrue(findings.contains(.writeStatement))
    }

    // MARK: - 读取（走 DatabaseService）

    func testReadAggregatesResultSetFromService() async throws {
        let task = makeTask(columns: ["id"])
        let service = FakeDatabaseService { sql in
            guard sql.contains("FROM \"public\".\"orders\"") else { return nil }
            return QueryResult(
                columns: [ColumnMeta(id: 0, name: "id", typeName: "int8")],
                rows: [["1"], ["2"]]
            )
        }

        let result = try await DataTaskRunner.read(task, on: service)

        XCTAssertEqual(result.columns.map(\.name), ["id"])
        XCTAssertEqual(result.rows.count, 2)
    }

    func testReadWithoutResultSetGivesReadableError() async {
        let task = makeTask(columns: ["id"])
        let service = FakeDatabaseService { _ in nil }

        do {
            _ = try await DataTaskRunner.read(task, on: service)
            XCTFail("应抛 noResultSet")
        } catch {
            XCTAssertEqual(error as? DataTaskRunError, .noResultSet)
        }
    }

    // MARK: - 产物导出（FR-AI-08）

    func testArtifactFileNameUsesTemplateAndNeverEscapesTheDirectory() throws {
        let task = makeTask(output: .init(format: .csv, fileNameTemplate: "../../{task}/落盘"))

        let fileName = try DataTaskRunner.artifactFileName(for: task, at: epoch)

        XCTAssertFalse(fileName.contains("/"))
        XCTAssertFalse(fileName.contains(".."))
        XCTAssertFalse(fileName.contains("\\"))
        XCTAssertTrue(fileName.hasSuffix(".csv"))
        XCTAssertTrue(fileName.contains("订单归档"))
    }

    func testArtifactFileNameDefaultIncludesTaskAndTimestamp() throws {
        let task = makeTask(output: .init(format: .tsv))

        let fileName = try DataTaskRunner.artifactFileName(for: task, at: epoch)

        XCTAssertTrue(fileName.hasPrefix("订单归档-"))
        XCTAssertTrue(fileName.hasSuffix(".tsv"))
    }

    func testArtifactFileNameDoesNotDuplicateExtension() throws {
        let task = makeTask(output: .init(format: .json, fileNameTemplate: "dump.json"))

        XCTAssertEqual(try DataTaskRunner.artifactFileName(for: task, at: epoch), "dump.json")
    }

    func testArtifactFileNameRequiresExportSettings() {
        XCTAssertThrowsError(try DataTaskRunner.artifactFileName(for: makeTask(), at: epoch)) { error in
            XCTAssertEqual(error as? DataTaskRunError, .missingExportSettings)
        }
    }

    func testExportArtifactWritesIntoGrantedDirectory() throws {
        let directory = try makeDirectory()
        let task = makeTask(output: .init(format: .csv, fileNameTemplate: "orders"))
        let grant = try makeGrant(directory: directory)
        let result = QueryResult(
            columns: [ColumnMeta(id: 0, name: "id", typeName: "int8")],
            rows: [["1"], ["2"]]
        )

        let url = try DataTaskRunner.exportArtifact(result, for: task, grant: grant, at: epoch)

        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("id"))
        XCTAssertTrue(text.contains("1"))
    }

    func testExportArtifactFailureIsReadable() throws {
        // 先拿到合法授权，再把目录删掉 —— 模拟「授权过的目录被移动 / 卷未挂载」。
        let directory = try makeDirectory()
        let task = makeTask(output: .init(format: .csv))
        let grant = try makeGrant(directory: directory)
        try FileManager.default.removeItem(at: directory)
        let result = QueryResult(columns: [ColumnMeta(id: 0, name: "id")], rows: [["1"]])

        XCTAssertThrowsError(try DataTaskRunner.exportArtifact(result, for: task, grant: grant, at: epoch)) { error in
            guard case DataTaskRunError.exportFailed = error else {
                return XCTFail("应抛 exportFailed，实际：\(error)")
            }
            // 失败必须说清是哪个文件，而不是静默不写。
            XCTAssertTrue((error as? DataTaskRunError)?.errorDescription?.contains("订单归档") ?? false)
        }
    }

    func testExportPreviewReportIsWrittenAndReadable() throws {
        let directory = try makeDirectory()
        let task = makeTask(output: .init(format: .csv))
        let grant = try makeGrant(directory: directory)
        let preview = try task.dryRun()

        let url = try DataTaskRunner.exportPreviewReport(for: task, preview: preview, grant: grant, at: epoch)

        XCTAssertEqual(url.pathExtension, "txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(task.specs))
        XCTAssertTrue(text.contains("SELECT"))
        XCTAssertTrue(text.contains(directory.path))
    }
}

/// 假书签实现：书签字节就是路径的 UTF-8（与 `SecureDirectoryAccessTests` 同思路，
/// 这里单独放一份是因为那个是 `private`）。
private final class FakeScopeBookmarking: SecurityScopedBookmarking, @unchecked Sendable {
    func makeBookmark(for directory: URL) throws -> Data {
        Data(directory.path.utf8)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        guard let path = String(data: data, encoding: .utf8) else {
            throw DirectoryAccessError.bookmarkCreationFailed(reason: "未知书签")
        }
        return (URL(fileURLWithPath: path, isDirectory: true), false)
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
