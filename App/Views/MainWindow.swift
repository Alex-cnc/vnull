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
            ConnectionFormView(configuration: mode.configuration) { configuration, password in
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
