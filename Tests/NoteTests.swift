import XCTest
@testable import DoyahCore

/// DOYAH-01 / 06 / 07 / 10 的 Core 半步：笔记模型、本地库、检索，以及**AI 产物→笔记的桥**的三条安全边界。
final class NoteTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doyah-notes-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testUpsertAndLoadRoundTrip() async throws {
        let store = NoteStore(fileURL: fileURL)
        let note = try await store.upsert(NoteDraft(title: " 索引失效排查 ", body: "EXPLAIN 看到 Seq Scan", tags: ["pg", " 性能 "]))
        XCTAssertEqual(note.title, "索引失效排查", "标题要去首尾空白")
        XCTAssertEqual(note.tags, ["pg", "性能"], "标签也要去空白并丢掉空标签")
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].body, "EXPLAIN 看到 Seq Scan")
    }

    /// **默认不带结果集行数据**；要带必须显式确认，且笔记上永久留痕。
    func testRowDataRequiresExplicitConfirmationAndLeavesATrace() async throws {
        let store = NoteStore(fileURL: fileURL)
        let normal = try await store.upsert(NoteDraft(title: "普通笔记", body: "SELECT 1"))
        XCTAssertFalse(normal.containsRowData)

        let withRows = try await store.upsert(
            NoteDraft(title: "带数据的笔记", body: "id | name").withRowData()
        )
        XCTAssertTrue(withRows.containsRowData, "显式确认过就必须留痕（同步到云端后用户要能查）")
        let loaded = try await store.load()
        XCTAssertEqual(loaded.filter(\.containsRowData).count, 1)
    }

    /// 来源只记**连接名字**：口令、连接串不允许出现在来源里。
    func testSourceOnlyRecordsConnectionName() async throws {
        let store = NoteStore(fileURL: fileURL)
        let source = NoteSource(kind: .diagnosis, connectionName: "217-PG", fingerprint: "e2")
        let note = try await store.upsert(NoteDraft(title: "诊断结论", body: "全表扫描", source: source))
        XCTAssertEqual(note.source.connectionName, "217-PG")
        XCTAssertEqual(note.source.kind, .diagnosis)
        XCTAssertEqual(note.source.fingerprint, "e2")

        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("password"), "落盘文件里不该出现口令字样")
        XCTAssertFalse(raw.contains("postgres://"), "也不该出现连接串")
    }

    /// AI 产物用 `.skill` 类别沉淀（DOYAH-10 的核心场景）。
    func testSkillCaptureKeepsKindAndFingerprint() async throws {
        let store = NoteStore(fileURL: fileURL)
        let draft = NoteDraft(
            title: "修 MySQL 时区问题的步骤",
            body: "1) SET time_zone 2) 检查 TIMESTAMP 列",
            tags: ["mysql"],
            source: NoteSource(kind: .skill, connectionName: "DemoMySQL", fingerprint: "skill-42")
        )
        let note = try await store.upsert(draft)
        XCTAssertEqual(note.source.kind, .skill)
        XCTAssertEqual(note.source.fingerprint, "skill-42")
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.first?.source.kind, .skill)
    }

    func testUpdateKeepsCreatedAtAndRefreshesUpdatedAt() async throws {
        let store = NoteStore(fileURL: fileURL)
        let created = try await store.upsert(NoteDraft(title: "标题"), now: Date(timeIntervalSince1970: 1_000))
        let later = Date(timeIntervalSince1970: 5_000)
        let updated = try await store.upsert(NoteDraft(title: "改过的标题"), id: created.id, now: later)
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.createdAt, created.createdAt, "创建时间不能被改写")
        XCTAssertEqual(updated.updatedAt, later)
        let afterUpdate = try await store.load()
        XCTAssertEqual(afterUpdate.count, 1, "更新不该多出一条")
    }

    func testDeleteRemovesOnlyThatNote() async throws {
        let store = NoteStore(fileURL: fileURL)
        let a = try await store.upsert(NoteDraft(title: "A"))
        _ = try await store.upsert(NoteDraft(title: "B"))
        try await store.delete(id: a.id)
        let remaining = try await store.load()
        XCTAssertEqual(remaining.map(\.title), ["B"])
    }

    /// 坏文件不该让整个笔记库不可用（与工程里其它存储同一纪律：回退 + 不静默丢）。
    func testCorruptFileFallsBackToEmpty() async throws {
        try "{ 这不是 JSON".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = NoteStore(fileURL: fileURL)
        let notes = try await store.load()
        XCTAssertTrue(notes.isEmpty)
        _ = try await store.upsert(NoteDraft(title: "坏文件之后还能写"))
        let written = try await store.load()
        XCTAssertEqual(written.count, 1)
    }

    func testSearchMatchesTitleBodyAndTags() {
        let notes = [
            Note(title: "索引失效", body: "EXPLAIN 里看到 Seq Scan", tags: ["pg"], updatedAt: Date(timeIntervalSince1970: 3)),
            Note(title: "事务", body: "回滚没生效", tags: ["mysql", "排障"], updatedAt: Date(timeIntervalSince1970: 2)),
            Note(title: "时区", body: "TIMESTAMP 与 DATETIME", tags: ["mysql"], updatedAt: Date(timeIntervalSince1970: 1))
        ]
        XCTAssertEqual(NoteSearch.match(notes, query: "SEQ").map(\.title), ["索引失效"], "正文匹配且大小写不敏感")
        XCTAssertEqual(NoteSearch.match(notes, query: "mysql").map(\.title), ["事务", "时区"], "标签匹配、按更新时间倒序")
        XCTAssertEqual(NoteSearch.match(notes, query: "  ").map(\.title), ["索引失效", "事务", "时区"], "空查询按更新时间倒序")
        XCTAssertTrue(NoteSearch.match(notes, query: "找不到的词").isEmpty)
    }

    func testTagCountsAreStableAndSorted() {
        let notes = [
            Note(title: "A", tags: ["mysql", "排障"]),
            Note(title: "B", tags: ["mysql"]),
            Note(title: "C", tags: ["pg"])
        ]
        let counts = NoteSearch.tagCounts(notes)
        XCTAssertEqual(counts.first?.tag, "mysql")
        XCTAssertEqual(counts.first?.count, 2)
        XCTAssertEqual(counts.map(\.tag), ["mysql", "pg", "排障"], "同次数按字典序，顺序稳定")
    }
}
