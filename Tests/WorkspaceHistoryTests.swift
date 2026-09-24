import XCTest
@testable import DoyahCore


/// 「最近打开」的落盘。
final class WorkspaceHistoryStoreTests: XCTestCase {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("doyah-workspace-history-\(UUID().uuidString).json")
    }

    func testLoadReturnsEmptyWhenFileMissing() throws {
        let store = WorkspaceHistoryStore(fileURL: temporaryURL())
        XCTAssertEqual(try store.load(), WorkspaceHistory())
    }

    func testRoundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceHistoryStore(fileURL: url)

        var history = WorkspaceHistory()
        history = WorkspaceHistory.recording(file: "/Users/me/index.ts", into: history)
        history = WorkspaceHistory.recording(workspace: "/Users/me/project", into: history)
        try store.save(history)

        XCTAssertEqual(try store.load(), history)
    }

    /// 空文件（写到一半断电之类）不该抛错，按空历史处理。
    func testEmptyFileIsTreatedAsEmptyHistory() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        XCTAssertEqual(try WorkspaceHistoryStore(fileURL: url).load(), WorkspaceHistory())
    }

    /// 内容坏了要**抛错**（让调用方如实告诉用户），而不是悄悄当成空历史 ——
    /// 那样用户会以为"最近打开"丢了，其实是文件坏了。
    func testCorruptFileThrows() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try WorkspaceHistoryStore(fileURL: url).load())
    }
}
