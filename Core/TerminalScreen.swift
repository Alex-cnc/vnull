import Foundation

// MARK: - 单元格与颜色

/// 终端颜色：默认 / 256 色索引 / 真彩。
public enum TerminalColor: Equatable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// 一个字符格。宽字符（中日韩）占两格，第二格是 `.continuation`。
public struct TerminalCell: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case empty
        case character(Character)
        /// 宽字符的右半格。
        case continuation
    }

    public var content: Content
    public var bold: Bool
    /// 暗淡（SGR 2）。渲染时把前景按比例混进底色 —— 见 `TerminalPalette.dimmed`。
    public var isDim: Bool
    public var underline: Bool
    /// 弯（波浪）下划线（SGR `4:3`）。渲染时用虚线下划线**近似** ——
    /// AppKit 的 `NSUnderlineStyle` 没有波浪样式，这一点在视图注释与文档里写明，不假装一样。
    public var isCurlyUnderline: Bool
    public var inverse: Bool
    public var foreground: TerminalColor
    public var background: TerminalColor

    public init(
        content: Content = .empty,
        bold: Bool = false,
        isDim: Bool = false,
        underline: Bool = false,
        isCurlyUnderline: Bool = false,
        inverse: Bool = false,
        foreground: TerminalColor = .default,
        background: TerminalColor = .default
    ) {
        self.content = content
        self.bold = bold
        self.isDim = isDim
        self.underline = underline
        self.isCurlyUnderline = isCurlyUnderline
        self.inverse = inverse
        self.foreground = foreground
        self.background = background
    }

    public static let blank = TerminalCell()

    public var character: Character? {
        if case .character(let value) = content { return value }
        return nil
    }

    /// 格子里可显示的字符（空白格给空格，宽字符右半格给空串）。
    public var displayText: String {
        switch content {
        case .empty: return " "
        case .character(let value): return String(value)
        case .continuation: return ""
        }
    }
}

// MARK: - 屏幕模型

/// 终端屏幕：把 PTY 吐出来的字节流解释成字符网格。
///
/// 放在 Core 而不是视图里，理由与 `DataTaskPresentation` 相同：这是**纯逻辑**，
/// 能脱离图形界面单测（`TerminalScreenTests` 覆盖光标 / 擦除 / 换行 / 颜色 / 宽字符）。
/// 视图只负责把网格画出来、把按键写成字节。
///
/// 实现的是一套**够用的 VT100/xterm 子集**，不追求全兼容：
/// - C0：BS / HT / LF / CR / BEL
/// - CSI：光标移动（A B C D E F G H f）、擦除（J K X）、插入删除（@ P L M）、
///   滚动（S T）、SGR（m）、屏幕对齐（r，滚动区域）
/// - OSC：忽略（窗口标题一类）
/// - 私有模式：`?25`（光标显隐）、`?7`（自动换行）、`?47` / `?1049`（备用屏）、`?2004`（括号粘贴）、
///   `?1`（DECCKM 应用光标键）、`?6`（DECOM 原址模式）、`?1000` / `?1002` / `?1003`（鼠标上报）、
///   `?1006`（SGR 鼠标编码）、`?1004`（焦点上报）
/// - 设备查询应答：DA1（`CSI c`）、DA2（`CSI > c`）、DSR 5 / 6（`CSI n`）、DECRQM（`CSI ? Ps $ p`）、
///   XTVERSION（`CSI > q`）—— 应答写进 `pendingResponses`，由调用方送回 PTY
///
/// 明确不做的：字符集切换（只当两字节吞掉）、双向文本、图片协议（sixel / kitty）、
/// 鼠标的双击 / 三击区分（只上报按下、松开、拖动、滚轮）。
public final class TerminalScreen {

    // MARK: 配置

    public private(set) var columns: Int
    public private(set) var rows: Int

    /// 回滚缓冲区上限（行）。满了就丢最旧的。
    public let scrollbackLimit: Int

    // MARK: 状态

    private var screen: [[TerminalCell]]
    private var scrollbackLines: [[TerminalCell]] = []

    public private(set) var cursorRow: Int = 0
    public private(set) var cursorColumn: Int = 0
    public private(set) var isCursorVisible: Bool = true
    public var isAutoWrapEnabled: Bool = true
    /// 括号粘贴（SGR 2004）：前台程序要求把粘贴内容包在 `ESC[200~ … ESC[201~` 里。
    /// 不跟踪它的话，粘一段代码进 vim 会被逐行自动缩进、粘多行 SQL 可能被逐行提交。
    public var isBracketedPasteEnabled: Bool = false

    /// DECCKM（`?1`）：应用光标键 —— 方向键走 SS3（`ESC O A`）而不是 CSI（`ESC [ A`）。
    /// vim / less 与部分 TUI 靠它区分键序；不跟踪的话方向键在这些程序里会"没反应"。
    public private(set) var isApplicationCursorKeysEnabled = false
    /// DECOM（`?6`）：原址模式 —— 光标定位与光标位置报告都相对**滚动区**。
    public private(set) var isOriginModeEnabled = false
    /// `?1004`：焦点变化时前台程序希望收到 `ESC [ I` / `ESC [ O`。
    public private(set) var isFocusReportingEnabled = false
    /// 鼠标追踪模式（`?1000` / `?1002` / `?1003`）。
    public private(set) var mouseTrackingMode: TerminalInput.MouseTrackingMode = .none
    /// `?1006`：鼠标上报用 SGR 编码（坐标不受 223 限制，且分得清哪个键松开）。
    public private(set) var isSGRMouseEnabled = false

