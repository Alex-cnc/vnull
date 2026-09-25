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
        // 诊断这条查询（FR-AI-03）：菜单叶子项同样要能运行时切语言。
        .menuDiagnoseQuery,
        // 维护任务编排（FR-AI-04）：同上。
        .menuMaintenanceTasks,
        // 外部调用审批（FR-AI-10 界面那一半）：同上。
        .menuMCPApprovals,
        // 笔记（DOYAH-01/03）。
        .menuNotes,
        .menuDataTask,
        .menuAgentAudit,
        .menuEgressLog,
        .menuNewBrowserTab,
        .menuLanguage,
        .menuAppearance,
        .menuConnectionSettings,
        // 服务器级对象（FR-SESS-03）：菜单叶子项也要能在运行时切语言，故走 menu 前缀并登记。
        .menuServerObjects,
        .menuERDiagram,
        // 导入数据（FR-IO-03）：与「归档…」同住「文件」菜单，同样需要运行时切语言。
        .menuImportData,
        .menuViewDatabase,
        .menuViewWorkspace,
        // 下面这几个是 2026-09-24 补登的**历史遗漏**：它们是自有菜单项，但键没有 `menu` 前缀
        // （`.archiveTitle` / `.databaseStatsTitle` / `.schemaDiffTitle` / `.lowerPaneToggle`），
        // 于是"所有 menu 前缀的键都已登记"那条测试一直没抓到它们 —— 实测切到中文后
        // `Query Archive` / `Database statistics` / `Schema diff and sync` / `Show/Hide Bottom Pane`
        // 四项停在英文。测试已改成按**菜单项来源清单**核对，不再只看前缀。
        .archiveTitle,
        .databaseStatsTitle,
        .schemaDiffTitle,
        .lowerPaneToggle,
        .menuRelaunchApp
    ]

    /// 把「任意受支持语言下的标题」翻成目标语言（自有菜单项 + 系统菜单的**顶层标题**）。
    ///
    /// 系统菜单（文件 / 编辑 / 显示 / 窗口 / 帮助 / 服务）的标题由 AppKit 按**启动语言**渲染，
    /// 运行时改 `AppleLanguages` 对当前进程无效 —— 但 `NSMenuItem.title` 是普通属性，
    /// **我们直接写就能变**（2026-09-24 起就这么做，于是"换语言要重启"这条限制去掉了）。
    /// 顶层菜单没有 action，只能按标题查；叶子项走 `retitled(action:appName:to:)`（更可靠）。
    public static func retitled(_ title: String, to language: AppLanguage) -> String? {
        for key in menuKeys + systemMenuTitles {
            for candidate in AppLanguage.allCases
            where LocalizedStrings.text(key, language: candidate) == title {
                return LocalizedStrings.text(key, language: language)
            }
        }
        return nil
    }

    // MARK: - 系统菜单（AppKit 渲染的那些）

    /// **带应用名**的系统菜单项：文案里有 `%@`，由调用方把 `CFBundleName` 传进来。
    /// 名字不写死在文案里 —— 改名时这里不用跟着改。
    public static let systemMenuAppNamedKeys: Set<LKey> = [
        .menuSystemAbout, .menuSystemHide, .menuSystemQuit, .menuSystemAppHelp
    ]

    /// 系统菜单**叶子项**：按 **action selector** 认，不按标题。
    ///
    /// 为什么按 selector：标题随启动语言变（英文启动是 `Undo`、中文启动是 `撤销`），
    /// selector 与语言无关；按标题查表就得把"两种语言的所有写法"都列出来，按 selector 只要一份。
    /// 表里的 selector 是从**本机运行中的应用**直接 dump 出来的（见 `Docs/需求规范书.md` NFR-I18N-03）。
    public static let systemMenuItems: [String: LKey] = [
        "orderFrontStandardAboutPanel:": .menuSystemAbout,
        "hide:": .menuSystemHide,
        "hideOtherApplications:": .menuSystemHideOthers,
        "unhideAllApplications:": .menuSystemShowAll,
        "terminate:": .menuSystemQuit,
        "performClose:": .menuSystemClose,
        "closeAll:": .menuSystemCloseAll,
        "undo:": .menuSystemUndo,
        "redo:": .menuSystemRedo,
        "cut:": .menuSystemCut,
        "copy:": .menuSystemCopy,
        "paste:": .menuSystemPaste,
        "delete:": .menuSystemDelete,
        "selectAll:": .menuSystemSelectAll,
        "_handleInsertFromContactsCommand:": .menuSystemContact,
        "_handleInsertFromPasswordsCommand:": .menuSystemPasswords,
        "_handleInsertFromCreditCardsCommand:": .menuSystemCreditCard,
        "startDictation:": .menuSystemDictation,
        "orderFrontCharacterPalette:": .menuSystemEmoji,
        "performMiniaturize:": .menuSystemMinimize,
        "performZoom:": .menuSystemZoom,
        "arrangeInFront:": .menuSystemBringAllToFront,
        "toggleFullScreen:": .menuSystemEnterFullScreen,
        "toggleSidebar:": .menuSystemToggleSidebar,
        "showHelp:": .menuSystemAppHelp
    ]

    /// 系统菜单的**顶层标题**（没有 action，只能按标题认）：自有菜单项之外的这些。
    public static let systemMenuTitles: [LKey] = [
        .menuSystemFile,
        .menuSystemEdit,
        .menuSystemView,
        .menuSystemWindow,
        .menuSystemHelp,
        .menuSystemServices,
        .menuSystemAutoFill
    ]

    /// 系统菜单叶子项：按 selector 取文案（带应用名的项用 `appName` 填 `%@`）。
    ///
    /// 表里没有的 selector 返回 `nil`，调用方退回按标题查 —— 这样即使某个 AppKit 版本改了
    /// selector 名，也只是那一项退回旧行为，不会把整棵菜单弄乱。
    public static func retitled(action selector: String, appName: String, to language: AppLanguage) -> String? {
        guard let key = systemMenuItems[selector] else { return nil }
        let template = LocalizedStrings.text(key, language: language)
        guard systemMenuAppNamedKeys.contains(key) else { return template }
        return String(format: template, locale: language.locale, appName)
    }
}
