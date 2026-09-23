import Foundation

/// 工作区里的一行（条目 + 缩进层级）—— 扁平化之后交给界面渲染。
///
/// 放在 Core 而不是 App：它是**纯数据**，而且树与搜索两边都要用；
/// 放在 App 会让搜索逻辑没法单测。
public struct WorkspaceRow: Equatable, Sendable, Identifiable {
    public let entry: WorkspaceEntry
    public let depth: Int

    public var id: String { entry.relativePath }

    public init(entry: WorkspaceEntry, depth: Int) {
        self.entry = entry
        self.depth = depth
    }
}

/// 工作区内**按文件名**搜索（FR-EDIT-32）。
///
/// 刻意做成"有界的递归"而不是全文检索：
///   · 全文检索要扫内容、要处理二进制与大文件、要给进度与取消 —— 那是另一个功能；
///   · 而"我记得文件名里有个 agent，帮我找出来"是**打开工作区后最常做的事**。
///
/// 有界体现在三处（都写死成默认参数，可在单测里改小）：
///   1. 忽略名单（复用 `WorkspaceTree.defaultIgnored`）；
///   2. **深度上限** —— 防止有人把工作区选到 `/` 或家目录后界面卡死；
///   3. **结果上限** —— 命中过多时停下来并如实告知"已达上限"，而不是悄悄截断。
///
/// 另外：**不跟随符号链接**（跟随会跑出工作区，甚至成环）。
public enum WorkspaceSearch {

    public static let defaultResultLimit = 200
    public static let defaultMaxDepth = 8

    /// 搜索结果。
    public struct Result: Equatable, Sendable {
        public var entries: [WorkspaceEntry]
        /// 是否因为命中上限而提前停止（界面应如实提示）。
        public var isTruncated: Bool
        public init(entries: [WorkspaceEntry], isTruncated: Bool) {
            self.entries = entries
            self.isTruncated = isTruncated
        }
    }

    /// 在工作区内按文件名递归搜索。
    ///
    /// 匹配规则：**大小写与变音符号不敏感的子串匹配**（`localizedCaseInsensitiveContains`）——
    /// 与访达一致，免得用户记不住大小写就搜不到。
    public static func findFileNames(
        in root: URL,
        query: String,
        limit: Int = defaultResultLimit,
        maxDepth: Int = defaultMaxDepth,
        ignored: Set<String> = WorkspaceTree.defaultIgnored,
        fileManager: FileManager = .default
    ) -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0, maxDepth >= 0 else {
            return Result(entries: [], isTruncated: false)
        }

        var matches: [WorkspaceEntry] = []
        var truncated = false
        var queue: [(url: URL, depth: Int)] = [(root, 0)]

        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard depth < maxDepth else { continue }
            guard let children = try? WorkspaceTree.children(
                of: directory, relativeTo: root, showHidden: false, ignored: ignored, fileManager: fileManager
            ) else { continue }

            for entry in children {
                switch entry.kind {
                case .symlink:
                    continue                      // 不跟随、也不报告：它可能指向工作区外
                case .directory:
                    queue.append((directory.appendingPathComponent(entry.name), depth + 1))
                case .file:
                    if entry.name.localizedCaseInsensitiveContains(trimmed) {
                        if matches.count >= limit {
                            truncated = true
                            return Result(entries: matches, isTruncated: true)
                        }
                        matches.append(entry)
                    }
                }
            }
        }

        return Result(
            entries: matches.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending },
            isTruncated: truncated
        )
    }
}
