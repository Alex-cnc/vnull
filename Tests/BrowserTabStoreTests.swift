import XCTest
@testable import DoyahCore

/// 浏览器页签会话持久化（FR-EDIT-34 契约 ⑤）的回归测试。
///
/// 核心不变量：**恢复出来的页签带着地址与历史，但绝不自动发起请求**。
/// 存储层能保证的是"地址与历史回来了"；"不自动请求"由 `AppState`（恢复时不建引擎）
/// 与视图（显示「已恢复的页签（尚未加载）」）共同保证 —— 两边都有测试。
final class BrowserTabStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserTabStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func makeStore() -> BrowserTabStore {
        BrowserTabStore(directoryURL: directory)
    }

    func testSaveAndLoadRoundTripKeepsURLTitleAndHistory() async throws {
        let store = makeStore()

        var page = BrowserPage()
        page.beginNavigation(to: URL(string: "https://a.example/one")!)
        page.beginNavigation(to: URL(string: "https://a.example/two")!)
        page.finishNavigation(title: "第二个页面")

        try await store.save([page])
        let restored = try await store.load()

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, page.id)
        XCTAssertEqual(restored.first?.url, URL(string: "https://a.example/two"))
        XCTAssertEqual(restored.first?.title, "第二个页面")

        // 历史也回来了：这意味着恢复后「后退」仍然可用（否则用户会以为历史丢了）。
        var restoredPage = try XCTUnwrap(restored.first)
        XCTAssertTrue(restoredPage.canGoBack)
        XCTAssertEqual(restoredPage.goBack(), URL(string: "https://a.example/one"))
    }

    /// 没有文件 = 没有页签（不是错误）。
    func testMissingFileLoadsAsEmpty() async throws {
        let store = makeStore()
        let pages = try await store.load()
        XCTAssertTrue(pages.isEmpty)
    }

    /// 文件损坏要**如实抛错**，不能静默当成空 —— 静默吞掉会让「页签怎么没了」变成无解悬案。
    func testCorruptFileThrowsReadableError() async throws {
        let store = makeStore()
        let location = await store.fileLocation()
        try Data("这不是 JSON".utf8).write(to: location)

        do {
            _ = try await store.load()
            XCTFail("损坏文件应当抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("浏览器页签读取失败"))
        }
    }

    /// 上限保护：手改文件塞几百个页签也不至于让界面一次性冒出几百个。
    func testRestoreIsBounded() async throws {
        let store = makeStore()
        let pages = (0..<(BrowserTabStore.restoreLimit + 10)).map { index -> BrowserPage in
            var page = BrowserPage()
            page.beginNavigation(to: URL(string: "https://example.com/\(index)")!)
            return page
        }
        try await store.save(pages)

        let restored = try await store.load()
        XCTAssertEqual(restored.count, BrowserTabStore.restoreLimit)
    }

    func testClearRemovesTheFile() async throws {
        let store = makeStore()
        var page = BrowserPage()
        page.beginNavigation(to: URL(string: "https://example.com")!)
        try await store.save([page])

        try await store.clear()

        let pages = try await store.load()
        XCTAssertTrue(pages.isEmpty)
    }
}
