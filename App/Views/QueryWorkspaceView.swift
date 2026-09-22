import SwiftUI
import DoyahCore

struct QueryWorkspaceView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let tab = appState.selectedTab {
                VStack(spacing: 0) {
                    tabBar
                    Divider()
                    QueryEditorView(tab: tab)
                }
            } else {
                ContentUnavailableView(
                    L(.workspaceNoTabsTitle),
                    systemImage: "doc.text",
                    description: Text(L(.workspaceNoTabsDescription))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(appState.tabs) { tab in
                    HStack(spacing: 6) {
                        if tab.isExecuting {
                            ProgressView()
                                .controlSize(.mini)
                        }

                        Button(tab.isDirty ? "\(tab.title) •" : tab.title) {
                            appState.selectedTabID = tab.id
                        }
                        .buttonStyle(.plain)
                        .fontWeight(appState.selectedTabID == tab.id ? .semibold : .regular)

                        Button {
                            appState.closeTab(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.tabs.count <= 1 || tab.isExecuting)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(appState.selectedTabID == tab.id ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                }

                Button {
                    appState.newQueryTab()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct QueryEditorView: View {
    @EnvironmentObject private var appState: AppState
    let tab: QueryTab
    @State private var isSaveQueryPresented = false
    @State private var isGoToLinePresented = false

    var body: some View {
        let diagnostics = self.diagnostics

        VStack(spacing: 0) {
            QueryContextBar()
            Divider()

            QueryToolbar(
                tab: tab,
                connection: tabConnection,
                onOpenFile: {
                    appState.openFileFromPanel()
                },
                onSaveFile: {
                    appState.saveCurrentFile(for: tab.id, forceSaveAs: false)
                },
                onSaveFileAs: {
                    appState.saveCurrentFile(for: tab.id, forceSaveAs: true)
                },
                onSaveQuery: { isSaveQueryPresented = true },
                onRequestGoToLine: { isGoToLinePresented = true },
                onEditCommand: { command in
                    EditorCommandCenter.shared.send(command, to: tab.id)
                }
            )
            Divider()

            // 编辑区在上、下方面板（结果 / 问题 / 输出 / 终端 / 调试控制台）在下，
            // 分隔条可拖拽调整高度；最大化时面板占满，收起时只剩编辑区。
            Group {
                if appState.isLowerPaneMaximized {
                    LowerPaneView(tab: tab, diagnostics: diagnostics)
                } else if appState.isLowerPaneVisible {
                    VSplitView {
                        editorArea(diagnostics)
                            .frame(minHeight: 120, idealHeight: 260)
                        LowerPaneView(tab: tab, diagnostics: diagnostics)
                            .frame(minHeight: 120, idealHeight: 260)
                    }
                } else {
                    editorArea(diagnostics)
                }
            }
        }
        .sheet(isPresented: $isSaveQueryPresented) {
            SaveQuerySheet(
                defaultName: defaultQueryName,
                isDuplicate: { name in
                    appState.savedQueries.contains { $0.name == name }
                },
                onSave: { name in
                    Task { await appState.saveCurrentQuery(for: tab.id, name: name) }
                }
            )
        }
        .sheet(isPresented: $isGoToLinePresented) {
            GoToLineSheet { line, column in
                EditorCommandCenter.shared.send(.goToLine(line: line, column: column), to: tab.id)
            }
        }
    }

    private var defaultQueryName: String {
        appState.suggestedQueryName(for: tab)
    }

    // MARK: - 编辑区

    private func editorArea(_ diagnostics: [SQLDiagnostic]) -> some View {
        VStack(spacing: 0) {
            SQLEditorView(
                text: Binding(
                    get: { tab.sql },
                    set: { appState.updateSQL($0, for: tab.id) }
                ),
                databaseType: tabConnection?.dbType ?? .postgresql,
                diagnostics: diagnostics,
                tabID: tab.id
            )

            if !diagnostics.isEmpty {
                Divider()
                diagnosticsBar(diagnostics)
            }
        }
    }

    // MARK: - 语法检查

    private var diagnostics: [SQLDiagnostic] {
        guard let databaseType = tabConnection?.dbType else { return [] }
        // 超大脚本先不检查，避免每次按键都做全量扫描。
        guard tab.sql.count <= 20_000 else { return [] }
        return SQLLinter(
            databaseType: databaseType,
            language: LocalizationManager.shared.language
        ).analyze(tab.sql)
    }

    private func diagnosticsBar(_ diagnostics: [SQLDiagnostic]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(diagnostics.prefix(3)) { diagnostic in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: diagnostic.severity == .error
                          ? "xmark.octagon.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.orange)
                    Text("\(L(.lintLocation, diagnostic.line, diagnostic.column))：\(diagnostic.message)")
                        .font(.caption)
                        .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.orange)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }

            if diagnostics.count > 3 {
                Text(L(.workspaceMoreDiagnostics, diagnostics.count - 3))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.06))
    }

    // MARK: - 连接

    private var tabConnection: ConnectionConfig? {
        if let connectionID = tab.connectionID,
           let connection = appState.connections.first(where: { $0.id == connectionID }) {
            return connection
        }
        return appState.selectedConnection
    }
}
