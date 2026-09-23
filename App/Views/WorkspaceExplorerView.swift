import DoyahCore
import SwiftUI

/// 工作区面板（FR-EDIT-32）——活动栏里选「工作区」时显示在右侧。
///
/// 三件事：选目录（沙箱下是一次授权）、一层懒加载的文件树、**底部常显授权状态**。
/// 最后一条是这个面板存在感最强的地方：沙箱下书签会过期、目录会被移动，
/// 用户必须在界面上**当场看见**"现在到底能不能读写"，而不是打开文件才发现读不到。
struct WorkspaceExplorerView: View {

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var accent: AccentManager
    @Environment(\.colorScheme) private var scheme

    @State private var selectedPath: String?
    @State private var hoveredPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if workspace.hasWorkspace {
                header
                pathLine
                tree
                statusFooter
            } else {
                emptyState
                Spacer(minLength: 0)
                statusFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface(.sidebar))
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Text(L(.activityWorkspace))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
            Spacer(minLength: 0)
            iconButton("arrow.clockwise", help: L(.workspaceRefresh)) {
                Task { await workspace.refresh() }
            }
            iconButton("folder.badge.gearshape", help: L(.workspaceSwitch)) {
                Task { await workspace.pickAndChoose() }
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.xs)
    }

    /// 工作区名 + 切换入口（点击整行即可换目录）。
    private var pathLine: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "folder.fill")
                    .font(Theme.font(.caption))
                    .foregroundStyle(accent.accentColor)
                Text(workspace.displayName)
                    .font(Theme.font(.bodyStrong))
                    .foregroundStyle(Theme.text(.primary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(workspace.rootPath ?? "")
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .lineLimit(1)
                .truncationMode(.middle)   // 中间省略：只省略中间才不会把根目录吃掉
                .help(workspace.rootPath ?? "")
        }
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.s)
    }

    // MARK: 文件树

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let rows = workspace.visibleRows()
                if rows.isEmpty {
                    Text(L(.workspaceTreeEmpty))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.tertiary))
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.s)
                } else {
                    ForEach(rows) { row in
                        treeRow(row)
                    }
                }
            }
            .padding(.vertical, Spacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(workspace.revision)   // 缓存变化（展开 / 刷新）时重建列表
    }

    private func treeRow(_ row: WorkspaceRow) -> some View {
        let entry = row.entry
        let isSelected = selectedPath == entry.relativePath
        let isHovered = hoveredPath == entry.relativePath

        return HStack(spacing: Spacing.xs) {
            // 展开箭头只给目录：符号链接不给（它不跟随，见 WorkspaceTree 的说明）
            if entry.isExpandable {
                Image(systemName: workspace.isExpanded(entry) ? "chevron.down" : "chevron.right")
                    .imageScale(.small)          // 用 imageScale 而不是裸字号：SF Symbol 的惯用做法
                    .foregroundStyle(Theme.text(.tertiary))
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }

            Image(systemName: symbol(for: entry))
                .font(Theme.font(.caption))
                .foregroundStyle(isSelected ? accent.accentColor : Theme.text(.tertiary))
                .frame(width: 14)

            Text(entry.name)
                .font(Theme.font(.body))
                .foregroundStyle(isSelected ? Theme.text(.primary) : Theme.text(.secondary))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, Spacing.s + CGFloat(row.depth) * 14)
        .padding(.trailing, Spacing.m)
        .frame(height: Metrics.listRowHeight)
        .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredPath = hovering ? entry.relativePath : (hoveredPath == entry.relativePath ? nil : hoveredPath)
        }
        .onTapGesture(count: 2) {
            // 双击：目录展开 / 收起；文件在新页签里打开（走既有的 openFile 单一入口）
            if entry.isExpandable {
                workspace.toggle(entry)
            } else if let url = workspace.url(for: entry) {
                appState.openFile(at: url)
            }
        }
        .onTapGesture {
            selectedPath = entry.relativePath
            if entry.isExpandable { workspace.toggle(entry) }
        }
        .contextMenu {
            Button(L(.workspaceReveal)) { workspace.reveal(entry) }
        }
        .help(entry.relativePath)
        .accessibilityIdentifier("workspace-row-\(entry.relativePath)")
    }

    private func symbol(for entry: WorkspaceEntry) -> String {
        switch entry.kind {
        case .directory: return workspace.isExpanded(entry) ? "folder.fill" : "folder"
        case .symlink: return "arrowshape.turn.up.right"
        case .file:
            switch (entry.name as NSString).pathExtension.lowercased() {
            case "swift": return "swift"
            case "sql": return "cylinder"
            case "md": return "doc.text"
            case "json", "yml", "yaml", "toml": return "curlybraces"
            case "png", "jpg", "jpeg", "gif", "webp": return "photo"
            default: return "doc"
            }
        }
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        if isSelected {
            ZStack(alignment: .leading) {
                accent.tint(scheme).opacity(0.9)
                Rectangle()
                    .fill(accent.accentColor)
                    .frame(width: Spacing.hair)
            }
        } else if isHovered {
            Theme.text(.primary).opacity(0.05)
        } else {
            Color.clear
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.workspaceEmptyTitle))
                .font(Theme.font(.bodyStrong))
                .foregroundStyle(Theme.text(.primary))
            Text(L(.workspaceEmptyHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Button(L(.workspaceChoose)) {
                Task { await workspace.pickAndChoose() }
            }
            .padding(.top, Spacing.xs)
        }
        .padding(Spacing.m)
    }

    // MARK: 底部状态（授权是否有效，必须常显）

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.hairline(scheme))
                .frame(height: Metrics.hairline)
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
        }
    }

    private var statusText: String {
        guard let status = workspace.status else { return L(.directoryStatusNotAuthorized) }
        return L(status.messageKey, status.messageArgument)
    }

    private var statusTint: Color {
        switch workspace.status {
        case .granted(_, let isStale):
            return isStale ? Theme.status(.warning) : Theme.status(.success)
        case .missing, .denied, .resolutionFailed:
            return Theme.status(.danger)
        case .notAuthorized, .none:
            return Theme.text(.tertiary)
        }
    }

    // MARK: 小组件

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
