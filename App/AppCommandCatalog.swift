import SwiftUI
import DoyahCore

/// 命令面板的**命令清单**（FR-EDIT-25）。
///
/// 为什么清单在 App 侧而不是 Core：标题要本地化（`L(...)`），而 Core 不做本地化 ——
/// 与 `AppShortcut` / `MenuLocalization` 的处理方式一致。
///
/// 每条命令的 `id` 是**稳定标识**：`AppState.performPaletteCommand(_:)` 按它分派。
/// 不要用标题做标识 —— 改文案就会把动作改没（这条在别处踩过）。
enum AppCommandCatalog {

    /// 面板要列出的命令。顺序即"同分时的默认顺序"，因此把高频的放前面。
    static func all() -> [CommandPalette.Item] {
        [
            item("newQuery", .commandNewQuery, "new query nq 新建 查询", "new query nq", .paletteCategoryQuery),
            item("execute", .commandExecute, "execute run 执行 运行", "execute run", .paletteCategoryQuery),
            item("stop", .commandStop, "stop cancel 停止 取消", "stop cancel", .paletteCategoryQuery),
            item("check", .commandCheck, "check explain 语法 检查", "check explain", .paletteCategoryQuery),
            item("format", .commandFormat, "format fmt 格式化", "format fmt", .paletteCategoryQuery),
            item("executionPlan", .commandExecutionPlan, "explain plan 执行计划", "execution plan explain", .paletteCategoryQuery),
            item("find", .commandFind, "find 查找", "find", .paletteCategoryQuery),
            item("replace", .commandReplace, "replace 替换", "replace", .paletteCategoryQuery),
            item("goToLine", .commandGoToLine, "goto line 跳转 行", "go to line", .paletteCategoryQuery),
            item("exportCSV", .commandExportCSV, "export csv 导出", "export csv", .paletteCategoryResult),
            item("exportJSON", .commandExportJSON, "export json 导出", "export json", .paletteCategoryResult),
            item("browseRows", .commandBrowseRows, "browse rows 浏览 表", "browse rows", .paletteCategoryObject),
            item("tableDDL", .commandTableDDL, "ddl 查看 建表 结构", "view ddl", .paletteCategoryObject),
            // 全库对象搜索（FR-META-12）：与对象树工具条的放大镜打开同一个面板。
            item("backupRestore", .backupRestoreTitle, "backup restore dump 备份 恢复 导出", "backup restore", .paletteCategoryServer),
            item("routineCandidates", .routineCandidatesTitle, "routine 例行 候选 记忆 重复", "routine candidates", .paletteCategoryAgent),
            item("objectSearch", .objectSearchTitle, "search 搜索 找 对象 表 视图 列 函数", "search objects find", .paletteCategoryObject),
            item("sessions", .commandSessions, "sessions 会话", "server sessions", .paletteCategoryServer),
            item("locks", .commandLocks, "locks 锁 阻塞", "locks blocking", .paletteCategoryServer),
            item("switchConnection", .commandSwitchConnection, "connection conn 切换 连接", "switch connection", .paletteCategoryServer),
            item("agentSQL", .commandAgentSQL, "agent nl2sql 智能体 自然语言 生成 sql", "agent nl2sql", .paletteCategoryAgent),
            item("syntheticData", .commandSyntheticData, "synthetic data 合成 测试数据", "synthetic data", .paletteCategoryAgent),
            item("egressLog", .commandEgressLog, "egress log 外发 日志", "egress log", .paletteCategoryAgent),
            item("help", .commandHelp, "help 帮助 快捷键", "help shortcuts", .paletteCategoryHelp),
        ]
    }

    /// 面板右侧显示的快捷键提示（有就用同一份事实来源 `AppShortcut`，没有就留空）。
    static func shortcutHint(for id: String) -> String? {
        switch id {
        case "execute": return shortcutText(.execute)
        case "stop": return shortcutText(.stop)
        case "check": return shortcutText(.check)
        case "format": return shortcutText(.format)
        case "executionPlan": return shortcutText(.executionPlan)
        case "find": return shortcutText(.find)
        case "replace": return shortcutText(.replace)
        case "goToLine": return shortcutText(.goToLine)
        case "help": return shortcutText(.help)
        case "egressLog": return shortcutText(.egressLog)
        default: return nil
        }
    }

    private static func shortcutText(_ shortcut: AppShortcut) -> String {
        // 与 tooltip / 帮助面板共用同一份事实来源（`AppShortcut`），避免"改了键、提示没改"。
        shortcut.display
    }

    private static func item(
        _ id: String,
        _ titleKey: LKey,
        _ keywordText: String,
        _ englishKeywords: String,
        _ categoryKey: LKey
    ) -> CommandPalette.Item {
        CommandPalette.Item(
            id: id,
            title: L(titleKey),
            // 关键词同时收中文与英文：输入 `fmt` 或 `格式` 都要能命中。
            keywords: keywordText.split(separator: " ").map(String.init) + [englishKeywords],
            category: L(categoryKey)
        )
    }
}
