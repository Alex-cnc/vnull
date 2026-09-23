import Foundation

/// 一次导航的裁决结果（FR-EDIT-34）。
public enum BrowserNavigationDecision: Equatable, Sendable {
    /// 允许加载。
    case allow(URL)
    /// 拒绝加载，`reason` 是可直接显示给用户的原因。
    case block(reason: String)
}

/// 浏览器页签的导航策略。
///
/// **行为契约（与渲染引擎无关，见需求书 FR-EDIT-34 / §10.9 P-14）**：
///
/// 1. **默认不加载远程内容** —— 新页签只打开空白页；任何远程加载都必须由**用户的显式动作**
///    发起（在地址栏回车、点链接）。引擎里的自动加载（恢复会话、预取、脚本发起的跳转）
///    一律拒绝。
/// 2. 只放行 `http` / `https`；`about:blank` 放行（它就是"空白页"）。`javascript:`、
///    `data:`、`file:` 一律拒绝 —— 前两者是脚本注入面，后者会绕过"文件访问必须经授权目录"
///    这条既有纪律（FR-AI-08 的授权模型）。
/// 3. **拒绝也要留痕**：每次裁决都会在外发日志里留下 `allowed` / `denied`。
///
/// 为什么把策略放在 Core 而不是塞进 `WKWebView` 的代理里：这是**契约**，
/// 换引擎（Linux/其他）时策略必须一字不差；塞进平台代码就变成"每个平台各写一份"。
public enum BrowserNavigationPolicy {

    /// 允许被加载的 URL scheme。
    public static let allowedSchemes: Set<String> = ["http", "https"]

    public static func decide(url: URL?, isUserInitiated: Bool) -> BrowserNavigationDecision {
        guard let url else {
            // 空白页：没有 URL 也是一种正常状态（新页签就是这个样子）。
            return .block(reason: "没有要加载的地址")
        }

        let scheme = (url.scheme ?? "").lowercased()

        if scheme == "about", url.absoluteString.lowercased() == "about:blank" {
            return .allow(url)
        }

        if !isUserInitiated {
            return .block(reason: "默认不加载远程内容：只有你主动输入地址或在页面上点击，才会发起请求")
        }

        guard allowedSchemes.contains(scheme) else {
            return .block(reason: "只允许 http / https；\(scheme.isEmpty ? "未知协议" : scheme + ":") 已被拒绝")
        }

        guard url.host != nil else {
            return .block(reason: "地址缺少主机名")
        }

        return .allow(url)
    }
}

/// 浏览器页签的状态模型（值类型，可持久化、可单测）。
///
/// 它只记状态与历史，不做任何渲染 —— 渲染是平台实现的事（契约见 `BrowserEngine`）。
public struct BrowserPage: Identifiable, Equatable, Sendable, Codable {
    /// 页签 id。
    public let id: UUID
    /// 当前地址（空白页时为 `nil`）。
    public private(set) var url: URL?
    /// 页面标题（引擎回报；未回报时用主机名兜底）。
    public private(set) var title: String
    /// 是否正在加载。
    public private(set) var isLoading: Bool
    /// 最近一次失败 / 被拒绝的原因（可读）。
    public private(set) var lastError: String?

    private var history: [URL]
    private var historyIndex: Int

    /// 历史栈上限：浏览器的"后退"不需要无限记忆，但不能太小（在同一个站内跳几十次是常态）。
    public static let historyLimit = 50

    public init(id: UUID = UUID(), url: URL? = nil, title: String = "新页签") {
        self.id = id
        self.url = url
        self.title = title
        self.isLoading = false
        self.lastError = nil
        self.history = url.map { [$0] } ?? []
        self.historyIndex = url == nil ? -1 : 0
    }

    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    /// 开始导航（策略已放行）。
    public mutating func beginNavigation(to url: URL) {
        self.url = url
        self.isLoading = true
        self.lastError = nil

        // 截断前进分支：这是浏览器的标准语义（新导航丢弃"前进"里的旧路径）。
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(url)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        historyIndex = history.count - 1
    }

    /// 导航被策略或引擎拒绝：**不改地址**，只记原因（用户看到的是"还在原页面 + 一句为什么"）。
    public mutating func rejectNavigation(reason: String) {
        isLoading = false
        lastError = reason
    }

    public mutating func finishNavigation(title: String?) {
        isLoading = false
        if let title, !title.isEmpty {
            self.title = title
        } else if let host = url?.host {
            self.title = host
        }
    }

    public mutating func failNavigation(reason: String) {
        isLoading = false
        lastError = reason
    }

    /// 后退 / 前进：返回要加载的地址（`nil` = 不能走）。
    public mutating func goBack() -> URL? {
        guard canGoBack else { return nil }
        historyIndex -= 1
        url = history[historyIndex]
        return url
    }

    public mutating func goForward() -> URL? {
        guard canGoForward else { return nil }
        historyIndex += 1
        url = history[historyIndex]
        return url
    }
}

