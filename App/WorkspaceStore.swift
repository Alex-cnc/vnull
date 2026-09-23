import AppKit
import Combine
import DoyahCore

/// 工作区的一行（条目 + 缩进层级）—— 扁平化之后交给 `List` / `ForEach` 渲染。
struct WorkspaceRow: Identifiable {
    let entry: WorkspaceEntry
    let depth: Int
    var id: String { entry.relativePath }
}

/// 工作区状态（FR-EDIT-32）：用户自选目录 + 沙箱授权书签 + 一层懒加载的文件树。
///
/// 关于授权：macOS 沙箱下访问用户目录必须持有 security-scoped bookmark，
/// 所以这里**在生命周期内一直握着 `DirectoryGrant`**（RAII：换工作区或清空时停止访问）。
/// 非沙箱构建里 `startAccessingSecurityScopedResource()` 会返回 false —— 那**不是**被拒绝，
/// 已有代码对此有专门处理（见 `SecureDirectoryAccess`）。
///
/// 关于树：只列**一层**，展开哪一层读哪一层。工程目录动辄几万条，
/// 递归读完会让界面卡住，而用户真正会点的只有当前这几行。
@MainActor
final class WorkspaceStore: ObservableObject {

    static let shared = WorkspaceStore()

    @Published private(set) var bookmark: DirectoryBookmark?
    @Published private(set) var status: DirectoryAccessStatus?
    @Published private(set) var rootURL: URL?
    @Published private(set) var isBusy = false
    /// 缓存内容变化时自增，驱动界面重绘（缓存本身不需要被观察）。
    @Published private(set) var revision = 0

    /// 工作区变化时通知外部（终端启动目录要跟着走）。
    var onWorkspaceChanged: ((String?) -> Void)?

    private var childrenCache: [String: [WorkspaceEntry]] = [:]
    private var expandedPaths: Set<String> = []
    private var loadError: String?
    private var grant: DirectoryGrant?

    /// 单独一个书签文件：不污染数据任务导出目录 / 查询归档的「使用已授权目录」列表。
    ///
    /// 之所以可从外部注入：**落盘路径是这类代码唯一没法靠纯逻辑单测的部分**，
    /// 而自检探针又跑在被沙箱限制的进程里（写不了 `~/Library/Application Support`）。
    /// 注入一个临时目录的 store，就能把"保存 → 读回 → 解析"这条链路真正跑通。
    private let store: DirectoryBookmarkStore

    init(store: DirectoryBookmarkStore = DirectoryBookmarkStore(fileName: "workspace-bookmark.json")) {
        self.store = store
    }

    var rootPath: String? { rootURL?.path }

    var displayName: String {
        if let name = bookmark?.displayName, !name.isEmpty { return name }
        return rootURL?.lastPathComponent ?? ""
    }

    var hasWorkspace: Bool { rootURL != nil }

    var errorText: String? { loadError }

    // MARK: 生命周期

    /// 启动时调用：读回书签 → 判定可用性 → 取用授权 → 读根目录。
    func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let bookmarks = try await store.all()
            guard let first = bookmarks.first else {
                apply(status: .notAuthorized, bookmark: nil)
                return
            }
            bookmark = first
            adopt(first)
        } catch {
            loadError = error.localizedDescription
            apply(status: nil, bookmark: nil)
        }
    }

    /// 用户刚在面板里选好一个目录。
    func choose(_ url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let created = try SecureDirectoryAccess.makeBookmark(for: url)
            // 工作区只保留一个：先清空再存，免得「已授权目录」列表越滚越长。
            try await store.removeAll()
            let saved = try await store.save(created)
            bookmark = saved
            adopt(saved)
        } catch {
            loadError = ErrorPresenter.message(for: error)
        }
    }

    /// 弹出目录选择器（用户取消不是错误）。
    func pickAndChoose() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = L(.workspaceChoose)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await choose(url)
    }

    func clear() async {
        grant?.stopAccessing()
        grant = nil
        childrenCache.removeAll()
        expandedPaths.removeAll()
        bookmark = nil
        rootURL = nil
        loadError = nil
        try? await store.removeAll()
        apply(status: .notAuthorized, bookmark: nil)
    }

    /// 重新解析书签并刷新根目录（书签可能被外部改动 / 目录被移动）。
    func refresh() async {
        guard let bookmark else { return }
        isBusy = true
        defer { isBusy = false }
        adopt(bookmark)
    }

    // MARK: 树

    func isExpanded(_ entry: WorkspaceEntry) -> Bool {
        expandedPaths.contains(entry.relativePath)
    }

    func toggle(_ entry: WorkspaceEntry) {
        guard entry.isExpandable else { return }
        if expandedPaths.contains(entry.relativePath) {
            expandedPaths.remove(entry.relativePath)
        } else {
            expandedPaths.insert(entry.relativePath)
            if childrenCache[entry.relativePath] == nil {
                childrenCache[entry.relativePath] = listChildren(relativePath: entry.relativePath)
            }
        }
        revision += 1
    }

    /// 当前可见的行（按展开状态扁平化）。
    func visibleRows() -> [WorkspaceRow] {
        var rows: [WorkspaceRow] = []
        func append(_ entries: [WorkspaceEntry], depth: Int) {
            for entry in entries {
                rows.append(WorkspaceRow(entry: entry, depth: depth))
                if entry.isExpandable, expandedPaths.contains(entry.relativePath) {
                    append(childrenCache[entry.relativePath] ?? [], depth: depth + 1)
                }
            }
        }
        append(childrenCache[""] ?? [], depth: 0)
        return rows
    }

    func url(for entry: WorkspaceEntry) -> URL? {
        guard let rootURL else { return nil }
        return WorkspaceTree.resolve(relativePath: entry.relativePath, in: rootURL)
    }

    /// 在访达中显示（目录就打开它，文件则选中它）。
    func reveal(_ entry: WorkspaceEntry? = nil) {
        let target = entry.flatMap { url(for: $0) } ?? rootURL
        guard let target else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: 内部

    /// 采用一份书签：解析状态 → 取用授权 → 读根目录。
    private func adopt(_ bookmark: DirectoryBookmark) {
        let resolved = SecureDirectoryAccess.status(for: bookmark)
        grant?.stopAccessing()
        grant = nil
        childrenCache.removeAll()
        expandedPaths.removeAll()
        loadError = nil

        guard case .granted(let path, _) = resolved else {
            rootURL = nil
            apply(status: resolved, bookmark: bookmark)
            return
        }
        do {
            grant = try SecureDirectoryAccess.open(bookmark)
        } catch {
            // 解析得到路径但取用失败：仍然把目录显示出来（非沙箱下这是常态），只记下原因。
            loadError = ErrorPresenter.message(for: error)
        }
        rootURL = URL(fileURLWithPath: path, isDirectory: true)
        childrenCache[""] = listChildren(relativePath: "")
        apply(status: resolved, bookmark: bookmark)
    }

    private func apply(status: DirectoryAccessStatus?, bookmark: DirectoryBookmark?) {
        self.status = status
        if bookmark == nil { self.bookmark = nil }
        revision += 1
        onWorkspaceChanged?(rootURL?.path)
    }

    private func listChildren(relativePath: String) -> [WorkspaceEntry] {
        guard let rootURL else { return [] }
        let directory = relativePath.isEmpty
            ? rootURL
            : WorkspaceTree.resolve(relativePath: relativePath, in: rootURL) ?? rootURL
        do {
            return try WorkspaceTree.children(of: directory)
        } catch {
            loadError = ErrorPresenter.message(for: error)
            return []
        }
    }
}
