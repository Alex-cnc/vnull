import SwiftUI
import DoyahCore

struct QueryWorkspaceView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let tab = appState.selectedTab {
                if appState.isLowerPaneVisible, appState.isLowerPaneMaximized {
                    // 最大化：**连查询页签条一起盖住** —— 上下文栏、工具栏、页签条全部让位，
                    // 整个工作区看起来就是面板本身（终端占满时就是一个完整的终端界面）。
                    // 恢复按钮在面板自己的页签条上，所以不会"盖住就出不来"。
                    LowerPaneView(tab: tab)
                } else {
                    VStack(spacing: 0) {
                        tabBar
                        Divider()
                        QueryEditorView(tab: tab)
                    }
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
        let diagnostics = QueryDiagnostics.analyze(tab: tab, in: appState)

        VStack(spacing: 0) {
            QueryContextBar()
            Divider()

            QueryToolbar(
                tab: tab,
                connection: appState.connection(for: tab),
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

            // 编辑区在上、下方面板在下，分隔条可拖拽调整高度；收起时只剩编辑区。
            // （最大化态在 `QueryWorkspaceView` 里处理 —— 它还要盖住页签条。）
            if appState.isLowerPaneVisible {
                VSplitView {
                    editorArea(diagnostics)
                        .frame(minHeight: 120, idealHeight: 260)
                    LowerPaneView(tab: tab)
                        .frame(minHeight: 120, idealHeight: 260)
                }
            } else {
                editorArea(diagnostics)
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
                databaseType: appState.connection(for: tab)?.dbType ?? .postgresql,
                diagnostics: diagnostics,
                tabID: tab.id
            )

            if !diagnostics.isEmpty {
                Divider()
                diagnosticsBar(diagnostics)
            }
        }
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
}
