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
    public var inverse: Bool
    public var foreground: TerminalColor
    public var background: TerminalColor

    public init(
        content: Content = .empty,
        bold: Bool = false,
        isDim: Bool = false,
        underline: Bool = false,
        inverse: Bool = false,
        foreground: TerminalColor = .default,
        background: TerminalColor = .default
    ) {
        self.content = content
        self.bold = bold
        self.isDim = isDim
        self.underline = underline
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
/// - 私有模式：`?25`（光标显隐）、`?7`（自动换行）、`?47` / `?1049`（备用屏）、`?2004`（括号粘贴）
///
/// 明确不做的：鼠标上报、字符集切换（只当两字节吞掉）、双向文本、图片协议。
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
    private var savedMainFlags: (cursorVisible: Bool, autoWrap: Bool, bracketedPaste: Bool)?

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

    private func handleOSC(_ byte: UInt8) {
        // OSC 以 BEL 或 ST(ESC \) 结束；内容（窗口标题等）一律忽略。
        if byte == 0x07 {
            state = .ground
        } else if byte == 0x1B {
            state = .charset // 复用：吞掉紧随的 '\'
        }
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
            let row = (csiParameters.indices.contains(0) ? csiParameters[0] : 1) - 1
            let column = (csiParameters.indices.contains(1) ? csiParameters[1] : 1) - 1
            cursorRow = clampRow(row)
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
            break // 设备状态查询：不回话（我们不是真的终端设备，够用即可）
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
            default: break
            }
        }
    }

    /// 切到 / 切回备用屏。
    private func setAlternateScreen(_ enabled: Bool, savesCursor: Bool) {
        guard enabled != isAlternateScreen else { return }
        if enabled {
            savedMainScreen = screen
            if savesCursor {
                savedMainCursor = (cursorRow, cursorColumn)
                savedMainFlags = (isCursorVisible, isAutoWrapEnabled, isBracketedPasteEnabled)
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
                attributes.underline = true
            case 7:
                attributes.inverse = true
            case 22:
                // SGR 22 是"恢复正常强度"：粗体**与暗淡一起清**（标准如此）。
                attributes.bold = false
                attributes.isDim = false
            case 24:
                attributes.underline = false
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