/// 平台渲染引擎必须实现的接口（`WKWebView` / WebKitGTK / 其他）。
///
/// **契约**：引擎只负责"把内容渲染出来 + 回报状态"，**所有导航决策都必须先经过
/// `BrowserNavigationPolicy`，所有出网都必须记进 `EgressLog`**。
/// 引擎自己不得决定"要不要加载" —— 那是策略层的事，否则两个平台会长出两套规则。
public protocol BrowserEngine: AnyObject, Sendable {
    var pageID: UUID { get }

    /// 状态变化回调（实现应保证在主线程调用）。
    @MainActor func setUpdateHandler(_ handler: @escaping @MainActor (BrowserPage) -> Void)

    /// 加载（调用方已通过策略裁决）。
    @MainActor func load(_ url: URL)
    @MainActor func goBack()
    @MainActor func goForward()
    @MainActor func reload()
    @MainActor func stopLoading()
}

/// 浏览器会话：把「地址解析 → 策略裁决 → 状态迁移 → **出网留痕**」串成一条纯函数流水线。
///
/// 为什么要有这一层（而不是让视图自己拼）：`FR-EDIT-34` 的验收里写着「每条出网请求都进
/// 同一份外发日志」。如果留痕散在视图的按钮回调里，漏一处就是一个没有记录的出网。
/// 做成**返回"该记什么"的纯函数**之后：
///   · 平台视图只负责"把这个 URL 交给引擎"，记什么由这里说了算；
///   · 而且这段逻辑可以在单测里跑，不需要真的开一个 WebView。
/// 地址解析失败的原因（可直接显示）。
public struct BrowserAddressError: Error, Equatable, Sendable, LocalizedError {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

public enum BrowserSession {

    /// 一次导航请求的结果：新状态 + 要加载的地址（`nil` = 拦截）+ 要写进外发日志的一条记录。
    public struct Transition: Equatable, Sendable {
        public var page: BrowserPage
        /// 非 `nil` 时，视图应当让引擎加载它。
        public var urlToLoad: URL?
        public var egressOutcome: EgressOutcome
        public var egressTarget: String
        public var egressDetail: String?
        /// 是否要往日志里写一条。
        ///
        /// `about:blank` 这类**本地页面根本没有出网**，既不是 `allowed` 也不是 `denied` ——
        /// 硬记一条会把日志塞满噪音，反而让"零外发"这件事变得不好读。
        public var shouldRecord: Bool
    }

    /// 用户地址栏输入 → URL。
    ///
    /// 只做最小纠偏（补 `https://`），不做"猜搜索词"——猜错会把用户输入发去搜索引擎，
    /// 那是**外发决策**，不该由一个便利函数替他做。
    public static func parseAddress(_ input: String) -> Result<URL, BrowserAddressError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(BrowserAddressError("请输入地址"))
        }
        if trimmed.lowercased() == "about:blank" {
            return .success(URL(string: "about:blank")!)
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), url.host != nil else {
            return .failure(BrowserAddressError("看不懂这个地址：\(trimmed)"))
        }
        return .success(url)
    }

    /// 导航请求（地址栏回车、页面内点击、或引擎的自动加载）。
    ///
    /// - Parameters:
    ///   - origin: 触发来源（例如「浏览器 · 页签 1」），会原样进外发日志。
    ///   - isUserInitiated: 是否由用户的显式动作发起。引擎的自动加载必须传 `false`。
    public static func navigate(
        page: BrowserPage,
        to url: URL?,
        origin: String,
        isUserInitiated: Bool
    ) -> Transition {
        let decision = BrowserNavigationPolicy.decide(url: url, isUserInitiated: isUserInitiated)
        let target = EgressTarget.sanitize(url?.absoluteString ?? "")

        switch decision {
        case .block(let reason):
            var blocked = page
            blocked.rejectNavigation(reason: reason)
            return Transition(
                page: blocked,
                urlToLoad: nil,
                egressOutcome: .denied,
                egressTarget: target,
                egressDetail: reason,
                shouldRecord: true
            )

        case .allow(let allowed):
            // `about:blank` 是本地空白页，没有出网 —— 别往日志里塞噪音（否则"零外发"就不好读了）。
            let isLocal = allowed.absoluteString.lowercased() == "about:blank"
            var next = page
            if !isLocal {
                next.beginNavigation(to: allowed)
            }
            return Transition(
                page: next,
                urlToLoad: isLocal ? nil : allowed,
                egressOutcome: .allowed,
                egressTarget: target,
                egressDetail: nil,
                shouldRecord: !isLocal
            )
        }
    }

    /// 把一次 Transition 记进外发日志（**由调用方 await**，保持本类型是纯函数）。
    @discardableResult
    public static func record(
        _ transition: Transition,
        origin: String,
        log: EgressLog = .shared
    ) async -> EgressEntry? {
        guard transition.shouldRecord else { return nil }
        return await log.record(
            kind: .browser,
            target: transition.egressTarget,
            origin: origin,
            outcome: transition.egressOutcome,
            detail: transition.egressDetail
        )
    }
}
