import Foundation

/// 一条"最近打开"记录（FR-EDIT-35 的 Home 欢迎页要用）。
public struct WorkspaceHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let openedAt: Date

    public var id: String { path }

    public init(path: String, openedAt: Date = Date()) {
        self.path = path
        self.openedAt = openedAt
    }

    /// 显示名 = 最后一段（Home 上不展示整条长路径）。
    public var displayName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// Home 页的"最近打开"两份清单：**文件**与**工作区目录**。
///
/// 规则刻意简单且可单测：
/// · 同一个路径只留一条（重复打开只是把它置顶，不是再记一条）；
/// · 最近打开的在前；
/// · 各有限额（文件 20 / 工作区 10）—— 欢迎页是"回到上次"，不是历史博物馆。
///
/// **不存内容**：只记路径与时间。存内容会让这个文件变成代码库的副本（体积、陈旧、以及"我到底在编辑哪一份"）。
public struct WorkspaceHistory: Codable, Sendable, Equatable {
    public var files: [WorkspaceHistoryEntry]
    public var workspaces: [WorkspaceHistoryEntry]

    public static let fileLimit = 20
    public static let workspaceLimit = 10

    public init(files: [WorkspaceHistoryEntry] = [], workspaces: [WorkspaceHistoryEntry] = []) {
        self.files = files
        self.workspaces = workspaces
    }

    /// 记一次"打开了文件"。
    public static func recording(file path: String, at moment: Date = Date(), into history: WorkspaceHistory) -> WorkspaceHistory {
        var copy = history
        copy.files = updated(history.files, with: path, at: moment, limit: fileLimit)
        return copy
    }

    /// 记一次"切换了工作区"。
    public static func recording(workspace path: String, at moment: Date = Date(), into history: WorkspaceHistory) -> WorkspaceHistory {
        var copy = history
        copy.workspaces = updated(history.workspaces, with: path, at: moment, limit: workspaceLimit)
        return copy
    }

    /// 移除一条（文件被删了、工作区不想再看到）。
    public static func removing(file path: String, from history: WorkspaceHistory) -> WorkspaceHistory {
        var copy = history
        copy.files.removeAll { $0.path == path }
        return copy
    }

    public static func removing(workspace path: String, from history: WorkspaceHistory) -> WorkspaceHistory {
        var copy = history
        copy.workspaces.removeAll { $0.path == path }
        return copy
    }

    private static func updated(_ entries: [WorkspaceHistoryEntry], with path: String, at moment: Date, limit: Int) -> [WorkspaceHistoryEntry] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        var result = entries.filter { $0.path != trimmed }
        result.insert(WorkspaceHistoryEntry(path: trimmed, openedAt: moment), at: 0)
        return Array(result.prefix(limit))
    }
}
