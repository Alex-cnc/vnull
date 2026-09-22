import SwiftUI
import DoyahCore

/// 数据库对象树。
///
/// 实现方式：**扁平化树**。
/// 不用「List 行里嵌套 DisclosureGroup」——那种结构在 SwiftUI `List` 中
/// 只有前两层可靠，第三层（schema → table）经常展不开。
/// 这里自己维护展开状态，把可见节点摊平成一维行数组，任意层级都能展开。
struct ObjectTreeView: View {
    @EnvironmentObject private var appState: AppState

    /// 服务器节点右键菜单「编辑连接…」的回调（由 `ConnectionListView` 传入）。
    var onEdit: ((ConnectionConfig) -> Void)?

    @State private var roots: [DatabaseObject] = []
    /// id → 已加载的子节点；值为空数组表示「加载过但没有子节点」。
    @State private var childrenCache: [String: [DatabaseObject]] = [:]
    @State private var expandedIDs: Set<String> = []
    @State private var loadingIDs: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var isLoadingRoot = false
    @State private var rootError: String?
    @State private var isCreateDatabasePresented = false
    /// 库属性 / 删除数据库（FR-SESS-05）。
    @State private var isPropertiesPresented = false
    @State private var isDropDatabasePresented = false
    /// 权限与锁面板（FR-SESS-04 / FR-DIAG-05）。
    @State private var isPrivilegePanelPresented = false
    @State private var isLockPanelPresented = false
    /// 是否按类型分组显示（FR-META-15）。切换只重新聚合缓存，不重新查库。
    @State private var groupByType = false

    /// 对象树刷新键：连接变化或「新建数据库」等操作后重新加载根节点（FR-META-11）。
    private struct RefreshKey: Hashable {
        let connectionID: UUID?
        let revision: Int
    }

