import SwiftUI
import WebKit

import DoyahCore
import DoyahPlatform

/// 浏览器页签的界面：地址栏 + 前进后退刷新 + 引擎视图（FR-EDIT-34）。
///
/// 版式全部走设计令牌（`Theme` / `Spacing` / `Radius` / `HairlineView`）——
/// 系统语义色与裸间距会被令牌棘轮拦下。
///
/// 这个视图**不做任何导航判断**：地址栏提交交给 `AppState.navigateBrowserTab`，
/// 那里会先过 Core 的策略、再让引擎加载、并把这次出网写进日志。视图只负责显示。
struct BrowserTabView: View {
    let page: BrowserPage

    @EnvironmentObject private var appState: AppState
    @State private var address: String = ""
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HairlineView()
            if let error = page.lastError, !error.isEmpty {
                errorBar(error)
                HairlineView()
            }
            content
        }
        .onAppear { address = page.url?.absoluteString ?? "" }
        .onChange(of: page.url) { _, newValue in
            // 引擎导航后地址栏跟随；正在输入时不打断用户。
            if !isAddressFocused {
                address = newValue?.absoluteString ?? ""
            }
        }
    }

    // MARK: 工具条

    private var toolbar: some View {
        HStack(spacing: Spacing.s) {
            Button {
                let engine = appState.browserEngine(for: page)
                Task { await engine.goBack() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!page.canGoBack)
            .help(L(.browserBack))

            Button {
                let engine = appState.browserEngine(for: page)
                Task { await engine.goForward() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!page.canGoForward)
            .help(L(.browserForward))

            Button {
                let engine = appState.browserEngine(for: page)
                if page.isLoading {
                    engine.stopLoading()
                } else {
                    Task { await engine.reload() }
                }
            } label: {
                Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(page.isLoading ? L(.browserStop) : L(.browserReload))

            TextField(L(.browserAddressPlaceholder), text: $address)
                .textFieldStyle(.roundedBorder)
                .font(Theme.font(.monoSmall))
                .focused($isAddressFocused)
                .onSubmit {
                    appState.navigateBrowserTab(page.id, input: address)
                    isAddressFocused = false
                }

            if page.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.status(.warning))
            Text(message)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if page.url != nil, appState.isBrowserPagePristine(page.id) {
            // 从会话恢复出来的页签：**不自动请求**（否则只是打开应用，数据就已经出网了）。
            // 给出明确的一步：用户点了才加载。
            VStack(spacing: Spacing.s) {
                Image(systemName: "clock.arrow.circlepath")
                    .imageScale(.large)
                    .foregroundStyle(Theme.text(.secondary))
                Text(L(.browserRestoredTitle))
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text(.primary))
                Text(page.url?.absoluteString ?? "")
                    .font(Theme.font(.monoSmall))
                    .foregroundStyle(Theme.text(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L(.browserRestoredHint))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                Button(L(.browserReload)) {
                    let engine = appState.browserEngine(for: page)
                    Task { await engine.reload() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if page.url == nil {
            // 空白页：明确写出「还没有发起任何请求」——空态本身就是承诺的展示。
            ContentUnavailableView(
                L(.browserTitle),
                systemImage: "globe",
                description: Text(L(.browserEmptyHint))
            )
        } else {
            BrowserEngineView(engine: appState.browserEngine(for: page))
        }
    }
}

/// `WKWebView` 的 SwiftUI 承载。
///
/// 只做「把已有引擎的 view 贴进来」这一件事：引擎是按页签缓存的（见 `AppState.browserEngine(for:)`），
/// 所以切换页签、视图重建都不会重新加载页面。
private struct BrowserEngineView: NSViewRepresentable {
    let engine: WebKitBrowserEngine

    func makeNSView(context: Context) -> WKWebView {
        engine.view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 引擎自己管理加载，这里无需同步任何状态。
    }
}
