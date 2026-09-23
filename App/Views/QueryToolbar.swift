import SwiftUI
import DoyahCore

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

    var body: some View {
        HStack(spacing: Spacing.xs) {
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
            planButton

            Divider()
                .frame(height: 16)

            // 事务模式（FR-EXEC-15）：紧挨执行按钮 —— 它改变的是「执行会发生什么」。
            TransactionControl(tab: tab)

            if tab.isExecuting {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, Spacing.xs)
            }

            Spacer()

            if let connection {
                connectionInfo(connection)
            } else {
                Label(L(.workspaceUnboundTab), systemImage: "exclamationmark.circle")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
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
        .help(AppShortcut.history.help(L(.historyHelp)))
        .keyboardShortcut(AppShortcut.history.key, modifiers: AppShortcut.history.modifiers)
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
            scopeButton(L(.runScopeAll), mode: .all, shortcut: .scopeAll)
            scopeButton(L(.runScopeCurrentStatement), mode: .currentStatement, shortcut: .scopeCurrentStatement)
            scopeButton(L(.runScopeSelection), mode: .selection, shortcut: .scopeSelection)

            Divider()

            Text(L(.runScopeHint))
                .font(Theme.font(.caption))
        } label: {
            Label(runScopeTitle, systemImage: runScopeSymbol)
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L(.toolbarRunScope) + "（" + AppShortcut.scopeAll.display + " / "
              + AppShortcut.scopeCurrentStatement.display + " / "
              + AppShortcut.scopeSelection.display + "）")
    }

    /// 运行范围的一个选项：显示当前是否生效 + 快捷键。
    private func scopeButton(
        _ title: String,
        mode: ExecutionScope.Mode,
        shortcut: AppShortcut
    ) -> some View {
        Button {
            appState.executionScope = mode
        } label: {
            if appState.executionScope == mode {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
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
                .keyboardShortcut(AppShortcut.safeMode.key, modifiers: AppShortcut.safeMode.modifiers)

            Toggle(L(.safetyConfirmAllWrites), isOn: $appState.isConfirmAllWritesEnabled)
                .keyboardShortcut(
                    AppShortcut.confirmAllWrites.key,
                    modifiers: AppShortcut.confirmAllWrites.modifiers
                )
                .disabled(!appState.isSafeModeEnabled)

            Divider()

            Text(L(.safetySafeModeHint))
                .font(Theme.font(.caption))
        } label: {
            Image(systemName: appState.isSafeModeEnabled
                  ? "checkmark.shield.fill"
                  : "shield.slash")
                .foregroundStyle(appState.isSafeModeEnabled ? Theme.accentColor : Theme.text(.disabled))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(AppShortcut.safeMode.help(L(.safetySafeMode)))
    }

    /// 帮助面板：直接由 `AppShortcut` 生成完整快捷键表，
    /// 与按钮上挂的是同一份定义，不会出现「提示与实键不一致」。
    private var shortcutList: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.helpShortcutsTitle))
                .font(Theme.font(.bodyStrong))

            ForEach(Array(Self.shortcutRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    Text(L(row.title))
                        .font(Theme.font(.caption))
                        .frame(width: 190, alignment: .leading)
                    Text(row.shortcut.display)
                        .font(Theme.font(.mono))
                        .foregroundStyle(Theme.text(.secondary))
                }
            }
        }
        .padding(Spacing.l)
        .frame(width: 360)
    }

    /// 帮助面板里展示的条目（顺序即阅读顺序）。
    private static var shortcutRows: [(title: LKey, shortcut: AppShortcut)] {
        [
            (.toolbarExecuteHelp, .execute),
            (.toolbarStopHelp, .stop),
            (.toolbarCheckHelp, .check),
            (.toolbarPlanHelp, .executionPlan),
            (.toolbarOpenFileHelp, .openFile),
            (.toolbarSaveFileHelp, .saveFile),
            (.toolbarSaveAs, .saveFileAs),
            (.toolbarSaveQueryHelp, .saveQuery),
            (.toolbarSavedQueriesHelp, .savedQueries),
            (.historyHelp, .history),
            (.editMenuFind, .find),
            (.editMenuReplace, .replace),
            (.editMenuGoToLine, .goToLine),
            (.editMenuIndent, .indent),
            (.editMenuOutdent, .outdent),
            (.editMenuClear, .clearEditor),
            (.editMenuFormat, .format),
            (.runScopeAll, .scopeAll),
            (.runScopeCurrentStatement, .scopeCurrentStatement),
            (.runScopeSelection, .scopeSelection),
            (.safetySafeMode, .safeMode),
            (.safetyConfirmAllWrites, .confirmAllWrites),
            (.menuAgentAudit, .agentAudit),
            (.menuDataTask, .dataTask),
            (.lowerPaneToggle, .terminal),
            (.archiveTitle, .archive),
            (.toolbarHelpHelp, .help)
        ]
    }

    private var openFileButton: some View {
        Button(action: onOpenFile) {
            toolbarIcon("folder")
        }
        .buttonStyle(.plain)
        .help(AppShortcut.openFile.help(L(.toolbarOpenFileHelp)))
        .keyboardShortcut(AppShortcut.openFile.key, modifiers: AppShortcut.openFile.modifiers)
    }

    private var saveFileMenu: some View {
        Menu {
            Button(L(.toolbarSaveAs)) {
                onSaveFileAs()
            }
            .keyboardShortcut(AppShortcut.saveFileAs.key, modifiers: AppShortcut.saveFileAs.modifiers)
        } label: {
            toolbarIcon("square.and.arrow.down")
        } primaryAction: {
            onSaveFile()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(AppShortcut.saveFile.help(L(.toolbarSaveFileHelp)))
        .keyboardShortcut(AppShortcut.saveFile.key, modifiers: AppShortcut.saveFile.modifiers)
    }

    // MARK: - 编辑菜单

    private var editMenu: some View {
        Menu {
            Button(L(.editMenuFind)) {
                onEditCommand(.showFind)
            }
            .keyboardShortcut(AppShortcut.find.key, modifiers: AppShortcut.find.modifiers)

            Button(L(.editMenuReplace)) {
                onEditCommand(.showReplace)
            }
            .keyboardShortcut(AppShortcut.replace.key, modifiers: AppShortcut.replace.modifiers)

            Divider()

            Button(L(.editMenuGoToLine)) {
                onRequestGoToLine()
            }
            .keyboardShortcut(AppShortcut.goToLine.key, modifiers: AppShortcut.goToLine.modifiers)

            Divider()

            Button(L(.editMenuIndent)) {
                onEditCommand(.indent)
            }
            .keyboardShortcut(AppShortcut.indent.key, modifiers: AppShortcut.indent.modifiers)

            Button(L(.editMenuOutdent)) {
                onEditCommand(.outdent)
            }
            .keyboardShortcut(AppShortcut.outdent.key, modifiers: AppShortcut.outdent.modifiers)

            Divider()

            Button(L(.editMenuClear)) {
                onEditCommand(.clear)
            }
            .keyboardShortcut(AppShortcut.clearEditor.key, modifiers: AppShortcut.clearEditor.modifiers)

            Button(L(.editMenuFormat)) {
                onEditCommand(.format)
            }
            .keyboardShortcut(AppShortcut.format.key, modifiers: AppShortcut.format.modifiers)
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
        .help(AppShortcut.help.help(L(.toolbarHelpHelp)))
        .keyboardShortcut(AppShortcut.help.key, modifiers: AppShortcut.help.modifiers)
        .popover(isPresented: $isHelpPresented, arrowEdge: .bottom) {
            shortcutList
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
        .help(AppShortcut.saveQuery.help(L(.toolbarSaveQueryHelp)))
        .keyboardShortcut(AppShortcut.saveQuery.key, modifiers: AppShortcut.saveQuery.modifiers)
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
        .help(AppShortcut.savedQueries.help(L(.toolbarSavedQueriesHelp)))
        .keyboardShortcut(AppShortcut.savedQueries.key, modifiers: AppShortcut.savedQueries.modifiers)
    }

    // MARK: - 执行 / 停止 / 检查

    private var executeButton: some View {
        Button {
            appState.startQuery(for: tab.id)
        } label: {
            Image(systemName: "play.fill")
                .font(Theme.font(.icon)).fontWeight(.bold)
                .foregroundStyle(tab.isExecuting ? Theme.text(.disabled) : Theme.status(.success))
                .frame(width: Metrics.toolbarButtonWidth, height: Metrics.toolbarButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AppShortcut.execute.help(L(.toolbarExecuteHelp)))
        .disabled(tab.isExecuting)
        .keyboardShortcut(AppShortcut.execute.key, modifiers: AppShortcut.execute.modifiers)
    }

    private var stopButton: some View {
        Button {
            Task {
                await appState.cancelQuery(for: tab.id)
            }
        } label: {
            Image(systemName: "stop.fill")
                .font(Theme.font(.icon)).fontWeight(.bold)
                .foregroundStyle(tab.isExecuting ? Theme.status(.danger) : Theme.text(.disabled))
                .frame(width: Metrics.toolbarButtonWidth, height: Metrics.toolbarButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AppShortcut.stop.help(tab.isExecuting ? L(.toolbarStopHelp) : L(.toolbarStopIdleHelp)))
        .keyboardShortcut(AppShortcut.stop.key, modifiers: AppShortcut.stop.modifiers)
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
        .help(AppShortcut.check.help(L(.toolbarCheckHelp)))
        .keyboardShortcut(AppShortcut.check.key, modifiers: AppShortcut.check.modifiers)
        .disabled(tab.isExecuting)
    }

    /// 执行计划按钮（FR-DIAG-01）。
    private var planButton: some View {
        Button {
            appState.isExecutionPlanPresented = true
            Task { await appState.runExecutionPlan(for: tab.id) }
        } label: {
            toolbarIcon("list.bullet.indent")
        }
        .buttonStyle(.plain)
        .help(AppShortcut.executionPlan.help(L(.toolbarPlanHelp)))
        .keyboardShortcut(AppShortcut.executionPlan.key, modifiers: AppShortcut.executionPlan.modifiers)
        .disabled(tab.isExecuting)
    }

    // MARK: - 连接信息

    private func connectionInfo(_ connection: ConnectionConfig) -> some View {
        HStack(spacing: 8) {
            let dialect = SQLDialectFactory.make(for: connection.dbType)

            Text(connection.dbType.displayName)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            Text(L(.workspaceDelimiter, dialect.statementDelimiter))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))

            if let info = appState.serverInfo(for: connection.id) {
                Text("· \(info.database) · \(info.user)")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                    .lineLimit(1)
            }

            Text(connection.endpointDescription)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .lineLimit(1)
        }
    }

    // MARK: - 通用图标按钮样式

    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(Theme.font(.icon)).fontWeight(.semibold)
            .foregroundStyle(Theme.text(.secondary))
            .frame(width: Metrics.toolbarButtonWidth, height: Metrics.toolbarButtonHeight)
            .contentShape(Rectangle())
    }
}
