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
    @State private var formMode: ConnectionFormMode?

    var body: some View {
        NavigationSplitView {
            ConnectionListView(
                onAdd: {
                    formMode = .new
                },
                onEdit: { configuration in
                    formMode = .edit(configuration)
                }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            QueryWorkspaceView()
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
        .sheet(isPresented: $appState.isAgentSettingsPresented) {
            AgentSettingsSheet()
        }
        .sheet(isPresented: $appState.isAgentSQLPresented) {
            AgentSQLPanel()
        }
        .sheet(isPresented: $appState.isAgentAuditPresented) {
            AgentAuditPanel()
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
        .task {
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
