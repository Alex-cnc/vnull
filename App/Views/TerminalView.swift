import AppKit
import SwiftUI
import DoyahCore

// MARK: - 模型

/// 终端面板的状态：屏幕模型 + PTY 会话。
///
/// 视图（`TerminalHostView`）只负责画网格与把按键变成字节，所有状态在这里，
/// 这样界面重建（例如语言切换导致整树重建）不会把 shell 弄丢——会话挂在 `@StateObject` 上。
@MainActor
final class TerminalModel: ObservableObject {
    let screen: TerminalScreen
    private let session = TerminalSession()

    @Published private(set) var isRunning = false
    @Published private(set) var errorText: String?

    /// 屏幕内容变了要让视图重画；由视图注册。
    private var requestRedraw: (() -> Void)?
    private var didStart = false

    init(columns: Int = 80, rows: Int = 24) {
        screen = TerminalScreen(columns: columns, rows: rows)
    }

    func attach(redraw: @escaping () -> Void) {
        requestRedraw = redraw
    }

    /// PTY 是否已经起过（视图用它决定"首次布局时用真实几何启动"）。
    var hasStarted: Bool { didStart }

    // MARK: 回滚区与选区

    /// 回滚区显示偏移（0 = 实时画面）。
    ///
    /// 只要不为 0，新输出**不会**把视口拽回底部（终端惯例：用户翻上去看东西时不被踢下来）；
    /// 按任意键 / ⌘↓ / ⌘End / 滚回底部才回到实时画面。
    /// 说明：偏移是相对**缓冲区底部**算的，因此回滚区被裁剪时看到的还是"底部往上第 N 行"。
    @Published private(set) var scrollOffset = 0

    /// 当前鼠标选区（nil = 没有选中）。
    @Published private(set) var selection: TerminalSelection?

    var maxScrollOffset: Int { screen.maxScrollOffset }

    /// 视图要画的那几行（已应用回滚偏移）。
    func displayLines() -> [[TerminalCell]] {
        screen.visibleLines(offset: scrollOffset, height: screen.rows)
    }

    func scroll(byLines delta: Int) {
        let clamped = min(max(0, scrollOffset + delta), screen.maxScrollOffset)
        guard clamped != scrollOffset else { return }
        scrollOffset = clamped
        requestRedraw?()
    }

    func scrollToBottom() {
        guard scrollOffset != 0 else { return }
        scrollOffset = 0
        requestRedraw?()
    }

    func beginSelection(at raw: TerminalCellPosition) {
        let position = TerminalSelection.snapped(raw, in: displayLines())
        selection = TerminalSelection(anchor: position, focus: position)
        requestRedraw?()
    }

    func extendSelection(to raw: TerminalCellPosition) {
        guard var current = selection else { return }
        current.focus = TerminalSelection.snapped(raw, in: displayLines())
        selection = current
        requestRedraw?()
    }

    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        requestRedraw?()
    }

    /// 选区文本（没选中或选到空白时返回 nil）。取的是**当前显示的那几行**，
    /// 所以"看到什么就复制什么"。
    func selectedText() -> String? {
        guard let selection else { return nil }
        let text = selection.text(in: displayLines())
        return text.isEmpty ? nil : text
    }

    /// ⌘C：把选区写进系统剪贴板；没有选中时返回 false，让按键继续往下走。
    @discardableResult
    func copySelectionToPasteboard() -> Bool {
        guard let text = selectedText() else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    func startIfNeeded(columns: Int, rows: Int) {
        guard !didStart else { return }
        didStart = true
        session.onOutput = { [weak self] data in
            guard let self else { return }
            self.screen.feed([UInt8](data))
            self.requestRedraw?()
        }
        session.onExit = { [weak self] code in
            guard let self else { return }
            self.isRunning = false
            self.screen.feed(text: "\r\n[进程已退出，代码 \(code)]\r\n")
            self.requestRedraw?()
        }
        screen.resize(columns: columns, rows: rows)
        if session.start(columns: columns, rows: rows, workingDirectory: Self.launchDirectory()) {
            isRunning = true
        } else {
            isRunning = false
            errorText = session.lastError
        }
        requestRedraw?()
    }

    func restart(columns: Int, rows: Int) {
        session.terminate()
        screen.reset()
        scrollOffset = 0
        selection = nil
        didStart = false
        errorText = nil
        startIfNeeded(columns: columns, rows: rows)
    }

    func send(_ bytes: [UInt8]) {
        session.write(bytes)
    }

    func send(text: String) {
        session.write(text: text)
    }

    func resize(columns: Int, rows: Int) {
        screen.resize(columns: columns, rows: rows)
        session.resize(columns: columns, rows: rows)
        requestRedraw?()
    }

    func stop() {
        session.terminate()
        isRunning = false
    }

    /// 终端启动目录：工作区（待 Explorer 接入）＞ 有意义的启动目录 ＞ 家目录。
    ///
    /// 实测：Finder 双击 / `open` 拉起时 `currentDirectoryPath` 是 `/`，直接继承会让
    /// 终端一进去就是根目录；从命令行直接跑才是真正的"启动目录"。
    private static func launchDirectory() -> String {
        let fileManager = FileManager.default
        let isUsableDirectory: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue && fileManager.isReadableFile(atPath: path)
        }
        return TerminalWorkingDirectory.resolve(
            workspace: nil,
            launchDirectory: fileManager.currentDirectoryPath,
            home: fileManager.homeDirectoryForCurrentUser.path,
            isUsableDirectory: isUsableDirectory
        )
    }
}

