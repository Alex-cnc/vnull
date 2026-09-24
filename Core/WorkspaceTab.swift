import Foundation

/// 工作区页签（FR-EDIT-35 / 36）。
///
/// **为什么不复用 `QueryTab`**：`QueryTab` 是 SQL 专用（`sql` / `connectionID` / `results` /
/// 事务态 / 执行状态…）。把"打开一个 JS 文件"塞进它，等于给一个已经承担执行语义的结构再加一套
/// 完全无关的状态 —— 最后会变成一个谁都不敢改的万能类。所以工作区页签**另起类型**，
/// 与 `QueryTab` 并列，各自演进。
public struct WorkspaceTab: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// 页签标题（Home 是「Home」，文件是文件名）。
    public var title: String
    /// 文件路径；`nil` = **Home 欢迎页**（工作区的默认页签，FR-EDIT-35）。
    public var path: String?
    public var language: TextLanguage
    /// 当前内容。
    public var content: String
    /// 上次读盘 / 存盘时的内容 —— `dirty` 由它俩比出来，不额外维护一个布尔（布尔迟早与内容不一致）。
    public var savedContent: String

    public init(id: UUID = UUID(), title: String, path: String? = nil, language: TextLanguage, content: String = "", savedContent: String? = nil) {
        self.id = id
        self.title = title
        self.path = path
        self.language = language
        self.content = content
        self.savedContent = savedContent ?? content
    }

    /// 是不是 Home 页。
    public var isHome: Bool { path == nil }

    /// 有未保存改动。
    public var isDirty: Bool { content != savedContent }

    /// 打开一个文件页签。
    public static func file(path: String, content: String) -> WorkspaceTab {
        WorkspaceTab(
            title: WorkspaceTabSet.title(for: path),
            path: path,
            language: TextLanguage.detect(path: path),
            content: content
        )
    }

    /// Home 页签。
    public static func home() -> WorkspaceTab {
        WorkspaceTab(title: "Home", language: .plainText)
    }

    /// 存盘成功：把"已保存内容"对齐到当前内容。
    public mutating func markSaved() {
        savedContent = content
    }
}

/// 工作区页签集合的**规则**（纯函数，可单测）。
public enum WorkspaceTabSet {

    /// 页签栏上显示的名字 = 路径最后一段。
    public static func title(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// 打开一个文件：
    /// - 已经开着 → **复用**（选中它），不重复开；
    /// - 没开过 → 追加到末尾并选中。
    ///
    /// 为什么"复用"是硬规则：同一个文件开成两个页签，改一边、存另一边，
    /// 是这类编辑器最经典的丢改动方式。
    public static func opening(path: String, in tabs: [WorkspaceTab], content: String) -> (tabs: [WorkspaceTab], selected: UUID) {
        if let existing = tabs.first(where: { $0.path == path }) {
            return (tabs, existing.id)
        }
        let tab = WorkspaceTab.file(path: path, content: content)
        return (tabs + [tab], tab.id)
    }

    /// 关闭一个页签：Home **关不掉**（它是工作区的落脚点，关了就没有默认页了）。
    public static func closing(id: UUID, in tabs: [WorkspaceTab]) -> [WorkspaceTab] {
        tabs.filter { $0.id != id || $0.isHome }
    }

    /// 选中项在关闭之后落到谁身上：优先它右边那个，没有就左边，都没有就返回 nil。
    public static func selection(afterClosing id: UUID, in tabs: [WorkspaceTab], selected: UUID?) -> UUID? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return selected }
        let remaining = closing(id: id, in: tabs)
        if remaining.contains(where: { $0.id == selected ?? id }) { return selected }
        if remaining.isEmpty { return nil }
        let fallback = min(index, remaining.count - 1)
        return remaining[fallback].id
    }
}
