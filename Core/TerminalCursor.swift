import Foundation

/// 终端光标形状（FR-EDIT-29）。
///
/// 两个来源，优先级要分清楚（否则"我设了块状怎么还是竖线"会变成悬案）：
/// 1. **前台程序**用 DECSCUSR（`CSI Ps SP q`）要求的样子 —— 它在运行时说了算（vim 插入模式要竖线）；
/// 2. 用户偏好 —— 前台程序**没要求**时的默认（`TerminalScreen.requestedCursor` 为 nil）。
public enum TerminalCursorStyle: String, CaseIterable, Sendable {
    case block
    case bar
    case underline

    /// 界面标签（走 Core 语言表：棘轮会拦"新写的用户可见中文"，这是它应该拦的）。
    public func label(language: AppLanguage = .simplifiedChinese) -> String {
        switch self {
        case .block: return LocalizedStrings.text(.terminalCursorBlock, language: language)
        case .bar: return LocalizedStrings.text(.terminalCursorBar, language: language)
        case .underline: return LocalizedStrings.text(.terminalCursorUnderline, language: language)
        }
    }
}

/// 光标外观 = 形状 + 是否闪烁。
public struct TerminalCursorAppearance: Equatable, Sendable {
    public var style: TerminalCursorStyle
    public var blinks: Bool

    public init(style: TerminalCursorStyle = .block, blinks: Bool = true) {
        self.style = style
        self.blinks = blinks
    }

    public static let `default` = TerminalCursorAppearance()

    /// DECSCUSR（`CSI Ps SP q`）的参数 → 外观。
    ///
    /// 规范（xterm ctlseqs）里的六个取值，**0 与 1 同义**（都是"闪烁块状"，0 是缺省）：
    /// 0/1 闪烁块、2 稳定块、3 闪烁下划线、4 稳定下划线、5 闪烁竖线、6 稳定竖线。
    /// 认不出的参数返回 `nil` —— **不改**当前形状（比"猜一个"更安全：猜错会让光标突然变形）。
    public static func fromDECSCUSR(_ parameter: Int) -> TerminalCursorAppearance? {
        switch parameter {
        case 0, 1: return TerminalCursorAppearance(style: .block, blinks: true)
        case 2: return TerminalCursorAppearance(style: .block, blinks: false)
        case 3: return TerminalCursorAppearance(style: .underline, blinks: true)
        case 4: return TerminalCursorAppearance(style: .underline, blinks: false)
        case 5: return TerminalCursorAppearance(style: .bar, blinks: true)
        case 6: return TerminalCursorAppearance(style: .bar, blinks: false)
        default: return nil
        }
    }

    /// 供命令行 / 日志用的一句话。
    public func description(language: AppLanguage = .simplifiedChinese) -> String {
        let blink = LocalizedStrings.text(
            blinks ? .terminalCursorBlinking : .terminalCursorSteady,
            language: language
        )
        return "\(style.label(language: language))（\(blink)）"
    }
}

/// 光标形状的用户偏好（FR-EDIT-29）：与终端字号同一套"存进偏好、读回来夹取/回落"的纪律。
public struct TerminalCursorPreference: Equatable, Sendable {

    public var appearance: TerminalCursorAppearance

    public init(appearance: TerminalCursorAppearance = .default) {
        self.appearance = appearance
    }

    public static let `default` = TerminalCursorPreference()

    /// 从偏好读回来：认不出的值回落成默认（不让偏好被手改后终端起不来）。
    public static func resolve(style: Any?, blinks: Any?) -> TerminalCursorPreference {
        guard let raw = style as? String, let parsed = TerminalCursorStyle(rawValue: raw) else {
            return .default
        }
        let blink = (blinks as? Bool) ?? true
        return TerminalCursorPreference(appearance: TerminalCursorAppearance(style: parsed, blinks: blink))
    }

    public enum Storage {
        public static let styleKey = "terminal.cursorStyle"
        public static let blinksKey = "terminal.cursorBlinks"
    }
}
