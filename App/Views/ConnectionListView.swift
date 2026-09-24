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
        // MARK: 对象树里那些面板（**挂在这里，别挂回 `ObjectTreeView`**）
        //
        // 为什么：修饰符挂在 `Group` 上会被 SwiftUI **分发到每个子视图**，而对象树的内容就是
        // "N 行" —— 这些 sheet 原先挂在它的 `Group` 上，于是每行各挂一份
        // （实测 16 行 × 10 个 sheet = 160 个呈现槽）。症状：「编辑表结构」点取消时
        // 界面来回闪很多次才关（2026-09-24 需求提出者实测）。挂到这个**唯一的 `List`** 上，
        // 宿主就只有 1 个。目标状态因此住在 `AppState`（见那边的注释）。
        .sheet(item: $appState.createTableTarget) { target in
            TableDesignSheet(
                mode: .create,
                databaseType: appState.selectedConnection?.dbType ?? .postgresql,
                initialSchema: target.kind == .schema ? target.name : target.schema
            ) { submission in
                Task {
                    _ = await appState.createTable(
                        named: submission.name,
                        schema: submission.schema,
                        columns: submission.changeSet.editedColumns,
                        extras: submission.changeSet
                    )
                }
            }
        }
        .sheet(isPresented: $appState.isBrowseRowsCommandPresented) {
            if let target = appState.selectedTreeObject {
                BrowseRowsSheet(object: target) {
                    appState.isBrowseRowsCommandPresented = false
                }
                .environmentObject(appState)
            }
        }
        .sheet(item: $appState.alterTableTarget) { target in
            TableDesignSheet(
                mode: .alter(tableName: target.name),
                databaseType: appState.selectedConnection?.dbType ?? .postgresql,
                initialSchema: target.schema,
                loadStructure: { try await appState.tableStructure(of: target) },
                loadExtras: { try await appState.tableExtras(of: target) }
            ) { submission in
                Task { _ = await appState.alterTable(target, changeSet: submission.changeSet) }
            }
        }
        .sheet(isPresented: $appState.isCreateDatabasePresented) {
            CreateDatabaseSheet { name in
                Task { await appState.createDatabase(named: name) }
            }
        }
        .sheet(isPresented: $appState.isPropertiesPresented) {
            if let database = appState.adminTargetDatabase {
                DatabasePropertiesSheet(databaseName: database) { alterations in
                    Task { await appState.alterDatabase(name: database, alterations: alterations) }
                }
            }
        }
        .sheet(isPresented: $appState.isDropDatabasePresented) {
            if let database = appState.adminTargetDatabase {
                DropDatabaseSheet(databaseName: database) { name in
                    Task { await appState.dropDatabase(name: name) }
                }
            }
        }
        .sheet(isPresented: $appState.isPrivilegePanelPresented) {
            PrivilegePanel()
        }
        .sheet(isPresented: $appState.isSyntheticCommandPresented) {
            if let target = appState.selectedTreeObject {
                SyntheticDataPanel(object: target)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.isSessionCommandPresented) {
            SessionPanel()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.isLockCommandPresented) {
            LockPanel()
        }
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
