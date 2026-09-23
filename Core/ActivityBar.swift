import Foundation

/// 活动栏的**视图切换项**（FR-EDIT-32）。
///
/// 为什么把「切视图」与「动作」分成两个类型（`ActivityBarItem` / `ActivityBarAction`）：
/// 它们在同一根窄条上，但语义完全不同 —— 切换项有**选中态**、会变右侧面板；
/// 动作（设置 / 账户）没有选中态，只是按钮。混成一个枚举，
/// 迟早会出现"设置被选中了、右侧面板变成设置页"这种结构性问题。
public enum ActivityBarItem: String, CaseIterable, Sendable, Identifiable {
    case database
    case workspace

    public var id: String { rawValue }

    /// SF Symbol 名。窄条上图标就是全部信息量，所以选型要保证剪影可辨。
    public var symbolName: String {
        switch self {
        case .database: return "cylinder.split.1x2"
        case .workspace: return "folder"
        }
    }

    /// 悬停提示与无障碍标签。
    public var titleKey: LKey {
        switch self {
        case .database: return .activityDatabase
        case .workspace: return .activityWorkspace
        }
    }

    /// 切换视图的菜单项文案（⇧⌘ 之外还给 ⌘1 / ⌘2）。
    public var menuKey: LKey {
        switch self {
        case .database: return .menuViewDatabase
        case .workspace: return .menuViewWorkspace
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

    /// 菜单快捷键：⌘1 / ⌘2（与 VS Code 的"按序号切视图"同一习惯）。
    public var shortcutIndex: Int {
        switch self {
        case .database: return 1
        case .workspace: return 2
        }
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
