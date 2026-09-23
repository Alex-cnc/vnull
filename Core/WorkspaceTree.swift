import Foundation

/// 工作区里的一个条目（FR-EDIT-32）。
public struct WorkspaceEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case directory
        case file
        /// 符号链接：**只显示、不跟随** —— 跟随会带来环与"实际读到了工作区外面"两个问题。
        case symlink
    }

    public let name: String
    /// 相对工作区根的路径，用 `/` 分隔（跨平台一致、也便于当 id 用）。
    public let relativePath: String
    public let kind: Kind

    public var id: String { relativePath }
    public var isDirectory: Bool { kind == .directory }
    /// 可展开 = 目录（符号链接即使指向目录也不展开）。
    public var isExpandable: Bool { kind == .directory }
}

/// 工作区文件树的**纯逻辑**：列一层目录、忽略名单、路径包含判定。
///
/// 放在 Core 的理由与其它模块一致：可以不打开图形界面单测，
/// 而这里恰好有几处**很容易写错又很难在界面上发现**的地方 ——
/// 路径包含判定用字符串前缀会在 `/ws` 与 `/ws-evil` 上出错；符号链接跟随会走出工作区。
public enum WorkspaceTree {

    /// 默认忽略名单：构建产物、依赖、版本库元数据、虚拟环境…
    ///
    /// 这些目录动辄几万条，列进来既慢又没用；用户真要看得细可以关掉忽略
    /// （`showHidden` 只管点开头的隐藏文件，两者是不同维度，故分开两个参数）。
    public static let defaultIgnored: Set<String> = [
        ".build", ".build-cache", "DerivedData", "node_modules", ".git", ".svn", ".hg",
        ".DS_Store", "__pycache__", ".venv", "venv", ".tox", "target", "dist",
        ".next", ".nuxt", ".swiftpm", ".idea", ".vscode-test", "Pods", "Carthage"
    ]

    /// 列一层目录（**不递归**：展开才读下一层，避免打开大工程时卡住界面）。
    ///
    /// 排序规则：目录在前、文件在后，同类按名称不区分大小写排序 ——
    /// 与访达 / VS Code 一致，用户不用重新适应。
    public static func children(
        of directory: URL,
        showHidden: Bool = false,
        ignored: Set<String> = defaultIgnored,
        fileManager: FileManager = .default
    ) throws -> [WorkspaceEntry] {
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        var entries: [WorkspaceEntry] = []
        for name in names {
            if ignored.contains(name) { continue }
            if !showHidden, name.hasPrefix(".") { continue }

            let url = directory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let kind: WorkspaceEntry.Kind
            if values?.isSymbolicLink == true {
                kind = .symlink
            } else if values?.isDirectory == true {
                kind = .directory
            } else {
                kind = .file
            }
            entries.append(
                WorkspaceEntry(
                    name: name,
                    relativePath: relativePath(of: url, in: directory) ?? name,
                    kind: kind
                )
            )
        }
        return entries.sorted { lhs, rhs in
            if (lhs.kind == .directory) != (rhs.kind == .directory) {
                return lhs.kind == .directory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// 相对路径（`nil` = 不在该目录下）。
    public static func relativePath(of url: URL, in root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        guard targetComponents.count >= rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// **路径必须落在工作区内**（FR-EDIT-32 的安全约束）。
    ///
    /// 刻意按**路径分量**比较而不是字符串前缀：后者会把 `/Users/me/ws-evil`
    /// 误判成 `/Users/me/ws` 的子路径 —— 这是路径校验里最经典的一个坑。
    /// 同时拒绝 `..`：它可能在标准化之前就绕过前缀比较。
    public static func isContained(_ candidatePath: String, in workspacePath: String) -> Bool {
        let candidate = URL(fileURLWithPath: candidatePath).standardizedFileURL
        let workspace = URL(fileURLWithPath: workspacePath).standardizedFileURL
        guard candidate.pathComponents.count >= workspace.pathComponents.count else { return false }
        return Array(candidate.pathComponents.prefix(workspace.pathComponents.count)) == workspace.pathComponents
    }

    /// 规范化"用户 / 缓存里拿到的相对路径"：去掉 `..` 与空段。
    ///
    /// 返回 `nil` 表示这个相对路径不安全（含 `..` 逃逸），调用方应当拒绝而不是"尽力而为"。
    public static func normalizedRelativePath(_ raw: String) -> String? {
        var components: [String] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// 在给定工作区根下解析一个相对路径（`nil` = 不安全或越界）。
    ///
    /// 这是"打开文件 / 交给智能体读写"之前**必须**过的一道关：
    /// 相对路径可能来自缓存、书签或模型输出，不能信。
    public static func resolve(relativePath: String, in workspaceURL: URL) -> URL? {
        guard let normalized = normalizedRelativePath(relativePath) else { return nil }
        let candidate = workspaceURL.appendingPathComponent(normalized).standardizedFileURL
        guard isContained(candidate.path, in: workspaceURL.path) else { return nil }
        return candidate
    }
}
