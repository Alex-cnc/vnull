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
    /// 「新建表」的目标节点（数据库或 schema 节点）；非 nil 时呈现表设计面板。
    @State private var createTableTarget: DatabaseObject?
    /// 「编辑表结构」的目标表节点；非 nil 时呈现表设计面板（编辑模式）。
    @State private var alterTableTarget: DatabaseObject?
    // 注：「按条件浏览 / 合成数据」这两个面板**没有**本地目标 state。
    // 它们的入口有两个（右键菜单与 ⌘K 命令面板），目标统一取 `appState.selectedTreeObject`、
    // 呈现开关统一取 AppState 的标志位 —— 本地 state 与全局标志位各存一份，
    // 迟早出现"面板开了、对象却是上一个"。
    /// 库属性 / 删除数据库（FR-SESS-05）。
    @State private var isPropertiesPresented = false
    @State private var isDropDatabasePresented = false
    /// 权限面板（FR-SESS-04）。
    @State private var isPrivilegePanelPresented = false
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
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            } else if isLoadingRoot && roots.isEmpty {
                HStack(spacing: Spacing.s) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L(.treeLoadingObjects))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                }
            } else if let rootError {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Label(L(.treeLoadFailed), systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.warning))
                    Text(rootError)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Button(L(.commonRetry)) {
                        Task { await reloadRoot() }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, Spacing.hair)
            } else if roots.isEmpty {
                Text(L(.treeEmpty))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
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
        .sheet(item: $createTableTarget) { target in
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
        .sheet(item: $alterTableTarget) { target in
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
        HStack(spacing: Spacing.s) {
            Picker("", selection: $groupByType) {
                Text(L(.treeGroupHierarchy)).tag(false)
                Text(L(.treeGroupByType)).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .help(L(.treeGroupByType))

            Spacer()

            // 全库对象搜索（FR-META-12）：与 ⌘K 里那条命令打开**同一个**面板。
            // 放这里是因为"找对象"是看着树时才有的念头，不必先想起来有命令面板。
            Button {
                appState.isObjectSearchPresented = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
            .buttonStyle(.plain)
            .help(L(.objectSearchTitle))

            Button {
                Task { await reloadRoot() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
            .buttonStyle(.plain)
            .help(L(.treeRefreshHelp))
            .disabled(isLoadingRoot)
        }
    }

    private func rowView(_ row: VisibleRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            HStack(spacing: Spacing.s) {
                if row.isGroupHeader {
                    Color.clear.frame(width: 12, height: 12)
                } else if row.isExpandable {
                    Button {
                        toggle(row.object)
                    } label: {
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .fontWeight(.bold)
                            .foregroundStyle(Theme.text(.secondary))
                            .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }

                Image(systemName: row.object.symbolName)
                    .font(Theme.font(.caption))
                    .foregroundStyle(color(for: row.object.kind))
                    .frame(width: 14)

                Text(row.object.name)
                    .font(Theme.font(.caption))
                    .fontWeight(row.isGroupHeader ? .semibold : .regular)
                    .lineLimit(1)

                if let detail = row.object.detail {
                    Text(detail)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.tertiary))
                        .lineLimit(1)
                }
            }
            .padding(.leading, CGFloat(row.depth) * Metrics.listIndent)
            .contentShape(Rectangle())
            // 选中态要看得见：⌘K 里"浏览数据 / 查看 DDL / 合成数据"都作用在选中项上，
            // 没有可见的选中标记时那句"请先在对象树里点选"会让人莫名其妙。
            .background(
                row.object.id == appState.selectedTreeObject?.id
                    ? Theme.accentColor.opacity(
                        Theme.isDarkAppearance ? Overlay.Selection.darkAlpha : Overlay.Selection.lightAlpha
                    )
                    : Color.clear
            )
            // 双击表 / 视图 → 浏览前 N 行（FR-DATA-01）。
            // 双击手势必须写在单击之前，否则会被单击吞掉。
            .onTapGesture(count: 2) {
                guard !row.isGroupHeader else { return }
                guard ObjectTreeActions.isAvailable(.browseRows, for: row.object.kind) else { return }
                select(row.object)
                Task { await appState.performTreeAction(.browseRows, on: row.object) }
            }
            .onTapGesture {
                guard !row.isGroupHeader else { return }
                // 单击既"选中"也"展开"：表 / 视图这类节点本来就靠单击展开看列，
                // 分两次点击才叫选中会让命令面板的目标变得不可预期。
                select(row.object)
                guard row.isExpandable else { return }
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
                        color: Theme.text(.secondary)
                    )
                } else if let error = row.error {
                    placeholderRow(
                        text: error,
                        depth: row.depth + 1,
                        systemImage: "exclamationmark.triangle.fill",
                        color: Theme.status(.warning)
                    )
                } else if let children = row.children, children.isEmpty {
                    placeholderRow(
                        text: emptyText(for: row.object),
                        depth: row.depth + 1,
                        systemImage: nil,
                        color: Theme.text(.tertiary)
                    )
                }
            }
        }
        .frame(height: Metrics.listRowHeight)
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

        if ObjectTreeActions.isAvailable(.browseRows, for: object.kind) {
            Button(L(.treeActionBrowseWithCondition)) {
                // 先记下目标（面板读的就是它），再开面板 —— 与 ⌘K 那条命令同一个入口。
                select(object)
                appState.isBrowseRowsCommandPresented = true
            }
        }

        // 合成数据（FR-AI-07）：只对表提供 —— 视图不可写，序列没有列。
        if object.kind == .table {
            Button(L(.syntheticGenerate) + "…") {
                select(object)
                appState.isSyntheticCommandPresented = true
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
            if object.kind == .database || object.kind == .schema {
                Divider()
                Button(L(.tableDesignTitle)) {
                    createTableTarget = object
                }
            }

            if object.kind == .table {
                Divider()
                Button(L(.tableDesignAlterTitle)) {
                    alterTableTarget = object
                }
            }

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

    /// 记下"这次操作针对谁"。右键菜单入口与 ⌘K 命令面板读的是**同一个**字段，
    /// 这样"面板开了、对象却是上一个"这种漂移不可能发生。
    private func select(_ object: DatabaseObject) {
        appState.selectedTreeObject = object
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
            appState.isLockCommandPresented = true
        }
        .disabled(!isConnected)

        // 服务器会话（FR-SESS-01 / 02）。这个 builder 本来就是**服务器节点专用菜单**，
        // 所以不需要再判节点类型 —— 会话是整个实例的概念（本轮我先多写了一次判断，编译才发现）。
        Button(L(.sessionTitle) + "…") {
            appState.isSessionCommandPresented = true
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
        HStack(spacing: Spacing.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(Theme.font(.caption))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(Theme.font(.caption))
                .foregroundStyle(color)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(depth) * Metrics.listIndent + Metrics.listIndent + Spacing.xs)
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
            appState.selectedTreeObject = nil
            return
        }

        if !isLoadingRoot { isLoadingRoot = true }
        if rootError != nil { rootError = nil }

        var loaded: [DatabaseObject] = []
        do {
            // 先把新数据取回来，**再**清缓存与展开状态：否则请求往返期间树会先空掉一次，
            // 那也是一次可见的闪。
            let newRoots = try await appState.loadMetadataRoot()
            roots = newRoots
            loaded = newRoots
            childrenCache = [:]
            expandedIDs = []
            errors = [:]
            // 树的内容换了（换连接 / 新建立了对象），旧的选中项可能已经不存在：
            // 留着它会让 ⌘K 里的"浏览数据"作用在一个陈旧的节点上。
            appState.selectedTreeObject = nil
        } catch {
            roots = []
            childrenCache = [:]
            expandedIDs = []
            errors = [:]
            rootError = ErrorPresenter.message(for: error)
            appState.selectedTreeObject = nil
        }
        if isLoadingRoot { isLoadingRoot = false }

        // 自动展开到「看得见表」（FR-META-01）：放在收起"加载中"**之后** —— 这一步还要走两三次
        // 元数据往返，挂在首屏上会让人以为界面卡住。
        await autoExpandToTables(roots: loaded)
    }

    /// 连上之后展开到表：服务器 → **连接自己那个库** → `public`。
    ///
    /// 为什么要有它：层级是「服务器 → 数据库 → schema → 表」，而展开状态是本地状态、每次连接
    /// 都从全部折叠开始 —— 实测反馈「连上了，那么多数据库里没看到 `customers`」就是这么来的
    /// （`customers` 是**表**，在连接自己那个库里，当时还得再点三次）。
    /// 策略本身在 Core（`ObjectTreeAutoExpansion`，有单测），这里只按顺序把名字喂进去，
    /// 走的是与用户手点**同一条** `loadChildren`（否则缓存与错误显示会分叉）。
    private func autoExpandToTables(roots: [DatabaseObject]) async {
        guard let server = roots.first, server.isExpandable else { return }

        expandedIDs.insert(server.id)
        await loadChildrenIfNeeded(of: server)

        guard let databases = childrenCache[server.id],
              let databaseName = ObjectTreeAutoExpansion.database(
                  in: databases.map(\.name),
                  connectionDatabase: appState.selectedConnection?.database
              ),
              let database = databases.first(where: { $0.name == databaseName }) else { return }

        expandedIDs.insert(database.id)
        await loadChildrenIfNeeded(of: database)

        guard let schemas = childrenCache[database.id],
              let schemaName = ObjectTreeAutoExpansion.schema(in: schemas.map(\.name)),
              let schema = schemas.first(where: { $0.name == schemaName }) else { return }

        expandedIDs.insert(schema.id)
        await loadChildrenIfNeeded(of: schema)
    }

    /// `loadChildren` 的幂等包装：已经加载过、或正在加载中就不再打一次
    /// （自动展开与用户手点可能撞在同一节点上）。
    private func loadChildrenIfNeeded(of object: DatabaseObject) async {
        guard childrenCache[object.id] == nil, !loadingIDs.contains(object.id) else { return }
        await loadChildren(of: object)
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
