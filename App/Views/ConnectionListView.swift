import SwiftUI
import DoyahCore

struct ConnectionListView: View {
    @EnvironmentObject private var appState: AppState
    let onAdd: () -> Void
    let onEdit: (ConnectionConfig) -> Void

    /// 待确认删除的连接（FR-CONN-05 / R-09：删除必须二次确认）。
    @State private var pendingDeletion: ConnectionConfig?

    var body: some View {
        List(selection: $appState.selectedConnectionID) {
            Section(L(.connectionListTitle)) {
                if appState.connections.isEmpty {
                    Text(L(.connectionListEmpty))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                }

                ForEach(appState.connections) { configuration in
                    ConnectionRow(configuration: configuration)
                        .tag(configuration.id)
                        .contextMenu {
                            Button(L(.commonEdit)) {
                                onEdit(configuration)
                            }
                            Button(L(.commonDelete), role: .destructive) {
                                pendingDeletion = configuration
                            }
                        }
                }
            }

            Section(L(.objectTreeSectionTitle)) {
                ObjectTreeView(onEdit: onEdit)
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog(
            L(.connectionDeleteConfirmTitle),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { configuration in
            Button(L(.commonDelete), role: .destructive) {
                pendingDeletion = nil
                Task { await appState.deleteConnection(configuration) }
            }
            Button(L(.commonCancel), role: .cancel) {
                pendingDeletion = nil
            }
        } message: { configuration in
            Text(L(.connectionDeleteConfirmMessage, configuration.displayTitle(untitled: L(.connectionUntitled))))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAdd) {
                    Label(L(.connectionNew), systemImage: "plus")
                }
            }
        }
    }
}

private struct ConnectionRow: View {
    let configuration: ConnectionConfig

    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle()
                .fill(Theme.categorical(configuration.dbType.identityTone))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: Spacing.hair) {
                HStack(spacing: Spacing.xs) {
                    Text(configuration.displayTitle(untitled: L(.connectionUntitled)))
                        .font(Theme.font(.body))
                        .lineLimit(1)
                    // 环境徽标（FR-CONN-16）：生产一眼可辨，避免连错库。
                    ConnectionEnvironmentBadge(appearance: configuration.appearance)
                }
                Text("\(configuration.dbType.displayName) · \(configuration.endpointDescription)")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