    /// 前台程序用 DECSCUSR（`CSI Ps SP q`）要求的光标外观；`nil` = 没要求（用用户偏好）。
    public private(set) var requestedCursor: TerminalCursorAppearance?

    /// 回答 `OSC 10/11/12`（前景 / 背景 / 光标色查询）时要报的颜色。
    ///
    /// 由**视图**注入（Core 不该猜现在是深色还是浅色 —— 那是外观偏好的事）。
    /// 为 `nil` 时**不回答**：与其瞎报一个颜色，不如让程序退回自己的默认
    /// （假装知道会让它按错误的底色选前景色，反而更难看）。
    public var paletteProvider: (() -> TerminalPalette)?

    /// 前台程序是否接管了鼠标（视图据此决定"上报"还是"本地选中"）。
    public var isMouseReportingActive: Bool { mouseTrackingMode != .none }

    /// 需要回给 PTY 的字节（设备查询应答）。
    ///
    /// 为什么不直接在这里写 PTY：屏幕模型是**纯逻辑**（Core 里没有文件描述符，也不该有）；
    /// 由调用方在 `feed` 之后 `drainResponses()` 送回，测试与命令行都能一眼看到发生了什么。
    private var pendingResponses: [UInt8] = []

    /// 取走待回字节（幂等：取过就空）。
    public func drainResponses() -> [UInt8] {
        defer { pendingResponses.removeAll() }
        return pendingResponses
    }

    /// 供命令行 / 测试查看当前有哪些待回应答，而不清空它。
    public var pendingResponseBytes: [UInt8] { pendingResponses }

    /// 当前 SGR 属性（新写入的字符用它）。
    private var attributes = TerminalCell()

    /// 滚动区域（DECSTBM），默认整屏。
    private var scrollTop = 0
    private var scrollBottom: Int

    private var savedCursor: (row: Int, column: Int)?

    /// 备用屏（`?1049h/l`、`?47h/l`）保存下来的主屏与光标。
    ///
    /// 为什么必须有它：全屏 TUI（`dsh-tui` / vim / less）都靠备用屏把界面"盖"在主屏上，
    /// 退出时再放回去。我们原先不支持，于是它们的每一帧都直接画在主屏上、
    /// **旧帧永不清除**，而且滚屏时会把 TUI 自己的界面推进回滚区 ——
    /// 视觉上就是"新旧内容叠在一起"。
    private var savedMainScreen: [[TerminalCell]]?
    private var savedMainCursor: (row: Int, column: Int)?
    /// 备用屏保存的主屏模式位。
    ///
    /// 为什么连 DECCKM / DECOM / 鼠标模式一起存：TUI（vim / less）切进备用屏时会**改**这些位，
    /// 退出时只恢复"上一次前台程序留下的状态"才是对的 —— 少存一个，退出 TUI 后方向键
    /// 就会停在应用模式上（外面那个 shell 收到 SS3 序列，按上箭头变成乱码）。
    private struct SavedModes {
        var cursorVisible: Bool
        var autoWrap: Bool
        var bracketedPaste: Bool
        var applicationCursorKeys: Bool
        var originMode: Bool
        var focusReporting: Bool
        var mouseTracking: TerminalInput.MouseTrackingMode
        var sgrMouse: Bool
    }

    private var savedMainFlags: SavedModes?

    /// 当前是否在备用屏上。
    public private(set) var isAlternateScreen = false

    /// 「延迟换行」标记：光标停在最后一列且已写过内容，等下一个字符才真正换行。
    private var pendingWrap = false

    // MARK: 解析状态

    private enum ParserState {
        case ground
        case escape
        case csi
        case osc
        case charset
    }

    private var state: ParserState = .ground
    private var csiParameters: [Int] = []
    /// 与 `csiParameters` 平行：该参数是用 `:` 引入的**子参数**吗？
    ///
    /// 需要它是因为 `38:5:n` 与 `38;5;n` 都合法（前者是 ISO-8613-6 的写法，
    /// 后者是 xterm 为兼容 konsole 额外接受的）。只留一个 `[Int]` 就分不出
    /// "`38:2::255:0:0`（带一个空的颜色空间标识）"与"`38;2;255;0;0`"，
    /// 前者会多出一个参数，按后者解析就会把颜色读错位。
    private var csiSubParameterFlags: [Bool] = []
    private var csiCurrent: String = ""
    private var csiPrivateMarker: Character?
    private var csiIntermediate: Character?

    /// 跨 chunk 的 UTF-8 半截字节。
    private var pendingUTF8: [UInt8] = []

    /// 当前 OSC 的内容（用于回答颜色查询）。
    private var oscPayload: [UInt8] = []

