import SwiftUI
import DoyahCore

/// 工作区顶部的「服务器 / 数据库」上下文栏。
///
/// - 服务器下拉：枚举已保存连接，与左侧连接列表联动；
/// - 数据库下拉：枚举当前服务器上**当前登录用户可连接**的数据库（方言层按权限过滤），
///   选定后作为后续查询 / 语法检查的目标库；
/// - 未选择服务器时（例如从文件打开的页签）显示「未绑定连接」占位。
struct QueryContextBar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(L(.contextServer), selection: serverSelection) {
                if appState.selectedConnectionID == nil {
                    Text(L(.workspaceUnboundTab))
                        .tag(AppState.unboundConnectionID)
                }
                ForEach(appState.connections) { configuration in
                    // 服务器选择器里也带上环境徽标：**这里是"我现在连着哪台库"的最直接指示**。
                    HStack(spacing: Spacing.xs) {
                        Text(serverTitle(configuration))
                        ConnectionEnvironmentBadge(appearance: configuration.appearance, isCompact: true)
                    }
                    .tag(configuration.id)
                }
            }
            .labelsHidden()
            .frame(minWidth: 160, maxWidth: 280)
            .help(L(.contextServerHelp))

            Divider()
                .frame(height: 16)

            if appState.selectedConnectionID == nil {
                Text(L(.workspaceUnboundHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "cylinder")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L(.contextDatabase), selection: databaseSelection) {
                    ForEach(appState.availableDatabases, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 120, maxWidth: 240)
                .disabled(appState.availableDatabases.isEmpty)
                .help(L(.contextDatabaseHelp))

                if appState.isLoadingDatabases {
                    ProgressView()
                        .controlSize(.small)
                }

                if let error = appState.databaseError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(error)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task(id: appState.selectedConnectionID) {
            await appState.loadDatabases()
        }
    }

    private var serverSelection: Binding<ConnectionConfig.ID> {
        Binding(
            get: { appState.selectedConnectionID ?? AppState.unboundConnectionID },
            set: { newValue in
                guard newValue != AppState.unboundConnectionID else { return }
                appState.selectedConnectionID = newValue
            }
        )
    }

    private var databaseSelection: Binding<String> {
        Binding(
            get: { appState.selectedDatabase ?? "" },
            set: { appState.selectedDatabase = $0 }
        )
    }

    /// 环境徽标（FR-CONN-16）：与侧边栏用**同一个组件**，保证"到处一致"。
    @ViewBuilder
    private func environmentBadge(_ configuration: ConnectionConfig) -> some View {
        ConnectionEnvironmentBadge(appearance: configuration.appearance)
    }

    private func serverTitle(_ configuration: ConnectionConfig) -> String {
        // FR-CONN-14：连接名后括注登录用户名，便于区分同一主机上的不同账号。
        let name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return configuration.endpointDescription }
        return "\(configuration.displayTitle(untitled: name)) · \(configuration.endpointDescription)"
    }
}
