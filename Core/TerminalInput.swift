import Foundation

/// 终端**输入与应答**的纯函数层（FR-EDIT-29）。
///
/// 为什么单独放一层：这些东西全是"给定状态 → 一串字节"的纯映射（方向键要不要走 SS3、
/// 鼠标事件怎么编码、设备查询怎么回话），把它们从视图里拎出来才能在 Core 单测里钉住，
/// 也才能在命令行上一眼看懂（`doyah terminal-modes`）。视图只负责把 AppKit 事件翻成
/// 这一层的入参。
///
/// 规范来源：xterm 的 [Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.txt)
/// （底本 ECMA-48 / ISO 6429）。**哪些是规范、哪些是惯例**，逐条标在下面 —— 上一轮核对
/// 语义清单时就是这么做的，这里沿用同一口径。
public enum TerminalInput {

    // MARK: - 光标键（DECCKM）

    public enum CursorKey: String, CaseIterable, Sendable {
        case up, down, right, left, home, end

        /// 普通模式（CSI 形式）的终止字符。
        var csiFinal: String {
            switch self {
            case .up: return "A"
            case .down: return "B"
            case .right: return "C"
            case .left: return "D"
            case .home: return "H"
            case .end: return "F"
            }
        }
    }

    /// 方向键 / Home / End 的字节。
    ///
    /// - Parameter applicationCursorKeys: DECCKM（`?1`）是否置位。置位时用 **SS3**（`ESC O x`），
    ///   否则用 CSI（`ESC [ x`）。这是规范（xterm ctlseqs 的 DECCKM 条目），不是惯例 ——
    ///   vim / less / 部分 TUI 靠它区分"方向键"与"应用光标键"。
    public static func cursorKey(_ key: CursorKey, applicationCursorKeys: Bool) -> [UInt8] {
        let prefix = applicationCursorKeys ? "\u{1B}O" : "\u{1B}["
        return Array((prefix + key.csiFinal).utf8)
    }

    // MARK: - 鼠标上报

    /// 鼠标追踪模式（DECSET 1000 / 1002 / 1003）。
    public enum MouseTrackingMode: Int, Sendable, CaseIterable {
        /// 不上报（本地选中）。
        case none = 0
        /// `?1000`：只上报按下 / 松开（含滚轮）。
        case click = 1000
        /// `?1002`：按住拖动时上报移动。
        case buttonEvent = 1002
        /// `?1003`：任何移动都上报。
        case anyEvent = 1003

        public var displayName: String {
            switch self {
            case .none: return "关闭"
            case .click: return "仅点击（?1000）"
            case .buttonEvent: return "按住拖动（?1002）"
            case .anyEvent: return "任何移动（?1003）"
            }
        }
    }

    public enum MouseButton: Int, Sendable {
        case left = 0
        case middle = 1
        case right = 2
        /// 松开（旧式编码里用 3 表示"哪个键松开了"）。
        case release = 3
    }