    var body: some View {
        Group {
            if appState.selectedConnection == nil {
                Text(L(.objectTreeSelectPrompt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isLoadingRoot && roots.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L(.treeLoadingObjects))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let rootError {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L(.treeLoadFailed), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(rootError)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Button(L(.commonRetry)) {
                        Task { await reloadRoot() }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            } else if roots.isEmpty {
                Text(L(.treeEmpty))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                refreshRow
                ForEach(visibleRows) { row in
                    rowView(row)
                }
            }
        }
        // 这里**不要**再加 `.id(appState.selectedConnectionID)`：
        // 那会让整棵子树被销毁重建，切连接 / 删连接时侧栏会明显闪一下；
        // 而下面 `.task(id:)` 已经会在连接变化时调 `reloadRoot()`，
        // 由它负责把缓存与展开状态清干净，效果一样但不会整块重建。
        .task(
            id: RefreshKey(
                connectionID: appState.selectedConnectionID,
                revision: appState.metadataRevision
            )
        ) {
            await reloadRoot()
        }
        .sheet(isPresented: $isCreateDatabasePresented) {
            CreateDatabaseSheet { name in
                Task { await appState.createDatabase(named: name) }
            }
        }
        .sheet(isPresented: $isPropertiesPresented) {
            if let database = appState.adminTargetDatabase {
                DatabasePropertiesSheet(databaseName: database) { alterations in
                    Task { await appState.alterDatabase(name: database, alterations: alterations) }
                }
            }
        }
        .sheet(isPresented: $isDropDatabasePresented) {
            if let database = appState.adminTargetDatabase {
                DropDatabaseSheet(databaseName: database) { name in
                    Task { await appState.dropDatabase(name: name) }
                }
            }
        }
        .sheet(isPresented: $isPrivilegePanelPresented) {
            PrivilegePanel()
        }
        .sheet(isPresented: $isLockPanelPresented) {
            LockPanel()
        }
    }

    // MARK: - 扁平化

    private struct VisibleRow: Identifiable {
        let object: DatabaseObject
        let depth: Int
        let isExpandable: Bool
        let isExpanded: Bool
        let isLoading: Bool
        let error: String?
        let children: [DatabaseObject]?
        /// 分组视图下的虚拟类型表头（不是真实数据库对象）。
        let isGroupHeader: Bool

        var id: String { object.id }
    }

    private var visibleRows: [VisibleRow] {
        var rows: [VisibleRow] = []

        func visit(_ object: DatabaseObject, depth: Int) {
            let isExpanded = expandedIDs.contains(object.id)
            rows.append(
                VisibleRow(
                    object: object,
                    depth: depth,
                    isExpandable: object.isExpandable,
                    isExpanded: isExpanded,
                    isLoading: loadingIDs.contains(object.id),
                    error: errors[object.id],
                    children: childrenCache[object.id],
                    isGroupHeader: false
                )
            )

            if isExpanded, let children = childrenCache[object.id] {
                if groupByType {
                    // 分组只对**已缓存的子节点**做聚合，因此切换视图不触发重新查库。
                    for group in ObjectTreeGrouping.groupedByType(
                        children,
                        parentID: object.id,
                        language: LocalizationManager.shared.language
                    ) {
                        rows.append(
                            VisibleRow(
                                object: DatabaseObject(
                                    id: group.id,
                                    name: group.title(language: LocalizationManager.shared.language),
                                    kind: ObjectTreeGrouping.headerKind(for: group.kind),
                                    detail: "\(group.count)"
                                ),
                                depth: depth + 1,
                                isExpandable: false,
                                isExpanded: false,
                                isLoading: false,
                                error: nil,
                                children: nil,
                                isGroupHeader: true
                            )
                        )
                        for child in group.objects {
                            visit(child, depth: depth + 2)
                        }
                    }
                } else {
                    for child in children {
                        visit(child, depth: depth + 1)
                    }
                }
            }
        }

        for root in roots {
            visit(root, depth: 0)
        }
        return rows
    }

    // MARK: - 行渲染

    /// 视图切换 + 刷新（FR-META-15 / FR-META-11）。
    private var refreshRow: some View {
        HStack(spacing: 6) {
            Picker("", selection: $groupByType) {
                Text(L(.treeGroupHierarchy)).tag(false)
                Text(L(.treeGroupByType)).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .help(L(.treeGroupByType))

            Spacer()
            Button {
                Task { await reloadRoot() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L(.treeRefreshHelp))
            .disabled(isLoadingRoot)
        }
    }

    private func rowView(_ row: VisibleRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if row.isGroupHeader {
                    Color.clear.frame(width: 12, height: 12)
                } else if row.isExpandable {
                    Button {
                        toggle(row.object)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }

                Image(systemName: row.object.symbolName)
                    .font(.caption)
                    .foregroundStyle(color(for: row.object.kind))
                    .frame(width: 14)

                Text(row.object.name)
                    .font(.caption)
                    .fontWeight(row.isGroupHeader ? .semibold : .regular)
                    .lineLimit(1)

                if let detail = row.object.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 12)
            .contentShape(Rectangle())
            // 双击表 / 视图 → 浏览前 N 行（FR-DATA-01）。
            // 双击手势必须写在单击之前，否则会被单击吞掉。
            .onTapGesture(count: 2) {
                guard !row.isGroupHeader else { return }
                guard ObjectTreeActions.isAvailable(.browseRows, for: row.object.kind) else { return }
                Task { await appState.performTreeAction(.browseRows, on: row.object) }
            }
            .onTapGesture {
                guard !row.isGroupHeader, row.isExpandable else { return }
                toggle(row.object)
            }
            .contextMenuIf(treeMenuKinds.contains(row.object.kind) && !row.isGroupHeader) {
                if row.object.kind == .server {
                    serverContextMenu
                } else {
                    objectContextMenu(for: row.object)
                }
            }

            if row.isExpanded && !row.isGroupHeader {
                if row.isLoading {
                    placeholderRow(
                        text: L(.treeLoading),
                        depth: row.depth + 1,
                        systemImage: nil,
                        color: .secondary
                    )
                } else if let error = row.error {
                    placeholderRow(
                        text: error,
                        depth: row.depth + 1,
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange
                    )
                } else if let children = row.children, children.isEmpty {
                    placeholderRow(
                        text: emptyText(for: row.object),
                        depth: row.depth + 1,
                        systemImage: nil,
                        color: Color(nsColor: .tertiaryLabelColor)
                    )
                }
            }
        }
        .padding(.vertical, 1)
    }

    /// 挂右键菜单的节点类型（服务器节点见 FR-META-11，其余见 FR-META-14）。
    private var treeMenuKinds: Set<DatabaseObject.Kind> {
        [.server, .table, .view, .column]
    }

    /// 表 / 视图 / 列节点的右键菜单（FR-META-14）。
    ///
    /// 菜单项是否呈现**由 Core 的 `ObjectTreeActions.isAvailable` 决定**，
    /// 不在视图里再写一份类型判断 —— 否则两处规则迟早不一致。
    @ViewBuilder
    private func objectContextMenu(for object: DatabaseObject) -> some View {
        if ObjectTreeActions.isAvailable(.browseRows, for: object.kind) {
            Button(L(.treeActionBrowseRows, ObjectTreeActions.defaultBrowseLimit)) {
                runTreeAction(.browseRows, on: object)
            }

            Divider()

            Button(L(.treeActionSelectTemplate)) {
                runTreeAction(.selectTemplate, on: object)
            }
        }

        if ObjectTreeActions.isAvailable(.insertTemplate, for: object.kind) {
            Button(L(.treeActionInsertTemplate)) {
                runTreeAction(.insertTemplate, on: object)
            }
        }

        if ObjectTreeActions.isAvailable(.copyQualifiedName, for: object.kind) {
            Button(L(.treeActionCopyQualifiedName)) {
                runTreeAction(.copyQualifiedName, on: object)
            }
        }

        if ObjectTreeActions.isAvailable(.copyColumnName, for: object.kind) {
            Button(L(.treeActionCopyColumnName)) {
                runTreeAction(.copyColumnName, on: object)
            }
        }

        if ObjectTreeActions.isAvailable(.viewDDL, for: object.kind) {
            Divider()

            Button(L(.treeActionViewDDL)) {
                runTreeAction(.viewDDL, on: object)
            }
        }

        if ObjectTreeActions.isAvailable(.truncateTable, for: object.kind) {
            Divider()

            // 只生成语句、不执行；真要跑还会被 Safe Mode 拦一次。
            Button(L(.treeActionTruncate), role: .destructive) {
                runTreeAction(.truncateTable, on: object)
            }
        }

        if ObjectTreeActions.isAvailable(.dropTable, for: object.kind) {
            Button(L(.treeActionDrop), role: .destructive) {
                runTreeAction(.dropTable, on: object)
            }
        }
    }

    private func runTreeAction(_ action: ObjectTreeAction, on object: DatabaseObject) {
        Task { await appState.performTreeAction(action, on: object) }
    }

    /// 服务器节点的右键菜单（FR-META-11）。
    ///
    /// 本期只实现「服务器」节点：连接 / 断开 / 编辑连接，以及**依据登录用户权限**
    /// 决定是否呈现「新建数据库」。数据库 / schema / 表等节点的菜单留待后续需求。
    @ViewBuilder
    private var serverContextMenu: some View {
        let isConnected = appState.isObjectTreeConnected

        Button(L(.objectTreeMenuConnect)) {
            Task { await appState.connectObjectTree() }
        }
        .disabled(isConnected)

        Button(L(.objectTreeMenuDisconnect)) {
            Task { await appState.disconnectObjectTree() }
        }
        .disabled(!isConnected)

        Divider()

        Button(L(.objectTreeMenuEditConnection)) {
            if let configuration = appState.selectedConnection {
                onEdit?(configuration)
            }
        }
        .disabled(appState.selectedConnection == nil)

        Divider()

        // 库级管理（FR-SESS-05）：目标是「当前正在用的库」，没连库时不呈现入口。
        Button(L(.objectTreeMenuDatabaseProperties)) {
            isPropertiesPresented = true
        }
        .disabled(appState.adminTargetDatabase == nil)

        Button(L(.objectTreeMenuDropDatabase)) {
            isDropDatabasePresented = true
        }
        .disabled(appState.adminTargetDatabase == nil)

        Divider()

        // 诊断与权限面板（FR-SESS-04 / FR-DIAG-05）；未连接时查询必然失败，故禁用。
        Button(L(.objectTreeMenuPrivileges)) {
            isPrivilegePanelPresented = true
        }
        .disabled(!isConnected)

        Button(L(.objectTreeMenuLocks)) {
            isLockPanelPresented = true
        }
        .disabled(!isConnected)

        Divider()

        // 权限未知（nil）或明确无权限（false）时不呈现入口，避免给出必然失败的按钮。
        if appState.canCreateDatabase == true {
            Divider()

            Button(L(.objectTreeMenuCreateDatabase)) {
                isCreateDatabasePresented = true
            }
        }
    }

    private func placeholderRow(
        text: String,
        depth: Int,
        systemImage: String?,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(color)
            }
            Text(text)
                .font(.caption2)
                .foregroundStyle(color)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(depth) * 12 + 18)
    }

    // MARK: - 交互

    private func toggle(_ object: DatabaseObject) {
        guard object.isExpandable else { return }

        if expandedIDs.contains(object.id) {
            expandedIDs.remove(object.id)
            return
        }

        expandedIDs.insert(object.id)
        guard childrenCache[object.id] == nil, !loadingIDs.contains(object.id) else { return }
        Task { await loadChildren(of: object) }
    }

    private func loadChildren(of object: DatabaseObject) async {
        loadingIDs.insert(object.id)
        errors[object.id] = nil
        do {
            childrenCache[object.id] = try await appState.loadMetadataChildren(of: object)
        } catch {
            errors[object.id] = ErrorPresenter.message(for: error)
        }
        loadingIDs.remove(object.id)
    }

    private func reloadRoot() async {
        guard appState.selectedConnection != nil else {
            roots = []
            childrenCache = [:]
            expandedIDs = []
            errors = [:]
            rootError = nil
            return
        }

        if !isLoadingRoot { isLoadingRoot = true }
        if rootError != nil { rootError = nil }

        do {
            // 先把新数据取回来，**再**清缓存与展开状态：否则请求往返期间树会先空掉一次，
            // 那也是一次可见的闪。
            let newRoots = try await appState.loadMetadataRoot()
            roots = newRoots
            childrenCache = [:]
            expandedIDs = []
            errors = [:]
        } catch {
            roots = []
            childrenCache = [:]
            expandedIDs = []
            errors = [:]
            rootError = ErrorPresenter.message(for: error)
        }
        if isLoadingRoot { isLoadingRoot = false }
    }

    // MARK: - 文案与配色

    private func emptyText(for object: DatabaseObject) -> String {
        switch object.kind {
        case .server:
            return L(.treeEmptyServer)
        case .database:
            if appState.selectedConnection?.dbType == .gbase8a {
                return L(.treeEmptyDatabaseGBase)
            }
            return L(.treeEmptyDatabase)
        case .schema:
            return L(.treeEmptySchema)
        case .table, .view, .sequence:
            return L(.treeEmptyTable)
        case .column, .function:
            return L(.treeEmptyGeneric)
        }
    }

    private func color(for kind: DatabaseObject.Kind) -> Color {
        switch kind {
        case .server:
            return .accentColor
        case .database:
            return .blue
        case .schema:
            return .purple
        case .table:
            return .green
        case .view:
            return .teal
        case .column:
            return .secondary
        case .function:
            return .orange
        case .sequence:
            return .indigo
        }
    }
}

private extension View {
    /// 条件式右键菜单：条件不成立时不挂菜单，
    /// 避免右键其它层级节点时弹出空菜单。
    @ViewBuilder
    func contextMenuIf<MenuContent: View>(
        _ condition: Bool,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        if condition {
            contextMenu(menuItems: menuContent)
        } else {
            self
        }
    }
}
