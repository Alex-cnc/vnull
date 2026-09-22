import SwiftUI
import PostgresClientCore

/// 查询工作区工具栏。
///
/// 按钮分组：
/// - 文件：打开文件 / 保存（主体直接保存，下拉箭头「另存为…」）
/// - 应用内查询：保存查询（书签）/ 已保存列表
/// - 编辑：查找 / 替换 / 跳到行列 / 缩进 / 清除 / 格式化
/// - 帮助（占位）
/// - 执行 / 停止
/// - 语法检查
///
/// 状态规则（用户明确要求）：
/// - 默认：执行按钮为暗绿色（可点），停止按钮为灰色（不可点）
/// - 点击执行后：两个按钮的状态互换
struct QueryToolbar: View {
    @EnvironmentObject private var appState: AppState
    let tab: QueryTab
    let connection: ConnectionConfig?

    let onOpenFile: () -> Void
    let onSaveFile: () -> Void
    let onSaveFileAs: () -> Void
    let onSaveQuery: () -> Void
    let onRequestGoToLine: () -> Void
    let onEditCommand: (EditorCommand) -> Void

    @State private var isHelpPresented = false

    /// 历史下拉里展示的最大条数（内存历史最多 50 条）。
    private static let historyMenuLimit = 20

    /// 执行按钮的「暗绿色」。
    private let executeGreen = Color(red: 0.10, green: 0.50, blue: 0.10)
    /// 停止按钮的红色。
    private let stopRed = Color(red: 0.80, green: 0.16, blue: 0.16)
    /// 未激活按钮的灰色。
    private let inactiveGray = Color(nsColor: .disabledControlTextColor)

