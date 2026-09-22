import Foundation

/// 查询窗口下方面板的页签。
///
/// 这是「工作区下部那一块」的页签集合 —— 它**不是**独立新增的区域，而是把原来的
/// Result（结果表）区域升级成多页签面板，与 VS Code 的底部面板同构：
/// 结果 / 问题 / 输出 / 终端 / 调试控制台。
public enum LowerPaneTab: String, CaseIterable, Identifiable, Sendable {
    /// 结果表（原来的 Result 区域，默认页签）。
    case result
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
        case .result: return .lowerPaneResult
        case .problem: return .lowerPaneProblem
        case .output: return .lowerPaneOutput
        case .terminal: return .lowerPaneTerminal
        case .debugConsole: return .lowerPaneDebugConsole
        }
    }

    /// 页签图标。
    public var symbolName: String {
        switch self {
        case .result: return "tablecells"
        case .problem: return "exclamationmark.triangle"
        case .output: return "text.alignleft"
        case .terminal: return "terminal"
        case .debugConsole: return "ladybug"
        }
    }
}
