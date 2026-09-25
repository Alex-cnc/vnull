import Foundation

/// 活动栏的**视图切换项**（FR-EDIT-32）。
///
/// 为什么把「切视图」与「动作」分成两个类型（`ActivityBarItem` / `ActivityBarAction`）：
/// 它们在同一根窄条上，但语义完全不同 —— 切换项有**选中态**、会变右侧面板；
/// 动作（设置 / 账户）没有选中态，只是按钮。混成一个枚举，
/// 迟早会出现"设置被选中了、右侧面板变成设置页"这种结构性问题。
public enum ActivityBarItem: String, CaseIterable, Sendable, Identifiable {
    // **顺序 = 栏上的上下位置**（2026-09-25 需求提出者：「活动栏排序调整一下：工作区在最上面」）。
    // `allCases` 的顺序就是显示顺序，所以"谁在上面"只由这里的声明顺序决定 ——
    // 别在视图里再排一次（两处顺序迟早不一致）。
    case workspace
    case database
    /// 笔记（DOYAH-01）：**Standard 版只有它**（许可证决定显示哪几项）。
    case notes

    public var id: String { rawValue }

    /// SF Symbol 名。窄条上图标就是全部信息量，所以选型要保证剪影可辨。
    public var symbolName: String {
        switch self {
        case .database: return "cylinder.split.1x2"
        case .workspace: return "folder"
        case .notes: return "note.text"
        }
    }

    /// 悬停提示与无障碍标签。
    public var titleKey: LKey {
        switch self {
        case .database: return .activityDatabase
        case .workspace: return .activityWorkspace
        case .notes: return .activityNotes
        }
    }

    /// 切换视图的菜单项文案（⇧⌘ 之外还给 ⌘1 / ⌘2）。
    public var menuKey: LKey {
        switch self {
        case .database: return .menuViewDatabase
        case .workspace: return .menuViewWorkspace
        case .notes: return .menuViewNotes
        }
    }

    /// 持久化键：与工程内其它 UI 偏好同一套 `ui.` 前缀。
    public static let storageKey = "ui.activityBarItem"

    /// 由持久化的 id 解析；**未知值一律回退到数据库视图**而不是报错
    /// （配置被手改、或将来删掉某个视图时，界面都必须照常起来）。
    public static func resolve(id: String?) -> ActivityBarItem {
        guard let id, !id.isEmpty else { return .database }
        return ActivityBarItem(rawValue: id) ?? .database
    }

    /// 菜单快捷键：⌘1 / ⌘2 / ⌘3（与 VS Code 的"按序号切视图"同一习惯）。
    ///
    /// 序号**跟着栏上的顺序**走：栏上第一项就是 ⌘1。写死成"数据库 = ⌘1"会让
    /// "按序号切视图"这条习惯失灵（用户按 ⌘1 期待的是最上面那个）。
    ///
    /// 正因为如此，序号**必须由"当前栏上可见的那几项"算**，不能写死在项上：
    /// 栏上有哪几项由许可证决定（Standard 只有笔记），Standard 下笔记就是 ⌘1，
    /// Ultra 下它才是 ⌘3。传可见列表进来，两处顺序就不可能不一致。
    /// 不可见 = 没有序号（返回 nil）—— 快捷键不该指向一个栏上不存在的视图。
    public static func shortcutIndex(
        of item: ActivityBarItem,
        in visibleItems: [ActivityBarItem]
    ) -> Int? {
        guard let position = visibleItems.firstIndex(of: item) else { return nil }
        return position + 1
    }
}

/// 活动栏底部的**动作**（不是视图）。
public enum ActivityBarAction: String, CaseIterable, Sendable, Identifiable {
    case account
    case settings

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .account: return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }

    public var titleKey: LKey {
        switch self {
        case .account: return .activityAccount
        case .settings: return .activitySettings
        }
    }
}