    public struct MouseModifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = MouseModifiers(rawValue: 4)
        public static let option = MouseModifiers(rawValue: 8)
        public static let control = MouseModifiers(rawValue: 16)
    }

    public enum MouseAction: Equatable, Sendable {
        case press
        case release
        case motion
        case wheelUp
        case wheelDown
    }

    public struct MouseEvent: Equatable, Sendable {
        public var action: MouseAction
        public var button: MouseButton
        public var modifiers: MouseModifiers
        /// 1 基的列与行（终端坐标，不是视图坐标）。
        public var column: Int
        public var row: Int

        public init(action: MouseAction, button: MouseButton, modifiers: MouseModifiers = [], column: Int, row: Int) {
            self.action = action
            self.button = button
            self.modifiers = modifiers
            self.column = column
            self.row = row
        }
    }

    /// 鼠标事件 → 上报字节。
    ///
    /// 两种编码：
    /// - **旧式（X10 / normal）**：`ESC [ M` + 三个字节 `(32+按钮码)(32+列)(32+行)`，
    ///   坐标 1 基、各加 32；松开统一用按钮码 3（规范如此，编码里表达不出"哪个键松开"）。
    ///   单字节上限 223 ⇒ 行 / 列超过 191 时**截断到 223**（xterm 同样无法表达，宁可截断也不发出
    ///   会被误解成别的按钮的字节）。
    /// - **SGR（`?1006`）**：`ESC [ < 按钮码 ; 列 ; 行 M`（按下 / 移动 / 滚轮）或结尾 `m`（松开），
    ///   坐标 1 基、**不加 32**，因此没有 223 的限制，也分得清松开的是哪个键。
    ///
    /// 按钮码：左 0 / 中 1 / 右 2、滚轮上 64 / 下 65，移动再 +32，修饰键 ⇧+4 / ⌥+8 / ⌃+16。
    public static func mouseReport(_ event: MouseEvent, sgr: Bool) -> [UInt8] {
        var code: Int
        switch event.action {
        case .press: code = event.button.rawValue
        case .release: code = sgr ? event.button.rawValue : MouseButton.release.rawValue
        case .motion: code = event.button.rawValue + 32
        case .wheelUp: code = 64
        case .wheelDown: code = 65
        }
        code += event.modifiers.rawValue

        let column = max(1, event.column)
        let row = max(1, event.row)

        if sgr {
            // SGR 里松开用终止符 `m` 区分，按钮码保持原样。
            let final = event.action == .release ? "m" : "M"
            return Array("\u{1B}[<\(code);\(column);\(row)\(final)".utf8)
        }

        let clamp: (Int) -> Int = { min(223, 32 + $0) }
        return [0x1B, 0x5B, 0x4D, UInt8(clamp(code)), UInt8(clamp(column)), UInt8(clamp(row))]
    }

    /// 这个事件在当前模式下要不要上报。
    ///
    /// 规范 / 惯例的分界：`?1000` 只报按下松开与滚轮；`?1002` 额外在**按住**时报移动
    /// （这是我们自己判断的"按住"，因为 xterm 的 report 里没有"当前按住哪个键"这个概念，
    /// 视图在拖动期间自然会带上按键）；`?1003` 任何移动都报。
    public static func shouldReport(_ event: MouseEvent, mode: MouseTrackingMode) -> Bool {
        guard mode != .none else { return false }
        switch event.action {
        case .press, .release, .wheelUp, .wheelDown:
            return true
        case .motion:
            return mode == .buttonEvent || mode == .anyEvent
        }
    }

    // MARK: - 设备查询应答

    /// 主设备属性（DA1，`CSI c`）。
    ///
    /// 回 `ESC [ ? 1 ; 2 c`：VT100 + Advanced Video Option —— 这是 xterm 的 DA1 回法，
    /// 也是最保守的一种（只声明最基础的能力）。**不夸大**：我们没实现六线图 / kitty 图形，
    /// 就不去声明那些能力位。
    public static func primaryDeviceAttributes() -> [UInt8] {
        Array("\u{1B}[?1;2c".utf8)
    }

    /// 次设备属性（DA2，`CSI > c`）。
    ///
    /// 回 `ESC [ > 0 ; 0 ; 0 c`（终端类型 VT100、固件版本 0、无 ROM 卡带）。
    /// **为什么版本写 0 而不是抄 xterm 的 276**：DA2 的版本号会被程序用来推断"有哪些扩展能力"，
    /// 抄一个高版本等于承诺我们并没有实现的功能；写 0 表示"未知 / 基础"，程序会走保守分支。
    public static func secondaryDeviceAttributes() -> [UInt8] {
        Array("\u{1B}[>0;0;0c".utf8)
    }

    /// 设备状态报告（DSR 5）：`ESC [ 0 n` = 一切正常。
    public static func statusReportOK() -> [UInt8] {
        Array("\u{1B}[0n".utf8)
    }

    /// 光标位置报告（DSR 6）：`ESC [ 行 ; 列 R`，**1 基**。
    ///
    /// 传进来的必须是**已经按原址模式换算过**的坐标（`?6` 置位时相对滚动区顶部），
    /// 换算在 `TerminalScreen` 里做 —— 那里才知道滚动区。
    public static func cursorPositionReport(row: Int, column: Int) -> [UInt8] {
        Array("\u{1B}[\(max(1, row));\(max(1, column))R".utf8)
    }

    /// DECRPM（模式报告，`CSI ? Ps $ p`）。
    ///
    /// 回 `ESC [ ? Ps ; Pm $ y`，`Pm`：**0** 不认识 / **1** 已置位 / **2** 已复位。
    /// 3 / 4 是"永久置位 / 永久复位"，我们没有那种模式，因此不产生。
    public static func modeReport(parameter: Int, isPrivate: Bool, state: ModeState) -> [UInt8] {
        let marker = isPrivate ? "?" : ""
        return Array("\u{1B}[\(marker)\(parameter);\(state.rawValue)$y".utf8)
    }

    public enum ModeState: Int, Sendable {
        case notRecognized = 0
        case set = 1
        case reset = 2
    }

    /// XTVERSION（`CSI > q`）：回 DCS 串 `DCS > | 文本 ST`。
    ///
    /// 文本里不写空格以外的控制字符；长度受限（DCS 串有上限），这里固定十几字节。
    public static func terminalVersion(name: String) -> [UInt8] {
        // ST 用 C1 的 8 位形式 `ESC \`（0x1B 0x5C），与 ctlseqs 一致。
        Array("\u{1B}P>|\(name)\u{1B}\\".utf8)
    }

    // MARK: - 鼠标归属（本机 / 转发给前台程序）

    /// 一次鼠标手势归谁处理。
    public enum MouseRoute: String, Sendable {
        /// 本机：选字 / 滚动 / 弹上下文菜单。
        case local
        /// 转发给前台程序（TUI 自己处理）。
        case program
    }

    /// 拖动 / 滚轮这类手势的归属：前台程序接管了鼠标就**转发**，按住 **⌥** 强制归本机。
    ///
    /// ⌥ 这条通行键是终端惯例（VS Code、PuTTY 同）—— TUI 一接管鼠标，本机就一个字都选不了，
    /// 必须留一个「还给我」的出口。
    public static func route(mouseReportingActive: Bool, optionHeld: Bool) -> MouseRoute {
        mouseReportingActive && !optionHeld ? .program : .local
    }

    /// **右键**的归属：与拖动 / 滚轮**反向** —— 默认归本机（弹上下文菜单），
    /// 只有「前台程序接管鼠标 **且** 按住 ⌥」才转发给它。
    ///
    /// 为什么反过来：右键是这套界面里唯一的**图形化**入口（复制 / 粘贴 / 全选 / 清回滚区 /
    /// 重开 shell）。实测反馈「能粘贴，但不知道复制按什么，而且没有右键菜单」，根因就是
    /// `dsh-tui` 这类 TUI 会开鼠标上报（`?1002` / `?1006`），而旧规则把右键一起转发走了 ——
    /// 菜单永远不会出现。TUI 里真正需要右键（button 2）的场合很少，需要时按 ⌥。
    public static func rightClickRoute(mouseReportingActive: Bool, optionHeld: Bool) -> MouseRoute {
        mouseReportingActive && optionHeld ? .program : .local
    }
}
