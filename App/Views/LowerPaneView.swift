import SwiftUI
import DoyahCore

/// 查询窗口**下部**那一块 —— 与 VS Code 底部面板同构的多页签区域。
///
/// 它不是独立新增的区域：原来的 Result（结果表）区域就是这里，现在升成页签，
/// 与 问题 / 输出 / 终端 / 调试控制台 并列。终端页签用的 `TerminalModel` 挂在 App 层，
/// 所以切页签、最大化 / 恢复、乃至切换界面语言都不会把 shell 杀掉。
struct LowerPaneView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var terminal: TerminalModel

    let tab: QueryTab

    /// 折叠态：**只画标题栏**（页签条 + 向上的展开箭头），不画内容。
    ///
    /// 2026-09-24 需求提出者实测：「Terminal 所在那个区域，点击向下那个箭头竟然隐藏不见了，
    /// 所以也就没有办法让它恢复了，应该是折叠到底部，只保留它的标题栏，向上展开的箭头在」。
    /// 原来"收起"是把整块面板从视图树里拿掉 —— 于是连恢复的入口也一起没了（只剩 ⇧⌘J 菜单，
    /// 但那个入口不在这块区域里，看不见自然就想不起来）。现在折叠**只收起内容**，
    /// 标题栏留在底部，箭头翻成向上。
    var isCollapsed: Bool = false

    /// 实时语法诊断（Problem 页签一并展示）。
    ///
    /// 自己算而不是由编辑器传进来：最大化时编辑器整块被盖住，就没人为这里提供诊断了。
    private var diagnostics: [SQLDiagnostic] {
        QueryDiagnostics.analyze(tab: tab, in: appState)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            if !isCollapsed {
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minHeight: isCollapsed ? 0 : 90)
        // 折叠态按**内容自己的理想高度**（标题栏一行）显示：不要让它被拉伸，
        // 也不要写死一个高度 —— 字号 / 语言变了它会自己跟着变。
        .fixedSize(horizontal: false, vertical: isCollapsed)
        .background(.background)
        // 终端**不在这里启动**：`onAppear` 时视图还没布局，只能拿模型默认的 80×24，
        // 于是全屏 TUI 的第一帧就按错的列数排（`dsh-tui` 的 13×40 欢迎鲸鱼会挤在一起）。
        // 启动挪到 `TerminalHostView.layout()`，那里拿得到真实几何。
    }

    // MARK: 页签条

    private var tabStrip: some View {
        HStack(spacing: Spacing.hair) {
            ForEach(LowerPaneTab.allCases) { item in
                tabButton(item)
            }

            Spacer(minLength: 8)

            if appState.lowerPaneTab == .problem || appState.lowerPaneTab == .output {
                iconButton("trash", help: L(.lowerPaneClear)) {
                    appState.clearLowerPaneLog(for: tab.id)
                }
            }

            if appState.lowerPaneTab == .terminal {
                if !terminal.isRunning {
                    Text(L(.terminalStopped))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.warning))
                        .padding(.trailing, 4)
                }
                if let errorText = terminal.errorText {
                    Text(errorText)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.danger))
                        .lineLimit(1)
                        .padding(.trailing, 4)
                }
                iconButton("arrow.clockwise", help: L(.terminalRestart)) {
                    terminal.restart(columns: terminal.screen.columns, rows: terminal.screen.rows)
                }
            }

            if isCollapsed {
                // 折叠态只留一个**向上**的箭头：这是"把它恢复出来"的入口，
                // 必须跟标题栏一起留在屏幕上。
                iconButton("chevron.up", help: L(.lowerPaneExpand)) {
                    appState.isLowerPaneVisible = true
                }
            } else {
                iconButton(
                    appState.isLowerPaneMaximized
                        ? "rectangle.compress.vertical"
                        : "rectangle.expand.vertical",
                    help: appState.isLowerPaneMaximized ? L(.lowerPaneRestore) : L(.lowerPaneMaximize)
                ) {
                    appState.isLowerPaneMaximized.toggle()
                }

                iconButton("chevron.down", help: L(.lowerPaneHide)) {
                    // 收起时同时取消最大化：下次打开回到常规分栏，而不是又占满编辑区。
                    appState.isLowerPaneMaximized = false
                    appState.isLowerPaneVisible = false
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func tabButton(_ item: LowerPaneTab) -> some View {
        let isSelected = appState.lowerPaneTab == item
        let badge = problemBadgeCount(for: item)

        return Button {
            appState.lowerPaneTab = item
            // 折叠态点页签 = 想看里面的内容 → 顺手展开（否则点了没反应，又是一次"点了没用"）。
            if isCollapsed { appState.isLowerPaneVisible = true }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: item.symbolName)
                    .font(Theme.font(.caption))
                Text(L(item.textKey))
                    .font(Theme.font(.caption))
                if badge > 0 {
                    Text("\(badge)")
                        .font(Theme.font(.caption))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.status(.danger).opacity(0.85)))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(isSelected ? .semibold : .regular)
        .help(L(item.textKey))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.font(.caption))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// Problem 页签上的角标：执行错误 + 语法诊断的条数。
    private func problemBadgeCount(for item: LowerPaneTab) -> Int {
        guard item == .problem else { return 0 }
        let errors = tab.problemLog.filter { $0.severity == .error }.count
        return errors + diagnostics.filter { $0.severity == .error }.count
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch appState.lowerPaneTab {
        case .problem:
            problemsContent

        case .output:
            logList(
                tab.outputLog,
                emptyText: L(.lowerPaneOutputEmpty)
            )

        case .terminal:
            VStack(spacing: 0) {
                TerminalView(
                    model: terminal,
                    appearance: appState.terminalAppearance,
                    fontSize: appState.terminalFontSize,
                    cursor: appState.terminalCursorPreference.appearance
                )
                Divider()
                terminalShortcutBar
            }

        case .debugConsole:
            placeholder(
                symbol: "ladybug",
                text: L(.lowerPaneDebugPlaceholder)
            )
        }
    }

    /// 终端页签底部的**快捷键提示条**。
    ///
    /// 为什么必须摆在台面上：终端里"只能用键盘"对不熟快捷键的人是个死结 —— 实测反馈就是
    /// 「能粘贴，但不知道复制按什么，也没有右键菜单」。菜单里虽然带了快捷键显示，
    /// 但得先知道"右键能弹菜单"才看得到；所以把三件事直接写在终端下面：
    /// 复制 / 粘贴 / 全选，以及 ⌥（在接管鼠标的 TUI 里选字）与右键（菜单）。
    private var terminalShortcutBar: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "keyboard")
            Text(L(.terminalShortcutHint))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(Theme.font(.caption))
        .foregroundStyle(Theme.text(.secondary))
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .help(L(.terminalShortcutHint))
    }

    private var problemsContent: some View {
        // 语法诊断（编辑器实时算出来的）+ 执行期错误，按时间先后合并展示。
        VStack(alignment: .leading, spacing: 0) {
            // 超长跳过要显式说出来：否则空态读起来就是"检查过了，没问题"（欺骗性空态）。
            if QueryDiagnostics.isRealtimeAnalysisSkipped(sql: tab.sql) {
                logRow(
                    severity: .warning,
                    timestamp: nil,
                    message: L(.lowerPaneProblemSkipped, "\(sqlRealtimeScanLimit)")
                )
                if !diagnostics.isEmpty || !tab.problemLog.isEmpty { Divider() }
            }

            if !diagnostics.isEmpty {
                ForEach(diagnostics) { diagnostic in
                    logRow(
                        severity: diagnostic.severity == .error ? .error : .warning,
                        timestamp: nil,
                        message: "\(L(.lintLocation, diagnostic.line, diagnostic.column))：\(diagnostic.message)"
                    )
                }
                if !tab.problemLog.isEmpty { Divider() }
            }

            logList(tab.problemLog, emptyText: L(.lowerPaneProblemEmpty), showsEmpty: diagnostics.isEmpty)
        }
    }

    private func logList(
        _ entries: [TabLogEntry],
        emptyText: String,
        showsEmpty: Bool = true
    ) -> some View {
        Group {
            if entries.isEmpty, showsEmpty {
                placeholder(symbol: "checkmark.circle", text: emptyText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            logRow(
                                severity: entry.severity,
                                timestamp: entry.timestamp,
                                message: entry.message
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func logRow(severity: TabLogEntry.Severity, timestamp: Date?, message: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: symbol(for: severity))
                .font(Theme.font(.caption))
                .foregroundStyle(color(for: severity))
                .padding(.top, 1)

            if let timestamp {
                Text(Self.timeFormatter.string(from: timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.text(.tertiary))
            }

            Text(message)
                .font(Theme.font(.caption))
                .foregroundStyle(color(for: severity))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func symbol(for severity: TabLogEntry.Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for severity: TabLogEntry.Severity) -> Color {
        switch severity {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: Spacing.s) {
            Spacer(minLength: 12)
            Image(systemName: symbol)
                .font(Theme.font(.title))
                .foregroundStyle(Theme.text(.tertiary))
            Text(text)
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