// MARK: - 绘制 / 输入

/// 终端视图：把字符网格画出来，把按键写成字节。
///
/// 按行拼 `NSAttributedString` 再整行绘制——比逐格绘制简单，80×24 这个量级完全够用。
final class TerminalHostView: NSView {

    private let model: TerminalModel
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private lazy var cellSize: CGSize = {
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(font.ascender - font.descender + font.leading)
        return CGSize(width: max(1, width), height: max(1, height))
    }()

    /// 输入法正在组字的「未上屏文本」（如拼音串）。非空时画在光标处。
    private var markedText = ""
    private var markedSelection = NSRange(location: 0, length: 0)

    init(model: TerminalModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: 尺寸 → 网格

    override func layout() {
        super.layout()
        let columns = max(20, Int(bounds.width / cellSize.width))
        let rows = max(4, Int(bounds.height / cellSize.height))

        // 首次布局时用**真实几何**启动 PTY。
        //
        // 原先是在 SwiftUI 的 `onAppear` 里启动，那时视图还没布局，只能拿到模型默认的
        // 80×24 —— 全屏 TUI 的第一帧就是按错的列数排的（`dsh-tui` 的欢迎鲸鱼是
        // 13 行 × 40 列的固定 sprite，按错的尺寸排就会挤在一起）。
        if !model.hasStarted {
            guard bounds.width >= cellSize.width * 20, bounds.height >= cellSize.height * 4 else { return }
            model.startIfNeeded(columns: columns, rows: rows)
            return
        }

        if columns != model.screen.columns || rows != model.screen.rows {
            runCache.removeAll()
            model.resize(columns: columns, rows: rows)
        }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let lines = model.displayLines()
        for (rowIndex, cells) in lines.enumerated() {
            let origin = CGPoint(x: 0, y: CGFloat(rowIndex) * cellSize.height)
            drawBackgrounds(cells, at: origin, rowIndex: rowIndex)
            drawSelection(cells, at: origin, rowIndex: rowIndex)
            drawText(cells, at: origin, rowIndex: rowIndex)
        }
        drawCursor()
        drawMarkedText()
        drawScrollIndicator()
    }

    /// 选区高亮：按格填，与背景层同一套坐标（列号 × 格子宽度）。
    private func drawSelection(_ cells: [TerminalCell], at origin: CGPoint, rowIndex: Int) {
        guard let selection = model.selection, !selection.isEmpty else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55).setFill()
        for column in cells.indices where selection.contains(row: rowIndex, column: column) {
            NSRect(
                x: origin.x + CGFloat(column) * cellSize.width,
                y: origin.y,
                width: cellSize.width,
                height: cellSize.height
            ).fill()
        }
    }