    var body: some View {
        HStack(spacing: 4) {
            openFileButton
            saveFileMenu
            historyMenu
            saveQueryButton
            savedQueriesMenu

            Divider()
                .frame(height: 16)

            editMenu
            runScopeMenu
            safetyMenu
            helpButton

            Divider()
                .frame(height: 16)

            executeButton
            stopButton

            Divider()
                .frame(height: 16)

            checkButton

            if tab.isExecuting {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
            }

            Spacer()

            if let connection {
                connectionInfo(connection)
            } else {
                Label(L(.workspaceUnboundTab), systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 文件

    private var historyMenu: some View {
        Menu {
            if appState.queryHistory.isEmpty {
                Text(L(.historyEmpty))
            } else {
                ForEach(appState.queryHistory.prefix(Self.historyMenuLimit)) { entry in
                    Button {
                        appState.loadHistory(entry, into: tab.id)
                    } label: {
                        Text(historyLabel(for: entry))
                    }
                    .help(L(.historyLoadHelp))
                }

                Divider()

                Button(L(.historyClear)) {
                    appState.clearQueryHistory()
                }
            }
        } label: {
            toolbarIcon("clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L(.historyHelp))
    }

    /// 菜单项文案：单行 SQL 摘要 + 成功/失败标记。
    private func historyLabel(for entry: QueryHistory) -> String {
        let singleLine = entry.sql
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        let preview = singleLine.count > 48 ? String(singleLine.prefix(48)) + "…" : singleLine
        let mark = entry.succeeded ? "✓" : "✗"
        return "\(mark) \(preview)"
    }

    /// 运行范围菜单（FR-EXEC-14）：整篇 / 光标所在语句 / 选中片段。
    private var runScopeMenu: some View {
        Menu {
            Picker(L(.toolbarRunScope), selection: $appState.executionScope) {
                Text(L(.runScopeAll)).tag(ExecutionScope.Mode.all)
                Text(L(.runScopeCurrentStatement)).tag(ExecutionScope.Mode.currentStatement)
                Text(L(.runScopeSelection)).tag(ExecutionScope.Mode.selection)
            }
            .pickerStyle(.inline)

            Divider()

            Text(L(.runScopeHint))
                .font(.caption)
        } label: {
            Label(runScopeTitle, systemImage: runScopeSymbol)
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L(.toolbarRunScope))
    }

    private var runScopeTitle: String {
        switch appState.executionScope {
        case .all: return L(.runScopeAll)
        case .currentStatement: return L(.runScopeCurrentStatement)
        case .selection: return L(.runScopeSelection)
        }
    }

    private var runScopeSymbol: String {
        switch appState.executionScope {
        case .all: return "doc.text"
        case .currentStatement: return "text.cursor"
        case .selection: return "selection.pin.in.out"
        }
    }

    /// 高危语句保护开关（FR-EXEC-16）。
    ///
    /// 放在工具栏而不是深层设置里：这是「执行前会不会拦我一下」的开关，
    /// 用户被拦下时第一反应就是来这里找它。
    private var safetyMenu: some View {
        Menu {
            Toggle(L(.safetySafeMode), isOn: $appState.isSafeModeEnabled)
            Toggle(L(.safetyConfirmAllWrites), isOn: $appState.isConfirmAllWritesEnabled)
                .disabled(!appState.isSafeModeEnabled)

            Divider()

            Text(L(.safetySafeModeHint))
                .font(.caption)
        } label: {
            Image(systemName: appState.isSafeModeEnabled
                  ? "checkmark.shield.fill"
                  : "shield.slash")
                .foregroundStyle(appState.isSafeModeEnabled ? Color.accentColor : inactiveGray)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L(.safetySafeMode))
    }

    private var openFileButton: some View {
        Button(action: onOpenFile) {
            toolbarIcon("folder")
        }
        .buttonStyle(.plain)
        .help(L(.toolbarOpenFileHelp))
        .keyboardShortcut("o", modifiers: .command)
    }

    private var saveFileMenu: some View {
        Menu {
            Button(L(.toolbarSaveAs)) {
                onSaveFileAs()
            }
        } label: {
            toolbarIcon("square.and.arrow.down")
        } primaryAction: {
            onSaveFile()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L(.toolbarSaveFileHelp))
        .keyboardShortcut("s", modifiers: .command)
    }

    // MARK: - 编辑菜单

    private var editMenu: some View {
        Menu {
            Button(L(.editMenuFind)) {
                onEditCommand(.showFind)
            }
            Button(L(.editMenuReplace)) {
                onEditCommand(.showReplace)
            }

            Divider()

            Button(L(.editMenuGoToLine)) {
                onRequestGoToLine()
            }

            Divider()

            Button(L(.editMenuIndent)) {
                onEditCommand(.indent)
            }
            Button(L(.editMenuOutdent)) {
                onEditCommand(.outdent)
            }

            Divider()

            Button(L(.editMenuClear)) {
                onEditCommand(.clear)
            }
            Button(L(.editMenuFormat)) {
                onEditCommand(.format)
            }
        } label: {
            toolbarIcon("pencil")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L(.toolbarEditHelp))
    }

    private var helpButton: some View {
        Button {
            isHelpPresented = true
        } label: {
            toolbarIcon("questionmark.circle")
        }
        .buttonStyle(.plain)
        .help(L(.toolbarHelpHelp))
        .popover(isPresented: $isHelpPresented, arrowEdge: .bottom) {
            Text(L(.helpPlaceholder))
                .font(.callout)
                .padding(12)
                .frame(width: 220)
        }
    }

    // MARK: - 应用内保存查询

    private var saveQueryButton: some View {
        Button {
            onSaveQuery()
        } label: {
            toolbarIcon("bookmark")
        }
        .buttonStyle(.plain)
        .help(L(.toolbarSaveQueryHelp))
        .disabled(tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var savedQueriesMenu: some View {
        Menu {
            if appState.savedQueries.isEmpty {
                Text(L(.toolbarSavedQueriesEmpty))
            } else {
                ForEach(appState.savedQueries) { query in
                    Button {
                        appState.loadSavedQuery(query, into: tab.id)
                    } label: {
                        Text(query.name)
                    }
                }

                Divider()

                Menu(L(.commonDelete)) {
                    ForEach(appState.savedQueries) { query in
                        Button(query.name, role: .destructive) {
                            Task {
                                await appState.deleteSavedQuery(query)
                            }
                        }
                    }
                }
            }
        } label: {
            toolbarIcon("list.bullet")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L(.toolbarSavedQueriesHelp))
    }

    // MARK: - 执行 / 停止 / 检查

    private var executeButton: some View {
        Button {
            appState.startQuery(for: tab.id)
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tab.isExecuting ? inactiveGray : executeGreen)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(.toolbarExecuteHelp))
        .disabled(tab.isExecuting)
        .keyboardShortcut(.return, modifiers: [.command])
    }

    private var stopButton: some View {
        Button {
            Task {
                await appState.cancelQuery(for: tab.id)
            }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tab.isExecuting ? stopRed : inactiveGray)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.isExecuting ? L(.toolbarStopHelp) : L(.toolbarStopIdleHelp))
        .disabled(!tab.isExecuting)
    }

    private var checkButton: some View {
        Button {
            Task {
                await appState.checkSyntax(for: tab.id)
            }
        } label: {
            toolbarIcon("checkmark.circle")
        }
        .buttonStyle(.plain)
        .help(L(.toolbarCheckHelp))
        .disabled(tab.isExecuting)
    }

    // MARK: - 连接信息

    private func connectionInfo(_ connection: ConnectionConfig) -> some View {
        HStack(spacing: 8) {
            let dialect = SQLDialectFactory.make(for: connection.dbType)

            Text(connection.dbType.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(L(.workspaceDelimiter, dialect.statementDelimiter))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let info = appState.serverInfo(for: connection.id) {
                Text("· \(info.database) · \(info.user)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(connection.endpointDescription)
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .lineLimit(1)
        }
    }

    // MARK: - 通用图标按钮样式

    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 22)
            .contentShape(Rectangle())
    }
}
