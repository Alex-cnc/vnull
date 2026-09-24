import SwiftUI
import DoyahCore

struct ConnectionListView: View {
    @EnvironmentObject private var appState: AppState
    let onAdd: () -> Void
    let onEdit: (ConnectionConfig) -> Void

    /// 待确认删除的连接（FR-CONN-05 / R-09：删除必须二次确认）。
    @State private var pendingDeletion: ConnectionConfig?

    /// 被折叠的分组（FR-CONN-15）。**默认全部展开** —— 折叠是"用户主动收起"的结果，
    /// 一进来就把组都收起来会让人以为连接没了。
    @State private var collapsedGroups: Set<String> = []

    /// 一个分组段：有组名时可折叠，未分组那段不给折叠 —— 它是兜底容器，
    /// 折起来等于把没归类的连接藏了。
    @ViewBuilder
    private func sectionView(_ section: ConnectionGrouping.Section) -> some View {
        let title = section.group ?? ConnectionGrouping.ungroupedTitle
        if section.isUngrouped {
            Text(title)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            rows(section)
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsedGroups.contains(section.id) },
                set: { expanded in
                    if expanded { collapsedGroups.remove(section.id) } else { collapsedGroups.insert(section.id) }
                }
            )) {
                rows(section)
            } label: {
                Text("\(title)（\(section.connections.count)）")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
        }
    }

    @ViewBuilder
    private func rows(_ section: ConnectionGrouping.Section) -> some View {
        ForEach(section.connections) { configuration in
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

    var body: some View {
        List(selection: $appState.selectedConnectionID) {
            Section(L(.connectionListTitle)) {
                if appState.connections.isEmpty {
                    Text(L(.connectionListEmpty))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                }

                // 按分组渲染（FR-CONN-15）：顺序由 `ConnectionGrouping` 一次定死
                // （分组本地化自然序、未分组永远最后、组内保持传入顺序），视图只负责画与折叠。
                // 顺序若在视图里再算一遍，两处迟早不一致。
                ForEach(ConnectionGrouping.sections(appState.connections)) { section in
                    sectionView(section)
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