    /// 翻上去看回滚区时的位置提示（右上角）。
    ///
    /// 只画箭头与数字、不含自然语言，所以不需要本地化文案键（本地化键表有奇偶校验，
    /// 为一句提示新增两套文案不划算）。
    private func drawScrollIndicator() {
        let offset = model.scrollOffset
        guard offset > 0 else { return }
        let text = "↑ \(offset)/\(model.maxScrollOffset)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor.withAlphaComponent(0.85)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: bounds.maxX - size.width - 6, y: 2),
            withAttributes: attributes
        )
    }

    /// 画输入法未上屏的组字（带下划线）—— 让用户看得到自己正在打的拼音 / 候选。
    private func drawMarkedText() {
        guard !markedText.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        NSAttributedString(string: markedText, attributes: attributes).draw(at: cursorCellRect.origin)
    }

    private func drawBackgrounds(_ cells: [TerminalCell], at origin: CGPoint, rowIndex: Int) {
        for (column, cell) in cells.enumerated() {
            guard let color = backgroundFill(for: cell) else { continue }
            color.setFill()
            NSRect(
                x: origin.x + CGFloat(column) * cellSize.width,
                y: origin.y,
                width: cellSize.width,
                height: cellSize.height
            ).fill()
        }
    }

    /// 按**绘制段**画，每段从自己的格子原点开始。
    ///
    /// 不能用"整行拼一个 NSAttributedString、一次性 draw"：那样字形落点由字体 advance
    /// 决定，而中日韩字符会回落成 PingFang、advance 只有 1.607 格（实测），
    /// 含中文的行会从第一个汉字起越画越偏。分段见 `Core/TerminalRun.swift`。
    ///
    /// 分段是**按行缓存**的：全屏 TUI 每帧都要重画整屏，若每帧都重新切段 + 新建
    /// `NSAttributedString`，一行 200 格就能堆出几千次分配。缓存按「这一行的格子内容」
    /// 命中，内容没变的行直接复用上一帧的分段与属性串。
    private func drawText(_ cells: [TerminalCell], at origin: CGPoint, rowIndex: Int) {
        let cached = attributedRuns(forRow: cells, rowIndex: rowIndex)
        for (run, attributed) in zip(cached.runs, cached.attributed) {
            attributed.draw(
                at: CGPoint(x: origin.x + CGFloat(run.column) * cellSize.width, y: origin.y)
            )
        }
    }

    private struct CachedRuns {
        var cells: [TerminalCell]
        var runs: [TerminalRun]
        var attributed: [NSAttributedString]
    }

    private var runCache: [Int: CachedRuns] = [:]

    private func attributedRuns(forRow cells: [TerminalCell], rowIndex: Int) -> CachedRuns {
        if let cached = runCache[rowIndex], cached.cells == cells { return cached }
        let runs = TerminalScreen.runs(in: cells)
        let entry = CachedRuns(
            cells: cells,
            runs: runs,
            attributed: runs.map {
                NSAttributedString(string: $0.text, attributes: attributes(for: $0.cell))
            }
        )
        runCache[rowIndex] = entry
        return entry
    }

    private func attributes(for cell: TerminalCell) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: cell.bold
                ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
                : font,
            .foregroundColor: foreground(for: cell)
        ]
        if cell.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    /// 前景色：反显时用背景当字色。
    private func foreground(for cell: TerminalCell) -> NSColor {
        if cell.inverse {
            return Self.color(for: cell.background, isBackground: true)
        }
        return Self.color(for: cell.foreground, isBackground: false)
    }

    /// 需要画的背景块（反显时画前景色）；默认背景不画。
    private func backgroundFill(for cell: TerminalCell) -> NSColor? {
        if cell.inverse {
            return Self.color(for: cell.foreground, isBackground: false)
        }
        if cell.background == .default { return nil }
        return Self.color(for: cell.background, isBackground: true)
    }

    /// 光标所在的格子（视图坐标）。
    private var cursorCellRect: NSRect {
        NSRect(
            x: CGFloat(model.screen.cursorColumn) * cellSize.width,
            y: CGFloat(model.screen.cursorRow) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
    }

    private func drawCursor() {
        guard model.screen.isCursorVisible else { return }
        let rect = cursorCellRect
        if window?.firstResponder === self {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6).setFill()
            rect.fill()
        } else {
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: 颜色

    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.00, green: 0.00, blue: 0.00, alpha: 1),
        NSColor(calibratedRed: 0.80, green: 0.14, blue: 0.15, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.80, green: 0.62, blue: 0.11, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.78, alpha: 1),
        NSColor(calibratedRed: 0.68, green: 0.25, blue: 0.72, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.63, blue: 0.69, alpha: 1),
        NSColor(calibratedRed: 0.80, green: 0.80, blue: 0.80, alpha: 1),
        NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.94, green: 0.36, blue: 0.36, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.85, blue: 0.42, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.80, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.58, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.86, green: 0.48, blue: 0.90, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.84, blue: 0.88, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)
    ]

    static func color(for terminalColor: TerminalColor, isBackground: Bool) -> NSColor {
        switch terminalColor {
        case .default:
            return isBackground ? .textBackgroundColor : .textColor
        case .rgb(let red, let green, let blue):
            return NSColor(
                calibratedRed: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
        case .indexed(let index):
            switch index {
            case 0...15:
                return palette[Int(index)]
            case 16...231:
                let value = Int(index) - 16
                let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
                return NSColor(
                    calibratedRed: steps[value / 36] / 255,
                    green: steps[(value % 36) / 6] / 255,
                    blue: steps[value % 6] / 255,
                    alpha: 1
                )
            default:
                let level = CGFloat(8 + (Int(index) - 232) * 10) / 255
                return NSColor(calibratedRed: level, green: level, blue: level, alpha: 1)
            }
        }
    }

    // MARK: 输入

    /// 触控板给的是带小数的精确位移，先攒够一行再滚，免得疯狂抖动。
    private var scrollRemainder: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let position = cellPosition(for: event)
        if event.modifierFlags.contains(.shift), model.selection != nil {
            model.extendSelection(to: position)
        } else {
            model.beginSelection(at: position)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        model.extendSelection(to: cellPosition(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        // 只是点了一下（没拖出范围）：清掉那一格高亮，不然屏幕上会留个孤零零的方块。
        if model.selection?.isEmpty == true { model.clearSelection() }
    }

    override func scrollWheel(with event: NSEvent) {
        scrollRemainder += event.scrollingDeltaY
        let lines = Int(scrollRemainder / cellSize.height)
        guard lines != 0 else { return }
        scrollRemainder -= CGFloat(lines) * cellSize.height
        // 向上滚（deltaY 为正）= 看更早的行 → 偏移增大。
        model.scroll(byLines: lines)
    }

    /// 视图坐标 → 格子位置（越界夹住，拖动到面板外也不会算飞出范围）。
    private func cellPosition(for event: NSEvent) -> TerminalCellPosition {
        let point = convert(event.locationInWindow, from: nil)
        let row = min(max(0, Int(point.y / cellSize.height)), max(0, model.screen.rows - 1))
        let column = min(max(0, Int(point.x / cellSize.width)), max(0, model.screen.columns - 1))
        return TerminalCellPosition(row: row, column: column)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            // ⌘V 粘贴：把整段文本喂给 shell。
            case "v":
                if let text = NSPasteboard.general.string(forType: .string) {
                    model.send(text: text)
                    return
                }
            // ⌘C 复制选区；没有选中就不拦，让按键照常往下走。
            case "c":
                if model.copySelectionToPasteboard() { return }
            // ⌘↓ / ⌘End：回到实时画面（翻上去看回滚区之后的"逃出"键）。
            case "\u{F701}", "\u{F72B}":
                model.scrollToBottom()
                return
            default:
                break
            }
            super.keyDown(with: event)
            return
        }

        // 有输入就回到实时画面（终端惯例：一边往上翻一边打字，视线要跟着回底部）。
        model.scrollToBottom()

        // 控制键 / 方向键 / 功能键：固定字节序列，不经过输入法。
        if let bytes = Self.controlBytes(for: event) {
            model.send(bytes)
            return
        }

        // 其余（含中文）交给输入法：组字 → 候选 → 上屏 走 NSTextInputClient。
        // 没这一步，输入法切换对终端完全不起作用。
        interpretKeyEvents([event])
    }

    /// 控制键 / 方向键 / 功能键 → 写进 PTY 的字节序列；不是这类键时返回 nil。
    static func controlBytes(for event: NSEvent) -> [UInt8]? {
        switch event.keyCode {
        case 36, 76: return [0x0D]                 // Return / 小键盘 Enter
        case 51: return [0x7F]                     // Delete（退格）
        case 48: return [0x09]                     // Tab
        case 53: return [0x1B]                     // Esc
        case 123: return Array("\u{1B}[D".utf8)    // ←
        case 124: return Array("\u{1B}[C".utf8)    // →
        case 125: return Array("\u{1B}[B".utf8)    // ↓
        case 126: return Array("\u{1B}[A".utf8)    // ↑
        case 115: return Array("\u{1B}[H".utf8)    // Home
        case 119: return Array("\u{1B}[F".utf8)    // End
        case 116: return Array("\u{1B}[5~".utf8)   // Page Up
        case 121: return Array("\u{1B}[6~".utf8)   // Page Down
        case 117: return Array("\u{1B}[3~".utf8)   // 前向删除
        case 122: return Array("\u{1B}OP".utf8)    // F1
        case 120: return Array("\u{1B}OQ".utf8)    // F2
        case 99: return Array("\u{1B}OR".utf8)     // F3
        case 118: return Array("\u{1B}OS".utf8)    // F4
        case 96: return Array("\u{1B}[15~".utf8)   // F5
        case 97: return Array("\u{1B}[17~".utf8)   // F6
        case 98: return Array("\u{1B}[18~".utf8)   // F7
        case 100: return Array("\u{1B}[19~".utf8)  // F8
        case 101: return Array("\u{1B}[20~".utf8)  // F9
        case 109: return Array("\u{1B}[21~".utf8)  // F10
        case 103: return Array("\u{1B}[23~".utf8)  // F11
        case 111: return Array("\u{1B}[24~".utf8)  // F12
        default: break
        }

        // ⌃ + 字母 / 符号：转成控制字节（⌃C = 0x03）
        if event.modifierFlags.contains(.control),
           let characters = event.characters,
           let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return [UInt8(scalar.value)] }
            if scalar.value >= 0x61, scalar.value <= 0x7A { return [UInt8(scalar.value - 0x60)] }
            if scalar.value >= 0x40, scalar.value <= 0x5F { return [UInt8(scalar.value - 0x40)] }
        }
        return nil
    }

    // MARK: 输入法

    /// 走键盘命令通道的那些（输入法 / 系统也可能派发到这里）。
    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            model.send([0x0D])
        case #selector(NSResponder.insertTab(_:)):
            model.send([0x09])
        case #selector(NSResponder.insertBacktab(_:)):
            model.send(Array("\u{1B}[Z".utf8))
        case #selector(NSResponder.cancelOperation(_:)):
            model.send([0x1B])
        case #selector(NSResponder.deleteBackward(_:)):
            model.send([0x7F])
        case #selector(NSResponder.deleteForward(_:)):
            model.send(Array("\u{1B}[3~".utf8))
        case #selector(NSResponder.moveLeft(_:)):
            model.send(Array("\u{1B}[D".utf8))
        case #selector(NSResponder.moveRight(_:)):
            model.send(Array("\u{1B}[C".utf8))
        case #selector(NSResponder.moveUp(_:)):
            model.send(Array("\u{1B}[A".utf8))
        case #selector(NSResponder.moveDown(_:)):
            model.send(Array("\u{1B}[B".utf8))
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            model.send(Array("\u{1B}[H".utf8))
        case #selector(NSResponder.scrollToEndOfDocument(_:)):
            model.send(Array("\u{1B}[F".utf8))
        case #selector(NSResponder.pageUp(_:)):
            model.send(Array("\u{1B}[5~".utf8))
        case #selector(NSResponder.pageDown(_:)):
            model.send(Array("\u{1B}[6~".utf8))
        default:
            break
        }
    }
}

