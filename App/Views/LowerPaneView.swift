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

    /// 实时语法诊断（Problem 页签一并展示）。
    ///
    /// 自己算而不是由编辑器传进来：最大化时编辑器整块被盖住，就没人为这里提供诊断了。
    private var diagnostics: [SQLDiagnostic] {
        QueryDiagnostics.analyze(tab: tab, in: appState)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 120)
        .background(.background)
        .onAppear {
            terminal.startIfNeeded(columns: terminal.screen.columns, rows: terminal.screen.rows)
        }
    }

    // MARK: 页签条

    private var tabStrip: some View {
        HStack(spacing: 2) {
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
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.trailing, 4)
                }
                if let errorText = terminal.errorText {
                    Text(errorText)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .padding(.trailing, 4)
                }
                iconButton("arrow.clockwise", help: L(.terminalRestart)) {
                    terminal.restart(columns: terminal.screen.columns, rows: terminal.screen.rows)
                }
            }

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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func tabButton(_ item: LowerPaneTab) -> some View {
        let isSelected = appState.lowerPaneTab == item
        let badge = problemBadgeCount(for: item)

        return Button {
            appState.lowerPaneTab = item
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.symbolName)
                    .font(.caption)
                Text(L(item.textKey))
                    .font(.caption)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
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
                .font(.caption)
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
        case .result:
            VStack(spacing: 0) {
                // 结果集的「出处」（第 N 条语句 · X 行 × Y 列）。
                // 这是结果集自己的元信息，所以留在结果页签里，而不是再往 Output 日志抄一遍。
                if let provenance = selectedProvenance {
                    Text(provenance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    Divider()
                }

                ResultTableView(
                    result: tab.result,
                    resultCount: tab.results.count,
                    selectedIndex: tab.selectedResultIndex,
                    onSelectResult: { index in
                        appState.selectResult(index, for: tab.id)
                    },
                    isExecuting: tab.isExecuting,
                    onExport: { format in
                        Task { await appState.exportResult(for: tab.id, format: format) }
                    }
                )
            }

        case .problem:
            problemsContent

        case .output:
            logList(
                tab.outputLog,
                emptyText: L(.lowerPaneOutputEmpty)
            )

        case .terminal:
            TerminalView(model: terminal)

        case .debugConsole:
            placeholder(
                symbol: "ladybug",
                text: L(.lowerPaneDebugPlaceholder)
            )
        }
    }

    /// 当前选中结果集的「出处」；没有（例如刚清空）时为 nil。
    private var selectedProvenance: String? {
        let index = tab.selectedResultIndex
        guard tab.resultSummaries.indices.contains(index) else { return nil }
        let value = tab.resultSummaries[index]
        return value.isEmpty ? nil : value
    }

    private var problemsContent: some View {
        // 语法诊断（编辑器实时算出来的）+ 执行期错误，按时间先后合并展示。
        VStack(alignment: .leading, spacing: 0) {
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
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol(for: severity))
                .font(.caption)
                .foregroundStyle(color(for: severity))
                .padding(.top, 1)

            if let timestamp {
                Text(Self.timeFormatter.string(from: timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(message)
                .font(.caption)
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
        VStack(spacing: 6) {
            Spacer(minLength: 12)
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
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
