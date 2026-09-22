import XCTest
@testable import DoyahCore

final class SavedQueryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testSaveAndLoadRoundTrip() async throws {
        let store = SavedQueryStore(directoryURL: directory)
        let connectionID = UUID()

        let queries = [
            SavedQuery(
                name: "最近订单",
                connectionID: connectionID,
                database: "postgres",
                sql: "SELECT * FROM orders;",
                savedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            SavedQuery(
                name: "活跃用户",
                sql: "SELECT * FROM users;",
                savedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        ]

        try await store.save(queries)
        let loaded = try await store.load()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.name), ["最近订单", "活跃用户"])
        XCTAssertEqual(loaded[0].sql, "SELECT * FROM orders;")
        XCTAssertEqual(loaded[0].connectionID, connectionID)
        XCTAssertEqual(loaded[0].database, "postgres")
        XCTAssertEqual(loaded[0].savedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(loaded[1].connectionID)
    }

    func testLoadReturnsEmptyWhenFileMissing() async throws {
        let store = SavedQueryStore(directoryURL: directory)
        let loaded = try await store.load()

        XCTAssertTrue(loaded.isEmpty)
    }

    func testCorruptedFileThrowsPersistenceError() async throws {
        let store = SavedQueryStore(directoryURL: directory)
        let location = await store.fileLocation()
        try Data("not a json".utf8).write(to: location)

        do {
            _ = try await store.load()
            XCTFail("损坏文件应当抛错")
        } catch let error as AppError {
            guard case .persistence = error else {
                return XCTFail("期望 persistence 错误，实际 \(error)")
            }
        }
    }
}
