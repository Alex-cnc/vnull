import SwiftUI
import PostgresClientCore

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
        .id(appState.selectedConnectionID)
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
                    children: childrenCache[object.id]
                )
            )

            if isExpanded, let children = childrenCache[object.id] {
                for child in children {
                    visit(child, depth: depth + 1)
                }
            }
        }

        for root in roots {
            visit(root, depth: 0)
        }
        return rows
    }

    // MARK: - 行渲染

    private var refreshRow: some View {
        HStack {
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
                if row.isExpandable {
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
            .onTapGesture {
                if row.isExpandable {
                    toggle(row.object)
                }
            }
            .contextMenuIf(row.object.kind == .server) {
                serverContextMenu
            }

            if row.isExpanded {
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

        isLoadingRoot = true
        rootError = nil
        childrenCache = [:]
        expandedIDs = []
        errors = [:]

        do {
            roots = try await appState.loadMetadataRoot()
        } catch {
            roots = []
            rootError = ErrorPresenter.message(for: error)
        }
        isLoadingRoot = false
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
        case .table, .view:
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
