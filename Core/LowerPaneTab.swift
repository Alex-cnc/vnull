import Foundation

/// 查询窗口下方面板的页签。
///
/// 这是「工作区下部那一块」的页签集合，与 VS Code 的底部面板同构：
/// 问题 / 输出 / 终端 / 调试控制台。
///
/// **刻意不含「结果」页签**：结果表是**数据**，属于查询自己的地盘（编辑器区 SQL 下方），
/// 而这个面板是**应用级**的通用面板。这样面板与产品未来无关 —— 不论以后只做数据库客户端、
/// 还是做成编程 IDE、或两者合集，这四个页签都成立。
public enum LowerPaneTab: String, CaseIterable, Identifiable, Sendable {
    /// 执行 SQL 的错误信息与语法诊断。
    case problem
    /// 执行 SQL 的任何输出（状态、影响行数、耗时、导出结果…）。
    case output
    /// 内嵌的本机 shell（FR-EDIT-29）。
    case terminal
    /// 占位：将来客户端具备编程 IDE 能力（断点 / 变量查看）时的调试控制台。
    case debugConsole

    public var id: String { rawValue }

    /// 页签标题的文案键。
    public var textKey: LKey {
        switch self {
        case .problem: return .lowerPaneProblem
        case .output: return .lowerPaneOutput
        case .terminal: return .lowerPaneTerminal
        case .debugConsole: return .lowerPaneDebugConsole
        }
    }

    /// 页签图标。
    public var symbolName: String {
        switch self {
        case .problem: return "exclamationmark.triangle"
        case .output: return "text.alignleft"
        case .terminal: return "terminal"
        case .debugConsole: return "ladybug"
        }
    }
}