// MARK: - 输入法

/// 中文等组字输入法能工作的关键：可打印输入走 `interpretKeyEvents`，
/// 系统把组字 / 候选 / 上屏通过下面这套回调交回来。**没实现它，输入法切换就没反应。**
extension TerminalHostView: NSTextInputClient {

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainString(from: string)
        clearMarkedText()
        guard !text.isEmpty else { return }
        model.send(text: text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = Self.plainString(from: string)
        markedSelection = selectedRange
        needsDisplay = true
    }

    func unmarkText() {
        clearMarkedText()
    }

    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange {
        // 终端没有"可选中文本"的概念，按未上屏组字处理即可。
        markedRange()
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard !markedText.isEmpty else { return nil }
        actualRange?.pointee = markedRange()
        return NSAttributedString(
            string: markedText,
            attributes: [
                .font: font,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .underlineStyle]
    }

    /// 候选窗口贴在终端光标处，而不是屏幕角落。
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = markedRange()
        guard let window else { return .zero }
        let inWindow = convert(cursorCellRect, to: nil)
        return window.convertToScreen(inWindow)
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    private func clearMarkedText() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    private static func plainString(from value: Any) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let plain = value as? String { return plain }
        return ""
    }
}

// MARK: - SwiftUI 包装

struct TerminalView: NSViewRepresentable {
    @ObservedObject var model: TerminalModel

    func makeNSView(context: Context) -> TerminalHostView {
        let view = TerminalHostView(model: model)
        model.attach { [weak view] in
            view?.needsDisplay = true
        }
        return view
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        nsView.needsDisplay = true
    }
}
