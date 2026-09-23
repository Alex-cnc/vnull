import AppKit
import Combine
import DoyahCore

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

    // MARK: 文件名搜索（FR-EDIT-32）
    //
    // 有界：忽略名单 + 深度上限 + 结果上限，全部收在 `WorkspaceSearch`（可单测）。
    // 这里只负责"什么时候算一次"与缓存 —— 每次敲键都重扫大目录是界面卡顿的经典来源。

    /// 搜索词。改动即重算（短查询会命中缓存）。
    @Published var searchQuery = "" {
        didSet { recomputeSearch() }
    }

    /// 搜索结果；`nil` = 当前没有在搜索。
    @Published private(set) var searchResult: WorkspaceSearch.Result?

    /// 是否处于搜索状态（界面据此决定显示树还是结果列表）。
    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchCache: [String: WorkspaceSearch.Result] = [:]

    func clearSearch() {
        searchQuery = ""
    }

    private func recomputeSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let rootURL else {
            searchResult = nil
            return
        }
        // 缓存键带上工作区路径：换工作区后同一个词不能命中旧结果。
        let key = rootURL.path + "\u{1}" + query
        if let cached = searchCache[key] {
            searchResult = cached
            return
        }
        let result = WorkspaceSearch.findFileNames(in: rootURL, query: query)
        searchCache[key] = result
        searchResult = result
    }

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
            // 传 rootURL 而不是 directory：relativePath 必须**始终相对工作区根**，
            // 它既是展开状态的键、也是路径解析的输入（见 WorkspaceTree.children 的注释）。
            return try WorkspaceTree.children(of: directory, relativeTo: rootURL)
        } catch {
            loadError = ErrorPresenter.message(for: error)
            return []
        }
    }
}
