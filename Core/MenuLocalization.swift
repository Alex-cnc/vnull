import Foundation

/// 菜单栏文案的**反向映射**（NFR-I18N-03）。
///
/// 为什么需要它：SwiftUI 的 `.commands` 在语言切换时**只重建菜单标题**，
/// 菜单里的叶子项（`Button` / `CommandGroup` 项）会停在启动时的语言。
/// 2026-09-22 在本机实测（App 内探针直接读 `NSApp.mainMenu`，未开图形界面）：
///
/// ```
/// 启动 en → 切成 zh-Hans
///   菜单标题   Agent            → 智能体      ✅ 变了
///   标题下子项 Agent settings…   → 智能体设置…  ❌ 没变（递归 NSMenu.update() 也不变）
///   文件 > New Query            → 新建查询      ❌ 没变
/// ```
///
/// 所以 App 层要在语言切换后，按「原文案 → 目标语言」把菜单项逐个改回来。
/// 反向映射放在 Core 而不是 App：这是纯函数，能单测；App 侧只剩遍历 `NSMenu` 的胶水。
public enum MenuLocalization {

    /// 菜单栏里由本 App 提供文案的键，与 `App/DoyahStudioCommands.swift` 一一对应。
    ///
    /// **新增菜单项时必须同时加到这里**，否则那一项会停在旧语言。
    /// `MenuLocalizationTests` 会校验「所有 `menu` 前缀的键都已登记」，防止漏加。
    public static let menuKeys: [LKey] = [
        .menuNewQuery,
        .menuAgent,
        .menuAgentSettings,
        .menuAgentGenerateSQL,
        .menuDataTask,
        .menuAgentAudit,
        .menuEgressLog,
        .menuLanguage,
        .menuAppearance,
        .menuViewDatabase,
        .menuViewWorkspace
    ]

    /// 把「任意受支持语言下的自有菜单标题」翻成目标语言。
    ///
    /// 只认**自有菜单项**；系统菜单（文件 / 编辑 / 显示 / 窗口 / 帮助 / 服务…）不在此表内，
    /// 返回 `nil`，由调用方原样保留。理由：那些标题由 AppKit 按应用包语言渲染，
    /// 运行时切换语言本来就改不动它们（实测切到英文后它们仍是中文），
    /// 硬去改只会让系统菜单中英混杂，比放着更糟。
    public static func retitled(_ title: String, to language: AppLanguage) -> String? {
        for key in menuKeys {
            for candidate in AppLanguage.allCases
            where LocalizedStrings.text(key, language: candidate) == title {
                return LocalizedStrings.text(key, language: language)
            }
        }
        return nil
    }
}
