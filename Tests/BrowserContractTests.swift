import XCTest
@testable import DoyahCore

/// 内嵌浏览器的契约测试（FR-EDIT-34）。
///
/// 这一组盯住的是**行为契约**，不是渲染：策略（默认不加载远程内容、只放行 http/https）、
/// 状态迁移（历史 / 前进后退 / 失败留在原页）、以及**每条出网都进外发日志**。
/// 渲染归平台实现，两个平台共用这里的规则。
final class BrowserContractTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func url(_ text: String) -> URL {
        URL(string: text)!
    }

    // MARK: - 导航策略

    /// **默认不加载远程内容**：引擎的自动加载（恢复会话 / 预取 / 脚本跳转）一律拒绝。
    func testRemoteLoadWithoutUserIntentIsBlocked() {
        let decision = BrowserNavigationPolicy.decide(
            url: url("https://example.com/"),
            isUserInitiated: false
        )
        guard case .block(let reason) = decision else {
            return XCTFail("非用户发起的远程加载必须被拒绝，实际：\(decision)")
        }
        XCTAssertTrue(reason.contains("默认不加载远程内容"))
    }

    func testUserInitiatedHTTPSIsAllowed() {
        let decision = BrowserNavigationPolicy.decide(
            url: url("https://example.com/a?b=1"),
            isUserInitiated: true
        )
        XCTAssertEqual(decision, .allow(url("https://example.com/a?b=1")))
    }

    /// 只放行 http / https；其余协议有**可读**的拒绝原因。
    func testNonWebSchemesAreBlockedWithReadableReason() {
        for text in [
            "javascript:alert(1)",
            "data:text/html,<h1>x</h1>",
            "file:///etc/passwd"
        ] {
            guard case .block(let reason) = BrowserNavigationPolicy.decide(
                url: url(text), isUserInitiated: true
            ) else {
                return XCTFail("\(text) 必须被拒绝")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testBlankPageIsAllowed() {
        XCTAssertEqual(
            BrowserNavigationPolicy.decide(url: url("about:blank"), isUserInitiated: false),
            .allow(url("about:blank"))
        )
    }

    func testMissingHostIsBlocked() {
        guard case .block = BrowserNavigationPolicy.decide(
            url: url("https:///nohost"), isUserInitiated: true
        ) else {
            return XCTFail("没有主机名的地址必须被拒绝")
        }
    }

    // MARK: - 地址解析

    func testAddressParsingAddsSchemeButDoesNotGuessSearchTerms() {
        XCTAssertEqual(try? BrowserSession.parseAddress("example.com").get(), url("https://example.com"))
        XCTAssertEqual(try? BrowserSession.parseAddress("http://a.b/c").get(), url("http://a.b/c"))

        // 有空格的输入不被当成搜索词（那是外发决策，不能由便利函数替用户做）。
        switch BrowserSession.parseAddress("hello world") {
        case .success(let parsed):
            XCTAssertEqual(parsed.host, "hello world", "非法主机名交给策略层拒绝，而不是偷偷改成搜索")
        case .failure:
            break
        }

        guard case .failure = BrowserSession.parseAddress("   ") else {
            return XCTFail("空输入应当给出可读失败")
        }
    }

    // MARK: - 会话流水线 + 出网留痕

    func testBlockedNavigationIsRecordedAsDeniedAndKeepsThePage() async throws {
        let log = EgressLog(directoryURL: directory)
        var page = BrowserPage()
        XCTAssertNil(page.url)

        let transition = BrowserSession.navigate(
            page: page,
            to: url("https://tracker.example/pixel"),
            origin: "浏览器 · 页签 1",
            isUserInitiated: false
        )
        page = transition.page

        XCTAssertNil(transition.urlToLoad, "被拒绝的导航不该交给引擎")
        XCTAssertNil(page.url, "被拒绝时页面停在原地")
        XCTAssertNotNil(page.lastError)

        let entry = await BrowserSession.record(transition, origin: "浏览器 · 页签 1", log: log)
        XCTAssertEqual(entry?.kind, .browser)
        XCTAssertEqual(entry?.outcome, .denied)

        let entries = try await log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.target, "https://tracker.example/pixel")
    }

    func testAllowedNavigationIsRecordedWithQueryStripped() async throws {
        let log = EgressLog(directoryURL: directory)
        let transition = BrowserSession.navigate(
            page: BrowserPage(),
            to: url("https://example.com/search?q=secret&token=sk-shouldnotappear"),
            origin: "浏览器 · 页签 1",
            isUserInitiated: true
        )

        XCTAssertEqual(transition.urlToLoad, url("https://example.com/search?q=secret&token=sk-shouldnotappear"))
        XCTAssertEqual(transition.egressOutcome, .allowed)

        await BrowserSession.record(transition, origin: "浏览器 · 页签 1", log: log)
        let entries = try await log.entries()
        XCTAssertEqual(entries.first?.target, "https://example.com/search", "目标里的 query 必须去掉")
        let location = await log.fileLocation()
        XCTAssertFalse(try String(contentsOf: location, encoding: .utf8).contains("sk-shouldnotappear"))
    }

    /// 本地空白页**不产生日志条目** —— 它没有出网；硬记一条只会让"零外发"不好读。
    func testBlankPageProducesNoEgressEntry() async throws {
        let log = EgressLog(directoryURL: directory)
        let transition = BrowserSession.navigate(
            page: BrowserPage(),
            to: url("about:blank"),
            origin: "浏览器 · 页签 1",
            isUserInitiated: true
        )

        XCTAssertNil(transition.urlToLoad)
        XCTAssertFalse(transition.shouldRecord)
        let entry = await BrowserSession.record(transition, origin: "浏览器 · 页签 1", log: log)
        XCTAssertNil(entry)
        let count = try await log.count()
        XCTAssertEqual(count, 0)
    }

    // MARK: - 状态迁移

    func testHistoryEnablesBackAndForwardAndTruncatesForwardBranch() {
        var page = BrowserPage()
        page.beginNavigation(to: url("https://a.example"))
        XCTAssertFalse(page.canGoBack)

        page.beginNavigation(to: url("https://b.example"))
        XCTAssertTrue(page.canGoBack)
        XCTAssertFalse(page.canGoForward)

        XCTAssertEqual(page.goBack(), url("https://a.example"))
        XCTAssertTrue(page.canGoForward)
        XCTAssertEqual(page.goForward(), url("https://b.example"))

        // 后退之后又导航到新地址 → 「前进」分支被丢弃（标准浏览器语义）。
        _ = page.goBack()
        page.beginNavigation(to: url("https://c.example"))
        XCTAssertFalse(page.canGoForward)
    }

    func testHistoryIsBounded() {
        var page = BrowserPage()
        for index in 0..<(BrowserPage.historyLimit + 20) {
            page.beginNavigation(to: url("https://example.com/\(index)"))
        }
        // 只保留最近 historyLimit 条：连续后退的次数不应超过上限。
        var steps = 0
        while page.goBack() != nil { steps += 1 }
        XCTAssertEqual(steps, BrowserPage.historyLimit - 1)
    }

    func testFinishNavigationFallsBackToHostWhenTitleMissing() {
        var page = BrowserPage()
        page.beginNavigation(to: url("https://docs.example/page"))
        XCTAssertTrue(page.isLoading)

        page.finishNavigation(title: nil)
        XCTAssertFalse(page.isLoading)
        XCTAssertEqual(page.title, "docs.example")
    }

    func testFailedNavigationKeepsURLAndRecordsReason() {
        var page = BrowserPage()
        page.beginNavigation(to: url("https://down.example"))
        page.failNavigation(reason: "连接超时")

        XCTAssertEqual(page.url, url("https://down.example"))
        XCTAssertEqual(page.lastError, "连接超时")
        XCTAssertFalse(page.isLoading)
    }
}