    public init(columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = 2_000) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.scrollbackLimit = max(0, scrollbackLimit)
        self.scrollBottom = self.rows - 1
        self.screen = Array(
            repeating: Array(repeating: .blank, count: self.columns),
            count: self.rows
        )
    }

    // MARK: 读取

    /// 可见屏幕的浅拷贝（视图渲染用）。
    public func visibleLines() -> [[TerminalCell]] {
        screen
    }

    /// 回滚区最多能往上翻多少行（备用屏上不提供回滚，与真实终端一致）。
    public var maxScrollOffset: Int {
        isAlternateScreen ? 0 : scrollbackLines.count
    }

    /// 按显示偏移取 `height` 行：`offset = 0` 是实时画面，`offset > 0` 往上翻。
    ///
    /// 回滚区与屏幕在这里拼成一个**虚拟缓冲**，视图不需要知道两者的边界 ——
    /// 它只拿到"要画的这几行"。不足 `height` 行时前面补空行，避免视图里出现
    /// 半屏跳动。
    public func visibleLines(offset: Int, height: Int) -> [[TerminalCell]] {
        let height = max(1, height)
        let clamped = min(max(0, offset), maxScrollOffset)
        var buffer = scrollbackLines
        buffer.append(contentsOf: screen)

        let bottom = max(0, buffer.count - clamped)
        let top = max(0, bottom - height)
        var window = Array(buffer[top..<bottom])
        if window.count < height {
            window.insert(
                contentsOf: Array(repeating: blankRow(), count: height - window.count),
                at: 0
            )
        }
        return window
    }

    public func line(_ index: Int) -> [TerminalCell] {
        guard screen.indices.contains(index) else { return [] }
        return screen[index]
    }

    public var scrollbackCount: Int { scrollbackLines.count }

    public func scrollbackLine(_ index: Int) -> [TerminalCell] {
        guard scrollbackLines.indices.contains(index) else { return [] }
        return scrollbackLines[index]
    }

    /// 屏幕文本（单测与复制用）：去掉行尾空白。
    public func text() -> String {
        screen.map { row in
            String(row.map(\.displayText).joined())
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    // MARK: 尺寸

    public func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(1, newColumns)
        let newRows = max(1, newRows)
        guard newColumns != columns || newRows != rows else { return }

        for index in screen.indices {
            if newColumns > screen[index].count {
                screen[index].append(contentsOf: Array(repeating: .blank, count: newColumns - screen[index].count))
            } else if newColumns < screen[index].count {
                screen[index].removeLast(screen[index].count - newColumns)
            }
            _ = index
        }

        if newRows > rows {
            screen.append(contentsOf: Array(
                repeating: Array(repeating: .blank, count: newColumns),
                count: newRows - rows
            ))
        } else if newRows < rows {
            // 变矮：把顶部多余的行推入回滚，保留光标附近的内容。
            let overflow = rows - newRows
            let trimmed = screen.prefix(overflow)
            appendScrollback(Array(trimmed))
            screen.removeFirst(overflow)
            cursorRow = max(0, cursorRow - overflow)
        }

        columns = newColumns
        rows = newRows
        scrollTop = 0
        scrollBottom = newRows - 1
        cursorRow = min(cursorRow, rows - 1)
        cursorColumn = min(cursorColumn, columns - 1)
    }

    // MARK: 馈入字节

    public func feed(_ bytes: [UInt8]) {
        for byte in bytes { feed(byte: byte) }
    }

    public func feed(text: String) {
        feed(Array(text.utf8))
    }

    private func feed(byte: UInt8) {
        switch state {
        case .ground:
            handleGround(byte)
        case .escape:
            handleEscape(byte)
        case .csi:
            handleCSI(byte)
        case .osc:
            handleOSC(byte)
        case .charset:
            // ESC ( / ) / * / + 后面跟一个字符集标识，吞掉。
            state = .ground
        }
    }

    // MARK: ground

    private func handleGround(_ byte: UInt8) {
        switch byte {
        case 0x1B: // ESC
            state = .escape
        case 0x0D: // CR
            pendingWrap = false
            cursorColumn = 0
        case 0x0A, 0x0B, 0x0C: // LF / VT / FF
            pendingWrap = false
            lineFeed()
        case 0x08: // BS
            pendingWrap = false
            cursorColumn = max(0, cursorColumn - 1)
        case 0x09: // HT
            pendingWrap = false
            cursorColumn = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
        case 0x07: // BEL
            break
        case 0x00...0x1F:
            break // 其余控制字符忽略
        default:
            decodeUTF8(byte)
        }
    }

    private func decodeUTF8(_ byte: UInt8) {
        pendingUTF8.append(byte)
        guard let text = String(bytes: pendingUTF8, encoding: .utf8) else {
            // 还不是合法序列：继续等（最多 4 字节）
            if pendingUTF8.count >= 4 {
                pendingUTF8.removeAll()
                put(Character("?"))
            }
            return
        }
        pendingUTF8.removeAll()
        for character in text { put(character) }
    }

    private func put(_ character: Character) {
        // 「延迟换行」：写满最后一列后先不换行，等下一个字符才换。
        // 立即换行会让每个整行输出的末尾多出一个空行（真实终端都这么做）。
        if pendingWrap {
            pendingWrap = false
            cursorColumn = 0
            lineFeed()
        }

        let width = Self.cellWidth(character)
        if width == 2, cursorColumn == columns - 1 {
            // 宽字符放不下行尾：先换行
            cursorColumn = 0
            lineFeed()
        }

        screen[cursorRow][cursorColumn] = cell(for: character)
        if width == 2, cursorColumn + 1 < columns {
            screen[cursorRow][cursorColumn + 1] = cell(for: nil)
        }

        let next = cursorColumn + width
        if next >= columns {
            cursorColumn = columns - 1
            pendingWrap = isAutoWrapEnabled
        } else {
            cursorColumn = next
        }
    }

    private func cell(for character: Character?) -> TerminalCell {
        var cell = attributes
        cell.content = character.map { TerminalCell.Content.character($0) } ?? .continuation
        return cell
    }

    private func lineFeed() {
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else {
            cursorRow = min(rows - 1, cursorRow + 1)
        }
    }

    /// 在滚动区域内上滚，腾出的行压入回滚缓冲。
    ///
    /// **备用屏上不压回滚**：TUI 每帧都在滚屏，压进去会把回滚区灌满它自己的界面，
    /// 而真实终端在备用屏上根本不提供回滚。
    private func scrollUp(_ count: Int) {
        for _ in 0..<max(1, count) {
            let removed = screen.remove(at: scrollTop)
            if scrollTop == 0, !isAlternateScreen { appendScrollback([removed]) }
            screen.insert(Array(repeating: .blank, count: columns), at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        for _ in 0..<max(1, count) {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: .blank, count: columns), at: scrollTop)
        }
    }

    private func appendScrollback(_ lines: [[TerminalCell]]) {
        guard scrollbackLimit > 0 else { return }
        scrollbackLines.append(contentsOf: lines)
        if scrollbackLines.count > scrollbackLimit {
            scrollbackLines.removeFirst(scrollbackLines.count - scrollbackLimit)
        }
    }

    // MARK: escape / csi / osc

    private func handleEscape(_ byte: UInt8) {
        switch Character(UnicodeScalar(byte)) {
        case "[":
            state = .csi
            csiParameters = []
            csiSubParameterFlags = []
            csiCurrent = ""
            csiPrivateMarker = nil
            csiIntermediate = nil
        case "]":
            state = .osc
        case "(", ")", "*", "+":
            state = .charset
        case "7": // DECSC 保存光标
            savedCursor = (cursorRow, cursorColumn)
            state = .ground
        case "8": // DECRC 恢复光标
            if let saved = savedCursor {
                cursorRow = min(saved.row, rows - 1)
                cursorColumn = min(saved.column, columns - 1)
            }
            state = .ground
        case "D": // IND
            lineFeed()
            state = .ground
        case "M": // RI
            if cursorRow == scrollTop { scrollDown(1) } else { cursorRow = max(0, cursorRow - 1) }
            state = .ground
        case "E": // NEL
            cursorColumn = 0
            lineFeed()
            state = .ground
        case "c": // RIS 复位
            reset()
            state = .ground
        default:
            state = .ground
        }
    }

    /// OSC：以 BEL 或 ST(`ESC \\`) 结束。
    ///
    /// 以前这里"内容一律忽略"，于是 `OSC 10;?`（问前景色）也一并吞掉了 —— 而程序问不到颜色时，
    /// 常用的退路是**猜**（有的 TUI 就按黑底白字硬编码），在浅色主题下会很难看。
    /// 现在只处理三件事，其余（窗口标题 / 剪贴板 / 超链接…）仍然忽略：
    /// `OSC 10;?` 前景、`OSC 11;?` 背景、`OSC 12;?` 光标色。
    private func handleOSC(_ byte: UInt8) {
        if byte == 0x07 {
            answerOSCQuery()
            oscPayload.removeAll(keepingCapacity: true)
            state = .ground
        } else if byte == 0x1B {
            // ST（`ESC \\`）：**在这里就回答**，不能等"下一个字节" —— 紧随的反斜杠由
            // `.charset` 状态吞掉，那条路上没有"OSC 收尾"这个回调（第一版就是这样漏答的）。
            oscPayload.append(byte)
            answerOSCQuery()
            oscPayload.removeAll(keepingCapacity: true)
            state = .charset // 复用：吞掉紧随的 '\\'
        } else {
            // 上限保护：OSC 内容可能很长（超链接），但查询只有十来字节 ——
            // 超出上限就不再累积，避免畸形输入把内存拖大。
            if oscPayload.count < 512 { oscPayload.append(byte) }
        }
    }

    /// 把收集到的 OSC 内容与查询对上号，答一次。
    private func answerOSCQuery() {
        guard !oscPayload.isEmpty, let palette = paletteProvider?() else { return }
        // 去掉可能的 ST 尾巴：`ESC` 被记进来，而紧随的 `\` 已被 charset 状态吞掉 ——
        // 所以这里最多只看到一个 0x1B；两种形态都容错（测试里 ST 与 BEL 各验一次）。
        var payload = oscPayload
        while let last = payload.last, last == 0x1B || last == 0x5C {
            payload.removeLast()
        }
        guard let text = String(bytes: payload, encoding: .utf8) else { return }
        let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[1].trimmingCharacters(in: .whitespaces) == "?" else { return }

        let rgb: TerminalPalette.RGB
        switch parts[0] {
        case "10": rgb = palette.foreground
        case "11": rgb = palette.background
        case "12": rgb = palette.cursor
        default: return
        }
        // xterm 的回法：`OSC <N>;rgb:RRRR/GGGG/BBBB ST`（每个分量 4 位十六进制）。
        let reply = "\u{1B}]" + parts[0] + ";rgb:" + Self.sixteenBit(rgb) + "\u{1B}\\"
        respond(Array(reply.utf8))
    }

    /// 8 位分量 → xterm 的四位十六进制（`AB` → `ABAB`，保持比例）。
    static func sixteenBit(_ rgb: TerminalPalette.RGB) -> String {
        func component(_ value: UInt8) -> String {
            let wide = Int(value) * 257   // 0xAB * 0x0101 = 0xABAB
            return String(format: "%04X", wide)
        }
        return component(rgb.red) + "/" + component(rgb.green) + "/" + component(rgb.blue)
    }

    private func handleCSI(_ byte: UInt8) {
        let scalar = UnicodeScalar(byte)
        let character = Character(scalar)

        if character.isNumber {
            csiCurrent.append(character)
            return
        }
        if character == ";" || character == ":" {
            csiParameters.append(Int(csiCurrent) ?? 0)
            csiSubParameterFlags.append(character == ":")
            csiCurrent = ""
            return
        }
        if character == "?" || character == ">" || character == "!" {
            csiPrivateMarker = character
            return
        }
        if character == " " || character == "$" || character == "\"" || character == "'" {
            csiIntermediate = character
            return
        }

        if !csiCurrent.isEmpty {
            csiParameters.append(Int(csiCurrent) ?? 0)
            csiSubParameterFlags.append(false)
        }
        csiCurrent = ""

        pendingWrap = false
        executeCSI(final: character)
        state = .ground
    }

    private func executeCSI(final: Character) {
        // 缺省参数按 1（光标类）或 0（擦除类）处理，调用处各自兜底。
        let first = csiParameters.first

        switch final {
        case "A": cursorRow = max(scrollTop, cursorRow - max(1, first ?? 1))
        case "B": cursorRow = min(scrollBottom, cursorRow + max(1, first ?? 1))
        case "C": cursorColumn = min(columns - 1, cursorColumn + max(1, first ?? 1))
        case "D": cursorColumn = max(0, cursorColumn - max(1, first ?? 1))
        case "E":
            cursorRow = min(scrollBottom, cursorRow + max(1, first ?? 1))
            cursorColumn = 0
        case "F":
            cursorRow = max(scrollTop, cursorRow - max(1, first ?? 1))
            cursorColumn = 0
        case "G":
            cursorColumn = clampColumn((first ?? 1) - 1)
        case "d":
            cursorRow = clampRow((first ?? 1) - 1)
        case "H", "f":
            var row = (csiParameters.indices.contains(0) ? csiParameters[0] : 1) - 1
            let column = (csiParameters.indices.contains(1) ? csiParameters[1] : 1) - 1
            if isOriginModeEnabled {
                // 原址模式（DECOM）：行号相对滚动区顶部，且不允许走出滚动区。
                row += scrollTop
                cursorRow = min(max(row, scrollTop), scrollBottom)
            } else {
                cursorRow = clampRow(row)
            }
            cursorColumn = clampColumn(column)
        case "J": eraseInDisplay(mode: first ?? 0)
        case "K": eraseInLine(mode: first ?? 0)
        case "X":
            let count = max(1, first ?? 1)
            for offset in 0..<count where cursorColumn + offset < columns {
                screen[cursorRow][cursorColumn + offset] = .blank
            }
        case "L": insertLines(max(1, first ?? 1))
        case "M": deleteLines(max(1, first ?? 1))
        case "@": insertCharacters(max(1, first ?? 1))
        case "P": deleteCharacters(max(1, first ?? 1))
        case "S": scrollUp(max(1, first ?? 1))
        case "T": scrollDown(max(1, first ?? 1))
        case "r":
            let top = (first ?? 1) - 1
            let bottom = (csiParameters.indices.contains(1) ? csiParameters[1] : rows) - 1
            if top >= 0, bottom < rows, top < bottom {
                scrollTop = top
                scrollBottom = bottom
                cursorRow = scrollTop
                cursorColumn = 0
            }
        case "m": applySGR()
        case "h": if csiPrivateMarker == "?" { setPrivateMode(enabled: true) }
        case "l": if csiPrivateMarker == "?" { setPrivateMode(enabled: false) }
        case "n":
            // DSR：`5` = 设备状态（回"一切正常"），`6` = 光标位置报告。
            // 不回答 6 的后果很具体：vim / tmux 一类程序会一直等这行回复，
            // 表现为「界面卡住不动」—— 看起来像我们的卡顿，其实是对方在等。
            switch first ?? 0 {
            case 5: respond(TerminalInput.statusReportOK())
            case 6:
                let row = isOriginModeEnabled ? cursorRow - scrollTop + 1 : cursorRow + 1
                respond(TerminalInput.cursorPositionReport(row: row, column: cursorColumn + 1))
            default: break
            }
        case "c":
            // DA1（`CSI c`）/ DA2（`CSI > c`）：声明基础能力，不夸大。
            if csiPrivateMarker == ">" {
                respond(TerminalInput.secondaryDeviceAttributes())
            } else {
                respond(TerminalInput.primaryDeviceAttributes())
            }
        case "p" where csiIntermediate == "$":
            // DECRQM：告诉对方我们认不认这个模式、现在是置位还是复位。
            guard let parameter = first else { break }
            respond(
                TerminalInput.modeReport(
                    parameter: parameter,
                    isPrivate: csiPrivateMarker == "?",
                    state: modeState(for: parameter, isPrivate: csiPrivateMarker == "?")
                )
            )
        case "q" where csiPrivateMarker == ">":
            // XTVERSION：回 DCS 串。程序据此区分终端实现（我们不冒充 xterm）。
            respond(TerminalInput.terminalVersion(name: DoyahIdentity.terminalVersionName))
        case "q" where csiIntermediate == " ":
            // DECSCUSR（`CSI Ps SP q`）：前台程序要求光标形状（vim 插入模式要竖线）。
            // 参数认不出时**保持原状**，不猜。
            if let appearance = TerminalCursorAppearance.fromDECSCUSR(first ?? 0) {
                requestedCursor = appearance
            }
        default:
            break
        }
    }

    private func setPrivateMode(enabled: Bool) {
        for parameter in csiParameters {
            switch parameter {
            case 25: isCursorVisible = enabled
            case 7: isAutoWrapEnabled = enabled
            // 47 与 1049 都切备用屏；1049 额外保存/恢复光标与模式（xterm 的约定）。
            case 47: setAlternateScreen(enabled, savesCursor: false)
            case 1049: setAlternateScreen(enabled, savesCursor: true)
            case 2004: isBracketedPasteEnabled = enabled
            case 1: isApplicationCursorKeysEnabled = enabled
            case 6: isOriginModeEnabled = enabled
            case 1004: isFocusReportingEnabled = enabled
            // 三个鼠标模式互斥：置位谁就切到谁；复位只在自己是当前模式时清掉
            // （`?1003l` 不该把 `?1002` 一起关掉 —— 顺序不同结果不同的那种 bug 最难查）。
            case 1000: applyMouseTracking(enabled: enabled, mode: .click)
            case 1002: applyMouseTracking(enabled: enabled, mode: .buttonEvent)
            case 1003: applyMouseTracking(enabled: enabled, mode: .anyEvent)
            case 1006: isSGRMouseEnabled = enabled
            default: break
            }
        }
    }

    private func applyMouseTracking(enabled: Bool, mode: TerminalInput.MouseTrackingMode) {
        if enabled {
            mouseTrackingMode = mode
        } else if mouseTrackingMode == mode {
            mouseTrackingMode = .none
        }
    }

    /// DECRQM 用的模式状态：只报我们**真的跟踪**的模式，其余一律 `0`（不认识）——
    /// 谎报"已置位"会让程序以为某项能力开着。
    private func modeState(for parameter: Int, isPrivate: Bool) -> TerminalInput.ModeState {
        guard isPrivate else { return .notRecognized }
        switch parameter {
        case 1: return isApplicationCursorKeysEnabled ? .set : .reset
        case 6: return isOriginModeEnabled ? .set : .reset
        case 7: return isAutoWrapEnabled ? .set : .reset
        case 25: return isCursorVisible ? .set : .reset
        case 1000: return mouseTrackingMode == .click ? .set : .reset
        case 1002: return mouseTrackingMode == .buttonEvent ? .set : .reset
        case 1003: return mouseTrackingMode == .anyEvent ? .set : .reset
        case 1004: return isFocusReportingEnabled ? .set : .reset
        case 1006: return isSGRMouseEnabled ? .set : .reset
        case 2004: return isBracketedPasteEnabled ? .set : .reset
        case 47, 1049: return isAlternateScreen ? .set : .reset
        default: return .notRecognized
        }
    }

    private func respond(_ bytes: [UInt8]) {
        pendingResponses.append(contentsOf: bytes)
    }

    /// 切到 / 切回备用屏。
    private func setAlternateScreen(_ enabled: Bool, savesCursor: Bool) {
        guard enabled != isAlternateScreen else { return }
        if enabled {
            savedMainScreen = screen
            if savesCursor {
                savedMainCursor = (cursorRow, cursorColumn)
                savedMainFlags = SavedModes(
                    cursorVisible: isCursorVisible,
                    autoWrap: isAutoWrapEnabled,
                    bracketedPaste: isBracketedPasteEnabled,
                    applicationCursorKeys: isApplicationCursorKeysEnabled,
                    originMode: isOriginModeEnabled,
                    focusReporting: isFocusReportingEnabled,
                    mouseTracking: mouseTrackingMode,
                    sgrMouse: isSGRMouseEnabled
                )
            }
            screen = Array(repeating: blankRow(), count: rows)
            cursorRow = 0
            cursorColumn = 0
            pendingWrap = false
            scrollTop = 0
            scrollBottom = rows - 1
            isAlternateScreen = true
        } else {
            // 主屏内容可能与备用屏尺寸不同（窗口在 TUI 里被拉过），按当前尺寸补齐。
            if let saved = savedMainScreen { screen = normalize(saved) }
            if let cursor = savedMainCursor {
                cursorRow = clampRow(cursor.row)
                cursorColumn = clampColumn(cursor.column)
            }
            if let flags = savedMainFlags {
                isCursorVisible = flags.cursorVisible
                isAutoWrapEnabled = flags.autoWrap
                isBracketedPasteEnabled = flags.bracketedPaste
                isApplicationCursorKeysEnabled = flags.applicationCursorKeys
                isOriginModeEnabled = flags.originMode
                isFocusReportingEnabled = flags.focusReporting
                mouseTrackingMode = flags.mouseTracking
                isSGRMouseEnabled = flags.sgrMouse
            }
            savedMainScreen = nil
            savedMainCursor = nil
            savedMainFlags = nil
            isAlternateScreen = false
            scrollTop = 0
            scrollBottom = rows - 1
            pendingWrap = false
        }
    }

    /// 把一份行数组调整为当前列 / 行数（多裁少补）。
    private func normalize(_ lines: [[TerminalCell]]) -> [[TerminalCell]] {
        var result = lines.prefix(rows).map { row -> [TerminalCell] in
            var row = row
            if row.count < columns {
                row.append(contentsOf: Array(repeating: .blank, count: columns - row.count))
            } else if row.count > columns {
                row.removeLast(row.count - columns)
            }
            return row
        }
        while result.count < rows { result.append(blankRow()) }
        return result
    }

    private func eraseInDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseInLine(mode: 0)
            for row in (cursorRow + 1)..<rows { screen[row] = blankRow() }
        case 1:
            eraseInLine(mode: 1)
            for row in 0..<cursorRow { screen[row] = blankRow() }
        case 2, 3:
            for row in 0..<rows { screen[row] = blankRow() }
        default:
            break
        }
    }

    private func eraseInLine(mode: Int) {
        switch mode {
        case 0:
            for column in cursorColumn..<columns { screen[cursorRow][column] = .blank }
        case 1:
            for column in 0...min(cursorColumn, columns - 1) { screen[cursorRow][column] = .blank }
        case 2:
            screen[cursorRow] = blankRow()
        default:
            break
        }
    }

    private func blankRow() -> [TerminalCell] {
        Array(repeating: .blank, count: columns)
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(blankRow(), at: cursorRow)
        }
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0..<count {
            screen.remove(at: cursorRow)
            screen.insert(blankRow(), at: scrollBottom)
        }
    }

    private func insertCharacters(_ count: Int) {
        guard cursorColumn < columns else { return }
        let blanks = Array(repeating: TerminalCell.blank, count: count)
        screen[cursorRow].insert(contentsOf: blanks, at: cursorColumn)
        screen[cursorRow].removeLast(count)
    }

    private func deleteCharacters(_ count: Int) {
        guard cursorColumn < columns else { return }
        let removable = min(count, columns - cursorColumn)
        screen[cursorRow].removeSubrange(cursorColumn..<(cursorColumn + removable))
        screen[cursorRow].append(contentsOf: Array(repeating: .blank, count: removable))
    }

    private func clampRow(_ row: Int) -> Int { min(max(0, row), rows - 1) }
    private func clampColumn(_ column: Int) -> Int { min(max(0, column), columns - 1) }

    /// 复位屏幕（RIS，或用户点「重新开始」时用）。
    /// 清空回滚区（FR-EDIT-29 的右键菜单项）。
    ///
    /// 与 `reset()` 区别：只丢历史行，**不动当前屏幕、光标与模式位** ——
    /// 用户想要的通常是"把上面那些翻不到头的历史清掉"，而不是把正在跑的 TUI 也重置。
    public func clearScrollback() {
        scrollbackLines.removeAll()
    }

    public func reset() {
        screen = Array(repeating: blankRow(), count: rows)
        scrollbackLines.removeAll()
        cursorRow = 0
        cursorColumn = 0
        attributes = .blank
        scrollTop = 0
        scrollBottom = rows - 1
        isCursorVisible = true
        isAutoWrapEnabled = true
        isBracketedPasteEnabled = false
        // RIS（`ESC c`）是"全复位"：模式位一律回默认 —— 漏掉哪个，下一个前台程序
        // 就会继承上一个留下的状态（例如方向键停在应用模式、鼠标还被接管着）。
        isApplicationCursorKeysEnabled = false
        isOriginModeEnabled = false
        isFocusReportingEnabled = false
        mouseTrackingMode = .none
        isSGRMouseEnabled = false
        requestedCursor = nil
        oscPayload.removeAll()
        pendingResponses.removeAll()
        savedCursor = nil
        savedMainScreen = nil
        savedMainCursor = nil
        savedMainFlags = nil
        isAlternateScreen = false
        pendingWrap = false
    }

    // MARK: SGR

    /// 解析 `38` / `48` 之后的扩展颜色（两种写法都要认）。
    ///
    /// - 冒号写法（ISO-8613-6，ECMA-48 5th 里标注为"保留待标准化"，xterm 已支持）：
    ///   `38:5:196`（索引色）、`38:2:Pi:Pr:Pg:Pb`（真彩色，`Pi` 是颜色空间标识，
    ///   实践中常常**留空** → 解析成 0）；`38:2:Pr:Pg:Pb` 这种省略 `Pi` 的也认。
    /// - 分号写法（xterm 为兼容 KDE konsole 额外接受）：`38;5;196`、`38;2;Pr;Pg;Pb`。
    ///
    /// 返回"颜色 + 消耗了几个参数"，让调用方推进下标。
    private func extendedColor(
        after index: Int,
        codes: [Int]
    ) -> (color: TerminalColor, consumed: Int)? {
        // 先把紧随其后的**冒号子参数**全部收进来（空字段在收集时已变成 0）。
        //
        // 注意标记的含义：`csiSubParameterFlags[i]` 记的是**参数 i 之后**那个分隔符是不是冒号，
        // 所以"参数 i 是子参数"等价于"分隔符 i-1 是冒号" —— 一开始按"自己的标记"判断，
        // 结果是最后一个子参数（它的后面是 `m`）永远收不进来，颜色静默丢失。
        var subParameters: [Int] = []
        var cursor = index + 1
        while cursor < codes.count,
              cursor - 1 >= 0,
              cursor - 1 < csiSubParameterFlags.count,
              csiSubParameterFlags[cursor - 1] {
            subParameters.append(codes[cursor])
            cursor += 1
        }

        if !subParameters.isEmpty {
            switch subParameters[0] {
            case 5 where subParameters.count >= 2:
                return (.indexed(UInt8(clamping: subParameters[1])), subParameters.count)
            case 2 where subParameters.count >= 5:
                // 带颜色空间标识：`2 : Pi : R : G : B` → 跳过 Pi
                return (
                    .rgb(
                        UInt8(clamping: subParameters[2]),
                        UInt8(clamping: subParameters[3]),
                        UInt8(clamping: subParameters[4])
                    ),
                    subParameters.count
                )
            case 2 where subParameters.count >= 4:
                return (
                    .rgb(
                        UInt8(clamping: subParameters[1]),
                        UInt8(clamping: subParameters[2]),
                        UInt8(clamping: subParameters[3])
                    ),
                    subParameters.count
                )
            default:
                return nil
            }
        }

        // 分号写法：只吃刚好够的那几个参数。
        guard index + 1 < codes.count else { return nil }
        let selector = codes[index + 1]
        if selector == 5, index + 2 < codes.count {
            return (.indexed(UInt8(clamping: codes[index + 2])), 2)
        }
        if selector == 2, index + 4 < codes.count {
            return (
                .rgb(
                    UInt8(clamping: codes[index + 2]),
                    UInt8(clamping: codes[index + 3]),
                    UInt8(clamping: codes[index + 4])
                ),
                4
            )
        }
        return nil
    }

    private func applySGR() {
        let codes = csiParameters.isEmpty ? [0] : csiParameters
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0:
                attributes = .blank
            case 1:
                attributes.bold = true
            case 2:
                // 暗淡（SGR 2）。**与粗体可以并存**：xterm 里 `1;2` 是"粗而暗"，
                // 我们按"先提亮再压暗"渲染，不把两者当成互斥开关。
                attributes.isDim = true
            case 4:
                // `4` 是下划线；`4:N` 是它的**子样式**（ECMA-48 4th、xterm 支持）：0 无 / 1 单 /
                // 2 双 / 3 弯（波浪）/ 4 点线 / 5 虚线。
                //
                // 子参数用 `:` 引入。注意 `csiSubParameterFlags[i]` 记的是**参数 i 之后**那个分隔符
                // 是不是冒号（见 `extendedColor` 的注释）—— 所以"下一个参数是子参数"要看
                // `flags[index]` 而不是 `flags[index + 1]`（第一版就写错了，测试当场抓到）。
                let hasSubStyle = index + 1 < codes.count
                    && csiSubParameterFlags.indices.contains(index)
                    && csiSubParameterFlags[index]
                if hasSubStyle {
                    switch codes[index + 1] {
                    case 0:
                        attributes.underline = false
                        attributes.isCurlyUnderline = false
                    case 3, 4, 5:
                        // 弯 / 点线 / 虚线：渲染上都用**点划线**近似（AppKit 没有波浪下划线），
                        // 但语义上仍分开记住 —— 将来换渲染后端不必重解析。
                        attributes.underline = true
                        attributes.isCurlyUnderline = true
                    default:
                        // 1 单线、2 双线（双线同样用单线近似）：都是"有下划线、不是弯的"。
                        attributes.underline = true
                        attributes.isCurlyUnderline = false
                    }
                    index += 1        // 吃掉子参数
                } else {
                    attributes.underline = true
                    attributes.isCurlyUnderline = false
                }
            case 7:
                attributes.inverse = true
            case 22:
                // SGR 22 是"恢复正常强度"：粗体**与暗淡一起清**（标准如此）。
                attributes.bold = false
                attributes.isDim = false
            case 24:
                attributes.underline = false
                attributes.isCurlyUnderline = false
            case 27:
                attributes.inverse = false
            case 30...37:
                attributes.foreground = .indexed(UInt8(code - 30))
            case 39:
                attributes.foreground = .default
            case 40...47:
                attributes.background = .indexed(UInt8(code - 40))
            case 49:
                attributes.background = .default
            case 90...97:
                attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107:
                attributes.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                let isForeground = code == 38
                if let color = extendedColor(after: index, codes: codes) {
                    if isForeground { attributes.foreground = color.color }
                    else { attributes.background = color.color }
                    index += color.consumed
                }
            default:
                break
            }
            index += 1
        }
    }

    // MARK: 宽度

    /// 粗略的东亚宽字符判定：够用即可（不引 Unicode 宽度表）。
    static func cellWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF,
             0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

/// 给命令行探针用的只读转发（`terminal-modes` 要展示 OSC 应答里的十六进制格式）。
///
/// 为什么不把 `TerminalScreen.sixteenBit` 直接改成 public：那是**实现细节**，
/// 只有探针需要它；转一层比把内部函数摊到公开 API 上更干净。
public enum ScreenProbe {
    public static func sixteenBit(_ rgb: TerminalPalette.RGB) -> String {
        TerminalScreen.sixteenBit(rgb)
    }
}
