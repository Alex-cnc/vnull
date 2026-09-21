import SwiftUI
import PostgresClientCore

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
        .task {
            await appState.loadAgentConfiguration()
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
