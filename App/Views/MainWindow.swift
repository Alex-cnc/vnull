import SwiftUI
import DoyahCore

/// 连接表单的展示模式。
/// 用 `.sheet(item:)` 而不是 `isPresented` + 可选值，
/// 避免「点编辑却弹出新建、字段为空」的状态捕获问题。
enum ConnectionFormMode: Identifiable {
    case new
    case edit(ConnectionConfig)

    var id: String {
        switch self {
        case .new:
            return "new"
        case .edit(let configuration):
            return configuration.id.uuidString
        }
    }

    var configuration: ConnectionConfig? {
        switch self {
        case .new:
            return nil
        case .edit(let configuration):
            return configuration
        }
    }

    var isNew: Bool {
        if case .new = self { return true }
        return false
    }
}

struct MainWindow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var localization: LocalizationManager
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var formMode: ConnectionFormMode?

    /// 侧栏内容由活动栏决定（「看哪个视图」与「视图里看什么」分开）。
    @ViewBuilder
    private var sidebarContent: some View {
        switch appState.selectedActivityItem {
        case .database:
            ConnectionListView(
                onAdd: { formMode = .new },
                onEdit: { configuration in formMode = .edit(configuration) }
            )
        case .workspace:
            WorkspaceExplorerView()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // 活动栏在 `NavigationSplitView` **外面**：它是应用级 chrome，不属于可调宽的侧栏
            // （与 VS Code 一致 —— 拖拽侧栏宽度时活动栏不动）。
            ActivityBarView()
            NavigationSplitView {
                sidebarContent
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
            } detail: {
            // 下方面板（结果 / 问题 / 输出 / 终端 / 调试控制台）已经并进工作区本身，
            // 所以这里不再另开一块区域。
                QueryWorkspaceView()
            }
        }
        .sheet(item: $formMode) { mode in
            ConnectionFormView(
                configuration: mode.configuration,
                existingConnections: appState.connections
            ) { configuration, password in
                Task {
                    if mode.isNew {
                        await appState.addConnection(configuration, password: password)
                    } else {
                        await appState.updateConnection(
                            configuration,
                            password: password.isEmpty ? nil : password
                        )
                    }
                    formMode = nil
                }
            }
        }
        // 命令面板（FR-EDIT-25）：⌘K 唤起。用隐藏按钮承载快捷键 ——
        // SwiftUI 里这是"不占用菜单项也能挂全局快捷键"的常规做法；
        // 面板自身的 ↑↓ / ↩ / esc 语义由 `CommandPaletteView` 处理。
        //
        // 说明：本轮的快捷键**没有**登记进 `AppShortcut`（帮助面板因此还看不到它），
        // 这条缺口写在需求行的"仍未做"里，不假装已完成。
        .background(
            Button("") { appState.isCommandPalettePresented = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .sheet(isPresented: $appState.isCommandPalettePresented) {
            CommandPaletteView()
                .environmentObject(appState)
        }
        // 查询参数面板（FR-EXEC-17）：执行时若有占位符就弹出来填值。
        .sheet(isPresented: $appState.isQueryParameterSheetPresented) {
            QueryParameterSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.isAgentSettingsPresented) {
            AgentSettingsSheet()
        }
        .sheet(isPresented: $appState.isAppearancePresented) {
            AppearanceSheet()
        }
        // 连接设置（FR-CONN-20）：保活心跳的开关与间隔。
        .sheet(isPresented: $appState.isConnectionSettingsPresented) {
            ConnectionSettingsSheet()
                .environmentObject(appState)
        }
        // 数据库统计（FR-DIAG-04）：四类指标只读采集。
        .sheet(isPresented: $appState.isDatabaseStatsPresented) {
            DatabaseStatsPanel()
                .environmentObject(appState)
        }
        // Schema 对比与同步（FR-DDL-04）：两侧结构差异 + 同步脚本。
        .sheet(isPresented: $appState.isSchemaDiffPresented) {
            SchemaDiffPanel()
                .environmentObject(appState)
        }
        // 服务器级对象（FR-SESS-03）：角色 / 表空间 / 扩展的浏览与增删改。
        .sheet(isPresented: $appState.isServerObjectsPresented) {
            ServerObjectsPanel()
                .environmentObject(appState)
        }
        // 外键跳转目标选择（FR-DATA-06）：一列被多条外键引用时才出现。
        .sheet(item: $appState.pendingForeignKeyJump) { request in
            ForeignKeyJumpSheet(request: request)
                .environmentObject(appState)
        }
        .alert(
            L(.accountUndecidedTitle),
            isPresented: $appState.isAccountNoticePresented
        ) {
            Button(L(.commonOk), role: .cancel) {}
        } message: {
            Text(L(.accountUndecidedMessage))
        }
        .sheet(isPresented: $appState.isAgentSQLPresented) {
            AgentSQLPanel()
        }
        .sheet(isPresented: $appState.isAgentAuditPresented) {
            AgentAuditPanel()
        }
        .sheet(isPresented: $appState.isEgressLogPresented) {
            EgressLogSheet()
        }
        .sheet(isPresented: $appState.isDataTaskPresented) {
            DataTaskPanel()
        }
        .sheet(isPresented: $appState.isExecutionPlanPresented) {
            if let tab = appState.selectedTab {
                ExecutionPlanPanel(tabID: tab.id)
            }
        }
        .sheet(item: $appState.pendingExecution) { pending in
            SafeModeConfirmSheet(pending: pending)
        }
        .sheet(isPresented: $appState.isSQLArchivePresented) {
            SQLArchiveSheet()
        }
        // ⌘K 命令面板里这三条（帮助 / 切换连接 / 全库对象搜索）都挂在**窗口**上：
        // 工具栏按钮只在某个页签存在时才在，而命令面板是全局入口 ——
        // 挂在窗口上，无论当前在看哪个视图，命令都不会落空。
        .sheet(isPresented: $appState.isShortcutHelpCommandPresented) {
            // 与工具栏「?」气泡**同一份内容**（`ShortcutHelpContent`），只是呈现方式不同。
            ShortcutHelpContent()
                .frame(width: 420)
        }
        .sheet(isPresented: $appState.isConnectionSwitchPresented) {
            ConnectionSwitchSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.isObjectSearchPresented) {
            ObjectSearchPanel()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.isRoutineCandidatesPresented) {
            RoutineCandidatesPanel()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.isBackupRestorePresented) {
            BackupRestoreSheet()
                .environmentObject(appState)
        }
        // 切换语言后系统级菜单要重启才跟随（NFR-I18N-03）。
        .sheet(isPresented: $localization.isRestartPromptPresented) {
            RelaunchPromptSheet()
        }
        .task {
            // 工作区（FR-EDIT-32）：读回授权书签并把路径交给终端作为启动目录。
            // 终端对象挂在 App 层，这里通过环境取不到它（它在 environment 里但需要 @EnvironmentObject）。
            // 因此工作区路径由 App 层直接订阅 —— 见 `DoyahStudioApp`。
            await workspace.load()
            await appState.loadAgentConfiguration()
            // 数据任务需要在客户端运行期间一直被调度（FR-AI-06）：
            // 启动时读一次任务与执行历史，然后由 App 侧的 tick 驱动 Core 的纯时间判定。
            await appState.loadDataTasks()
            appState.startDataTaskTicker()
            // 连接保活心跳（FR-CONN-20）：空闲连接按间隔发一条轻量查询
            appState.startKeepAliveTicker()
            // 归档目录状态与查询记忆索引（FR-AI-13 S2）：启动就读一次，
            // 否则要等用户打开归档面板之后补全才有记忆。
            await appState.refreshSQLArchiveStatus()
        }
        .alert(
            L(.alertErrorTitle),
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            )
        ) {
            Button(L(.commonOk), role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }
}

/// 「切换连接」的**最小可用**面板（⌘K → 切换连接）。
///
/// 为什么不复用现成的服务器选择器：它有两处（侧栏连接列表、查询上下文栏），
/// 但都要求"当前视图里正好有它"——上下文栏只在工作区顶部，命令面板不该依赖这个。
/// 所以这里给一个窄列表：点一行就切过去，别的不做（新建 / 编辑仍在侧栏，
/// 不在这里重复一套表单）。
struct ConnectionSwitchSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.commandSwitchConnection))
                .font(Theme.font(.title))

            if appState.connections.isEmpty {
                Text(L(.connectionListEmpty))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(appState.connections) { configuration in
                            row(configuration)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            HStack(spacing: Spacing.s) {
                Spacer()
                Button(L(.commonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.l)
        .frame(width: 380)
        .background(Theme.surface(.panel))
    }

    private func row(_ configuration: ConnectionConfig) -> some View {
        let isCurrent = configuration.id == appState.selectedConnectionID
        return HStack(spacing: Spacing.s) {
            // 环境徽标与侧栏 / 上下文栏是**同一个组件**：别处一眼能分辨生产库，这里也要能。
            ConnectionEnvironmentBadge(appearance: configuration.appearance, isCompact: true)

            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(configuration.displayTitle(untitled: L(.connectionUntitled)))
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text(.primary))
                    .lineLimit(1)
                Text(configuration.endpointDescription)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                    .lineLimit(1)
            }

            Spacer()

            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.accentColor)
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedConnectionID = configuration.id
            dismiss()
        }
    }
}
