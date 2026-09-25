import SwiftUI
import AppKit
import DoyahCore

/// 工作区**自己的**编辑区（FR-EDIT-35 / 36）。
///
/// 与数据库那套的关系：活动栏切到「工作区」时，右边显示的就是这里 ——
/// 页签集与数据库的 SQL 页签**互不干扰**（"我在写代码"和"我在跑查询"是两种工作）。
struct WorkspaceAreaView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var tabs: WorkspaceTabsModel

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            messageBar
        }
        .background(Theme.surface(.content))
    }

    // MARK: 页签条

    private var tabStrip: some View {
        HStack(spacing: Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(tabs.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.vertical, Spacing.hair)
            }

            Spacer(minLength: Spacing.s)

            if let tab = tabs.selectedTab, !tab.isHome {
                Text(L(.workspaceLanguageLabel, tab.language.displayName))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                    .lineLimit(1)

                Button {
                    tabs.save(tab.id)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(Theme.font(.caption))
                }
                .buttonStyle(.borderless)
                .disabled(!tab.isDirty)
                .help(L(.workspaceSaveButton))
            }

            Button {
                openFileFromPanel()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(Theme.font(.caption))
            }
            .buttonStyle(.borderless)
            .help(L(.workspaceOpenFileButton))
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
    }

    private func tabButton(_ tab: WorkspaceTab) -> some View {
        let isSelected = tab.id == tabs.selectedTab?.id
        return HStack(spacing: Spacing.xs) {
            Image(systemName: tab.isHome ? "house" : "doc.text")
                .font(Theme.font(.caption))
                .foregroundStyle(isSelected ? Theme.accentColor : Theme.text(.secondary))

            Text(tab.title)
                .font(Theme.font(.caption))
                .lineLimit(1)
                .fontWeight(isSelected ? .semibold : .regular)

            if tab.isDirty {
                Circle()
                    .fill(Theme.status(.warning))
                    .frame(width: 6, height: 6)
                    .help(L(.workspaceDirtyTag))
            }

            // Home 关不掉（工作区的落脚点），所以它没有关闭按钮。
            if !tab.isHome {
                Button {
                    tabs.close(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.font(.caption))
                }
                .buttonStyle(.borderless)
                .help(L(.workspaceCloseTab))
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.hair)
        .background(
            RoundedRectangle(cornerRadius: Radius.badge)
                .fill(isSelected ? Theme.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { tabs.select(tab.id) }
        .help(tab.path ?? tab.title)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let tab = tabs.selectedTab {
            if tab.isHome {
                WorkspaceHomeView()
            } else {
                VStack(spacing: 0) {
                    CodeEditorView(
                        tabID: tab.id,
                        text: tab.content,
                        language: tab.language,
                        onTextChange: { text in tabs.updateContent(text, for: tab.id) },
                        onSave: { tabs.save(tab.id) }
                    )
                    Divider()
                    Text(L(.workspaceEditorHint))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.tertiary))
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, Spacing.hair)
                }
            }
        }
    }

    /// 底部消息条：错误优先，其次一次性提示。**不静默**——打不开、存不下都要说出来。
    @ViewBuilder
    private var messageBar: some View {
        if let error = tabs.errorText {
            messageRow(text: error, symbol: "exclamationmark.triangle.fill", tone: Theme.status(.danger)) {
                tabs.errorText = nil
            }
        } else if let notice = tabs.noticeText {
            messageRow(text: notice, symbol: "checkmark.circle", tone: Theme.status(.success)) {
                tabs.noticeText = nil
            }
        }
    }

    private func messageRow(text: String, symbol: String, tone: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol)
                .font(Theme.font(.caption))
                .foregroundStyle(tone)
            Text(text)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: Spacing.s)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.font(.caption))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(tone.opacity(0.10))
    }

    // MARK: 动作

    private func openFileFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L(.workspaceOpenFileButton)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tabs.openFile(at: url)
    }
}

/// 工作区的 **Home 欢迎页**（FR-EDIT-35）：欢迎语 / 版本与版权 / 最近打开。
struct WorkspaceHomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var tabs: WorkspaceTabsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                actionRow
                HStack(alignment: .top, spacing: Spacing.l) {
                    recentFiles
                    recentWorkspaces
                    connections
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 1_100, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(.workspaceHomeWelcome))
                .font(Theme.font(.title))
                .foregroundStyle(Theme.text(.primary))
            Text(L(.workspaceHomeSubtitle))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Text(L(.workspaceHomeBuildLine, Self.appVersion, Self.appBuild))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
            Text(L(.workspaceHomeCopyright))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
        }
    }

    private var actionRow: some View {
        HStack(spacing: Spacing.s) {
            Button {
                openFileFromPanel()
            } label: {
                Label(L(.workspaceOpenFileButton), systemImage: "doc.text")
            }

            if workspace.rootURL == nil {
                Button {
                    Task { await workspace.pickAndChoose() }
                } label: {
                    Label(L(.workspaceChooseFolderButton), systemImage: "folder")
                }
            }
        }
    }

    private var recentFiles: some View {
        homeSection(title: L(.workspaceRecentFiles), empty: L(.workspaceRecentFilesEmpty), rows: tabs.history.files) { entry in
            Button {
                tabs.openFile(at: URL(fileURLWithPath: entry.path))
            } label: {
                homeRow(title: entry.displayName, detail: entry.path, symbol: "doc.text")
            }
            .buttonStyle(.plain)
            .help(entry.path)
        }
    }

    private var recentWorkspaces: some View {
        homeSection(title: L(.workspaceRecentWorkspaces), empty: L(.workspaceRecentWorkspacesEmpty), rows: tabs.history.workspaces) { entry in
            // 最近工作区**只展示**：重新切换要走目录授权（书签），不能拿一条历史路径冒充授权。
            homeRow(title: entry.displayName, detail: entry.path, symbol: "folder")
        }
    }

    private var connections: some View {
        homeSection(
            title: L(.workspaceConnections),
            empty: L(.workspaceConnectionEmpty),
            rows: appState.connections.map { WorkspaceHistoryEntry(path: $0.displayTitle(untitled: L(.connectionUntitled))) }
        ) { entry in
            Button {
                if let configuration = appState.connections.first(where: { $0.displayTitle(untitled: L(.connectionUntitled)) == entry.path }) {
                    appState.selectedConnectionID = configuration.id
                    // 走统一入口：工作区首页的"去数据库"也是能钻进未授权区的一条路，
                    // 当前档位不含数据库时它会照实说一句，而不是切到一个画不出来的视图。
                    appState.selectActivityItem(.database)
                }
            } label: {
                homeRow(title: entry.displayName, detail: entry.path, symbol: "cylinder.split.1x2")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func homeSection<Row: View>(
        title: String,
        empty: String,
        rows: [WorkspaceHistoryEntry],
        @ViewBuilder row: @escaping (WorkspaceHistoryEntry) -> Row
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(Theme.font(.bodyStrong))
                .foregroundStyle(Theme.text(.primary))

            if rows.isEmpty {
                Text(empty)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
            } else {
                ForEach(rows.prefix(8)) { entry in
                    row(entry)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func homeRow(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.primary))
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.hair)
        .contentShape(Rectangle())
    }

    private func openFileFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L(.workspaceOpenFileButton)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tabs.openFile(at: url)
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    private static var appBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
    }
}
