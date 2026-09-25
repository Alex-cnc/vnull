import Foundation

/// **许可证 → 界面呈现什么**（FR-LIC-02 / FR-NOTE-25）。
///
/// 为什么这条规则放 Core 而不是视图里：它是"哪个版本能看到哪几块"的**唯一判据**，
/// 放 Core 才能被单测穷举（三档 × 三块 = 9 种组合都钉住），而视图只负责照着画。
public enum LicensePresentation {

    /// 活动栏按能力位显示哪几项。
    ///
    /// **未授权的区不出现**（不是灰掉诱导）—— 这是 Q11 拍板口径。
    /// 顺序沿用 `ActivityBarItem.allCases`（"谁在上面"只由那里决定，不许在视图里再排一次）。
    public static func activityItems(for capabilities: LicenseCapabilities) -> [ActivityBarItem] {
        ActivityBarItem.allCases.filter { item in
            switch item {
            case .workspace: return capabilities.contains(.workspaces)
            case .database: return capabilities.contains(.database)
            case .notes: return capabilities.contains(.notes)
            }
        }
    }

    /// 当前档位下**默认打开哪一项**（原来的选中项在新档位里不可见时用它兜底）。
    ///
    /// 兜底顺序刻意是"笔记优先"：三档里**只有笔记是每一档都有**的能力，
    /// 于是无论许可证怎么变，界面总能落到一个用户看得见的页面上，不会出现"选中项指向不存在的视图"。
    public static func fallbackItem(for capabilities: LicenseCapabilities) -> ActivityBarItem? {
        let visible = activityItems(for: capabilities)
        if visible.contains(.notes) { return .notes }
        return visible.first
    }

    /// 把"上次选中的项"落到当前档位下**真正能打开的那一项**上。
    ///
    /// 这就是「Standard 下工作区与数据库不可达」这条口径的唯一落点：
    /// 历史偏好（`ui.activityBarItem`）、快捷键、命令面板、代码里直接赋值 ——
    /// 这些入口**都要经过这里**，否则总有一条路能钻进未授权的区（"屏蔽"就成了摆设）。
    /// 返回 `nil` 只在**一个区都没授权**时出现（坏许可证）；那时界面照常起来，只是没有可切项。
    public static func resolveSelection(
        _ selected: ActivityBarItem,
        for capabilities: LicenseCapabilities
    ) -> ActivityBarItem? {
        let visible = activityItems(for: capabilities)
        if visible.contains(selected) { return selected }
        return fallbackItem(for: capabilities)
    }

    /// 「关于 / 升级」页要显示的各版功能（Q11：**逐条列出**，不能只写"解锁更多"）。
    ///
    /// **只列比当前更高的档位**：Ultra 用户看到下面还有两档可"升级"是纯粹的噪音，
    /// 而 Pro 用户看到 Standard 更是向下推销（他要的是往上走）。排在当前档之前的都不列。
    public static func upgradeLines(for current: LicenseEdition) -> [(edition: LicenseEdition, items: [String])] {
        LicenseEditionCatalog.features
            .filter { $0.edition.rank > current.rank }
            .sorted { $0.edition.rank < $1.edition.rank }
    }

    /// 档位在界面上的名字键。
    ///
    /// **只给键、不给文案** —— 语言由界面按当前语言取。Core 直接返回中文会让
    /// 「切到英文但这一页还是中文」（R-45 记的就是这类问题），所以新增的呈现文案一律走键。
    /// 名字里带上"这一档到底给了什么"：只写 "Pro" 等于没说，用户得回去翻文档。
    public static func displayNameKey(of edition: LicenseEdition) -> LKey {
        switch edition {
        case .standard: return .licEditionStandard
        case .pro: return .licEditionPro
        case .ultra: return .licEditionUltra
        }
    }
}
