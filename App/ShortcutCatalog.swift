import SwiftUI

/// 工具栏 / 菜单快捷键的**单一事实来源**（FR-EDIT-28）。
///
/// 为什么要集中：快捷键同时出现在三个地方 —— 视图上的 `.keyboardShortcut`、
/// 按钮 tooltip、帮助面板列表。散着写必然出现「改了键、提示没改」。
/// 这里一处定义，三处引用。
///
/// 选键原则：
/// - 不占用系统级快捷键（⌘Q / ⌘W / ⌘H / ⌘M / ⌘,）；
/// - 高频动作用最短的组合（执行 ⌘↩、停止 ⌘.、查找 ⌘F）；
/// - 成组的动作用同一前缀（运行范围 ⌥⌘1/2/3、保存类 ⌘S / ⇧⌘S / ⌘D / ⇧⌘D）；
/// - ⌘K 预留给命令面板（FR-EDIT-25），此处不得占用。
enum AppShortcut: CaseIterable {
    /// 执行查询（需求 FR-EDIT-08 / FR-EXEC-13 明确指定 ⌘↩）。
    case execute
    case stop
    case check
    /// 执行计划面板（FR-DIAG-01）。
    case executionPlan

    case openFile
    case saveFile
    case saveFileAs
    case saveQuery
    case savedQueries
    case history

    case find
    case replace
    case goToLine
    case indent
    case outdent
    case clearEditor
    case format

    case scopeAll
    case scopeCurrentStatement
    case scopeSelection

    case safeMode
    case confirmAllWrites

    /// 智能体审批与审计面板（FR-AI-09）。
    case agentAudit

    /// 统一外发日志面板（NFR-SEC-08）。
    case egressLog

    /// 数据任务面板（FR-AI-05 / FR-AI-06 / FR-AI-08）。
    case dataTask

    case help

    /// 底部终端面板（显示 / 隐藏）。
    case terminal

    /// 查询归档（FR-EDIT-31）。
    case archive

    var key: KeyEquivalent {
        switch self {
        case .execute: return .return
        case .stop: return "."
        case .check: return "e"
        case .executionPlan: return "p"
        case .openFile: return "o"
        case .saveFile: return "s"
        case .saveFileAs: return "s"
        case .saveQuery: return "d"
        case .savedQueries: return "d"
        case .history: return "h"
        case .find: return "f"
        case .replace: return "f"
        case .goToLine: return "l"
        case .indent: return "]"
        case .outdent: return "["
        case .clearEditor: return "k"
        case .format: return "f"
        case .scopeAll: return "1"
        case .scopeCurrentStatement: return "2"
        case .scopeSelection: return "3"
        case .safeMode: return "s"
        case .confirmAllWrites: return "w"
        case .agentAudit: return "a"
        case .egressLog: return "e"
        case .dataTask: return "t"
        case .help: return "/"
        case .terminal: return "j"
        case .archive: return "r"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .execute, .openFile, .saveFile, .saveQuery, .indent, .outdent, .goToLine, .find:
            return [.command]
        case .stop:
            return [.command]
        case .check, .executionPlan, .saveFileAs, .savedQueries, .history, .clearEditor, .format, .agentAudit, .egressLog, .dataTask, .help, .terminal, .archive:
            return [.command, .shift]
        case .replace, .scopeAll, .scopeCurrentStatement, .scopeSelection, .safeMode, .confirmAllWrites:
            return [.command, .option]
        }
    }

    /// 「⌘↩」这样的展示文本（tooltip 与帮助面板共用）。
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        text += key == .return ? "↩" : String(key.character)
        return text
    }

    /// 按钮 tooltip：`执行 SQL（⌘↩）`。
    ///
    /// 提示文案本身**不再内嵌按键**，统一由这里追加，避免两处各写一份。
    func help(_ title: String) -> String {
        "\(title)（\(display)）"
    }
}
