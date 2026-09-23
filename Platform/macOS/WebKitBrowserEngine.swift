import Foundation
import WebKit

import DoyahCore

/// macOS 侧的浏览器引擎实现：`WKWebView`（FR-EDIT-34）。
///
/// **这个类只做三件事**：渲染、回报状态、把每次导航决策交给 Core 的策略。
/// 它**不自己判断"要不要加载"** —— 那是 `BrowserNavigationPolicy` 的事（换引擎时规则必须一字不差）。
///
/// 安全属性（与契约一致）：
/// 1. **默认不加载远程内容**：只有地址栏回车（走 `load(_:)`）或页面内点击链接才放行；
///    引擎的自动跳转 / 会话恢复 / 预取一律按非用户发起处理 → 拒绝 + 留痕；
/// 2. **不注入任何脚本桥**：不注册 `WKScriptMessageHandler`，网页拿不到客户端能力；
/// 3. **独立数据存储**：默认用非持久化存储，不与 SQL 客户端的连接信息、凭据混放；
/// 4. 每次裁决（放行 / 拦截）都写进统一外发日志。
///
/// **已知边界**：`WKWebView` 的公开 API 不暴露单个子资源请求，所以日志是**导航级**的
/// （见 `Docs/design/浏览器页签-设计说明.md` §4）。要做到子资源级只能自建本地代理，
/// 体量与风险都不合算 —— 这一条写在需求书里，不假装做到。
@MainActor
public final class WebKitBrowserEngine: NSObject, BrowserEngine {

    public let pageID: UUID

    /// 交给 SwiftUI 承载的视图。
    public let view: WKWebView

    private let origin: String
    private let log: EgressLog
    private var page: BrowserPage
    private var updateHandler: (@MainActor (BrowserPage) -> Void)?

    /// 本次加载是否由**应用层显式发起**（地址栏 / 前进后退按钮）。
    ///
    /// 为什么需要它：`WKNavigationAction.navigationType` 里，地址栏导航会落成 `.other` ——
    /// 与"脚本自己发起的跳转"同类。只靠它判断会把地址栏也当成自动加载挡掉（功能坏掉），
    /// 或者反过来把脚本跳转放过去（安全属性坏掉）。所以由我们自己标记"这是用户按的"。
    private var explicitLoadRequested = false

    public init(
        pageID: UUID = UUID(),
        origin: String = "浏览器 · 页签",
        log: EgressLog = .shared,
        websiteDataStore: WKWebsiteDataStore = .nonPersistent()
    ) {
        self.pageID = pageID
        self.origin = origin
        self.log = log
        self.page = BrowserPage(id: pageID)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        // 刻意不注册任何 WKScriptMessageHandler：网页不该有通往客户端能力的桥。

        self.view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        self.view.navigationDelegate = self
    }

    public func setUpdateHandler(_ handler: @escaping @MainActor (BrowserPage) -> Void) {
        updateHandler = handler
        handler(page)
    }

    public func load(_ url: URL) {
        // 地址栏导航：标记为"用户显式发起"，然后同样**经过策略**（策略是唯一出口）。
        explicitLoadRequested = true
        navigate(to: url, isUserInitiated: true)
    }

    public func goBack() {
        explicitLoadRequested = true
        guard let url = page.goBack() else { return }
        view.load(URLRequest(url: url))
        publish()
    }

    public func goForward() {
        explicitLoadRequested = true
        guard let url = page.goForward() else { return }
        view.load(URLRequest(url: url))
        publish()
    }

    public func reload() {
        explicitLoadRequested = true
        if let url = page.url {
            view.load(URLRequest(url: url))
        } else {
            view.reload()
        }
    }

    public func stopLoading() {
        view.stopLoading()
        page.rejectNavigation(reason: page.lastError ?? "")
        page.finishNavigation(title: nil)
        publish()
    }

    /// 统一的导航入口：裁决 → 留痕 → 交给 WebView（或就地拒绝）。
    private func navigate(to url: URL, isUserInitiated: Bool) {
        let transition = BrowserSession.navigate(
            page: page,
            to: url,
            origin: origin,
            isUserInitiated: isUserInitiated
        )
        page = transition.page
        publish()

        // 留痕（拦截与放行都记）—— 这是"每条出网都进日志"的落点。
        Task { [transition, origin, log] in
            await BrowserSession.record(transition, origin: origin, log: log)
        }

        guard let loadURL = transition.urlToLoad else { return }
        view.load(URLRequest(url: loadURL))
    }

    private func publish() {
        updateHandler?(page)
    }
}

// MARK: - WKNavigationDelegate

extension WebKitBrowserEngine: WKNavigationDelegate {

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url

        // 应用层显式动作（地址栏 / 后退前进 / 刷新）已经在 `load(_:)` 里裁决过并记过日志，
        // 这里放行即可 —— 但仍然只在"确实标记过"时放行，不让标记无限期生效。
        if explicitLoadRequested {
            explicitLoadRequested = false
            decisionHandler(.allow)
            return
        }

        let userInitiated = Self.isUserInitiated(navigationAction.navigationType)
        let transition = BrowserSession.navigate(
            page: page,
            to: url,
            origin: origin,
            isUserInitiated: userInitiated
        )
        page = transition.page
        publish()

        Task { [transition, origin, log] in
            await BrowserSession.record(transition, origin: origin, log: log)
        }

        decisionHandler(transition.urlToLoad == nil ? .cancel : .allow)
    }

    /// 由 `navigationType` 判断是否用户发起。
    ///
    /// `.other` **不算**用户发起：脚本跳转、meta 刷新、预取都落在这里。
    /// 这偏保守，代价是某些站点内部的合法跳转会被拦 —— 宁可拦掉让用户手动点一次，
    /// 也不要让"默认不加载远程内容"这条保证失效。
    static func isUserInitiated(_ type: WKNavigationType) -> Bool {
        switch type {
        case .linkActivated, .formSubmitted, .formResubmitted, .backForward:
            return true
        case .other, .reload:
            return false
        @unknown default:
            return false
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        page.finishNavigation(title: nil)      // 先结束上一轮的加载态
        publish()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        page.finishNavigation(title: webView.title)
        publish()
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        page.failNavigation(reason: error.localizedDescription)
        publish()
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        page.failNavigation(reason: error.localizedDescription)
        publish()
    }
}
