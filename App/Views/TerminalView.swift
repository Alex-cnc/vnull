// 终端配色（FR-EDIT-29）：色值**全部**来自 `Core/TerminalPalette`（深 / 浅两套 ANSI 色板，
// 可单测、有对比度与可区分性门槛），视图只做「外观 → 色板 → NSColor」的绑定。
// 这里不再有裸色值：曾经那 16 个手写 NSColor 已经搬进 Core 并换成有门槛的调色板。
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

    /// 工作区路径（FR-EDIT-32）：终端启动目录以它为准。
    ///
    /// 说明：**只在启动那一刻读取** —— 已经跑起来的 shell 不会被"换工作区"搬走
    /// （与 VS Code 一致：换工作区是开新终端，而不是把正在跑的命令换目录）。
    var workspacePath: String?

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

    /// ⌘C / 菜单「复制」：把选区写进系统剪贴板；没有选中时返回 false，让按键继续往下走。
    @discardableResult
    func copySelectionToPasteboard() -> Bool {
        guard let text = selectedText() else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    /// ⌘V / 菜单「粘贴」：读系统剪贴板并发给 shell。
    ///
    /// 走 `TerminalPaste`（Core 的纯函数）而不是直接 `session.write(text:)`：
    /// 前台程序开了**括号粘贴**（SGR 2004）时必须把内容包起来，否则 vim 会逐行自动缩进、
    /// 多行 SQL 可能被逐行提交。包装规则与换行处理都是纯逻辑，那边有单测。
    @discardableResult
    func pasteFromPasteboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        let payload = TerminalPaste.payload(
            for: text,
            isBracketedPasteEnabled: screen.isBracketedPasteEnabled
        )
        guard !payload.isEmpty else { return false }
        send(payload)
        return true
    }

    /// ⌘A：全选**当前显示的那几行**（含回滚区偏移后的视图）。
    ///
    /// 只选可见范围而不是整个回滚区：回滚区可能有上万行，全选之后复制会得到一个
    /// 巨大字符串；终端惯例（Terminal.app / iTerm2）也是按可见范围来的。
    func selectAllVisible() {
        let lines = displayLines()
        guard let last = lines.indices.last, lines[last].indices.last != nil else { return }
        selection = TerminalSelection(
            anchor: TerminalCellPosition(row: 0, column: 0),
            focus: TerminalCellPosition(row: last, column: max(0, lines[last].count - 1))
        )
        requestRedraw?()
    }

    func startIfNeeded(columns: Int, rows: Int) {
        guard !didStart else { return }
        didStart = true
        session.onOutput = { [weak self] data in
            guard let self else { return }
            self.screen.feed([UInt8](data))
            // 设备查询应答（DA1 / DSR / DECRQM / XTVERSION）要**回给前台程序**：
            // 不回话的话，vim / tmux 一类程序会一直等这一行，表现为"界面卡住"。
            let responses = self.screen.drainResponses()
            if !responses.isEmpty { self.session.write(responses) }
            self.requestRedraw?()
        }
        session.onExit = { [weak self] code in
            guard let self else { return }
            self.isRunning = false
            self.screen.feed(text: "\r\n[进程已退出，代码 \(code)]\r\n")
            self.requestRedraw?()
        }
        screen.resize(columns: columns, rows: rows)
        if session.start(columns: columns, rows: rows, workingDirectory: launchDirectory()) {
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
    private func launchDirectory() -> String {
        let fileManager = FileManager.default
        let isUsableDirectory: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue && fileManager.isReadableFile(atPath: path)
        }
        return TerminalWorkingDirectory.resolve(
            workspace: workspacePath,
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
final class TerminalHostView: NSView, NSMenuItemValidation {

    private let model: TerminalModel
    /// 外观偏好（可覆盖系统外观；解析在 Core 的 `TerminalAppearance`）。
    ///
    /// 名字不叫 `appearance`：那会和 `NSView.appearance`（`NSAppearance?`）撞名。
    private var appearancePreference: TerminalAppearance
    /// 当前字号（pt）。夹取在 Core 的 `TerminalFontSize`，视图不自己定上下限。
    private var fontSize: Int
    private var font: NSFont
    private var cellSize: CGSize

    /// 造字体：唯一一处"字号 → NSFont"的翻译。
    ///
    /// **字体族**来自全局等宽字体偏好（FR-EDIT-26），**字号**用终端自己的设置 ——
    /// 与 VS Code 的 `terminal.integrated.fontFamily` / `fontSize` 同一个分工：
    /// 族要统一（否则编辑器与终端字形不一致），字号要能分开（终端常配小一点）。
    private static func makeFont(size: Int) -> NSFont {
        FontManager.shared.monospaceNSFont(size: CGFloat(size))
    }

    /// 量格子：等宽字体的 advance 与行高都按当前字号实测，不查表。
    private static func measure(_ font: NSFont) -> CGSize {
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(font.ascender - font.descender + font.leading)
        return CGSize(width: max(1, width), height: max(1, height))
    }

    /// 输入法正在组字的「未上屏文本」（如拼音串）。非空时画在光标处。
    private var markedText = ""
    private var markedSelection = NSRange(location: 0, length: 0)

    init(model: TerminalModel, appearance: TerminalAppearance, fontSize: Int) {
        self.model = model
        self.appearancePreference = appearance
        let clamped = TerminalFontSize.clamped(fontSize)
        self.fontSize = clamped
        let font = Self.makeFont(size: clamped)
        self.font = font
        self.cellSize = Self.measure(font)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.nsColor(palette.background).cgColor
    }

    /// 应用偏好（外观 / 字号）。
    ///
    /// 字号变化必须**重建字体与格子尺寸并重新布局**：`layout()` 用格子宽度反算列数发给 PTY，
    /// 拿旧格子去算就会把一个 120 列的窗口报成 80 列，TUI 的第一帧就排错了。
    func apply(appearance: TerminalAppearance, fontSize: Int) {
        if self.appearancePreference != appearance {
            self.appearancePreference = appearance
            runCache.removeAll()
            layer?.backgroundColor = Theme.nsColor(palette.background).cgColor
            needsDisplay = true
        }

        // 字体族来自全局偏好（FR-EDIT-26）：偏好变了、或字号变了，都要重建字体与格子尺寸。
        let clamped = TerminalFontSize.clamped(fontSize)
        let current = FontManager.shared.monospaceNSFont(size: CGFloat(clamped))
        if self.fontSize == clamped, self.font.fontName == current.fontName, self.font.pointSize == current.pointSize {
            return
        }
        self.fontSize = clamped
        let font = Self.makeFont(size: clamped)
        self.font = font
        self.cellSize = Self.measure(font)
        runCache.removeAll()
        needsDisplay = true
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: 标准编辑动作（让菜单栏「编辑 → 复制 / 粘贴 / 全选」也对终端生效）
    //
    // 为什么必须有：⌘C / ⌘V 在 `keyDown` 里能拦住，但**菜单项走的是响应链上的
    // `copy:` / `paste:` 选择器** —— 视图不实现它们，菜单里那两项就是灰的 / 点了没反应。
    // 同一件事做两条路径容易分叉，所以都指向上面同一组方法。

    // `copy:` / `paste:` / `selectAll:` 是 NSResponder 上已有的动作，所以要 override。
    @objc func copy(_ sender: Any?) {
        _ = model.copySelectionToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        _ = model.pasteFromPasteboard()
    }

    // `selectAll:` 在 NSResponder 上有实现（要 override），而 `copy:` / `paste:` 是
    // 响应链上的标准动作（协议提供、不加 override）—— 三条名字看着一样，处理却不同。
    override func selectAll(_ sender: Any?) {
        model.selectAllVisible()
    }

    /// 没有选区时「复制」应当是灰的（而不是点了没反应）。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return model.selectedText() != nil
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string)?.isEmpty == false
        case #selector(selectAll(_:)):
            return true
        default:
            return true
        }
    }

    // MARK: 配色（全部来自 Core/TerminalPalette）

    /// 当前外观是否深色。终端**跟随系统外观**：浅色下用浅色色板，深色下用深色色板 ——
    /// 只有一套色板时，另一套外观里必然有一半的 ANSI 色不可读（旧实现就是这个毛病）。
    private var isDarkTerminal: Bool {
        appearancePreference.resolvesToDark(systemIsDark: systemIsDarkAppearance)
    }

    /// 系统当前是否深色（只有"跟随系统"这一档会用到它）。
    private var systemIsDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var palette: TerminalPalette {
        Theme.terminalPalette(isDark: isDarkTerminal)
    }

    /// 换外观（深浅切换）时：清掉按行缓存并重画 —— 缓存里存着**属性串**，
    /// 不清会拿旧色板画的字继续显示。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        runCache.removeAll()
        layer?.backgroundColor = Theme.nsColor(palette.background).cgColor
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        observeWindowFocus()
    }

    /// 焦点上报（`?1004`）：前台程序要的话，窗口拿到 / 失去焦点时各发一次
    /// `ESC [ I` / `ESC [ O`（xterm 的约定）。不报的话，TUI 分不清
    /// "用户切走了窗口"与"用户没在打字"，光标闪烁与重绘策略会不对。
    private func observeWindowFocus() {
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        focusObservers.append(
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.reportFocus(gained: true)
            }
        )
        focusObservers.append(
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.reportFocus(gained: false)
            }
        )
    }

    private func reportFocus(gained: Bool) {
        guard model.screen.isFocusReportingEnabled else { return }
        model.send(Array((gained ? "\u{1B}[I" : "\u{1B}[O").utf8))
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
        Theme.nsColor(palette.background).setFill()
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
        Theme.nsColor(palette.selectionBackground).setFill()
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
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, CGFloat(fontSize) - 1), weight: .medium),
            .foregroundColor: Theme.nsColor(TextTone.secondary),
            .backgroundColor: Theme.nsColor(Surface.raised).withAlphaComponent(0.85)
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
            .foregroundColor: Theme.nsColor(palette.foreground),
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
                ? FontManager.shared.monospaceBoldNSFont(size: font.pointSize)
                : font,
            .foregroundColor: foreground(for: cell)
        ]
        if cell.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    /// 前景色（粗体提亮 / 暗淡 / 反显都在 Core 的色板里算好）。
    private func foreground(for cell: TerminalCell) -> NSColor {
        Theme.terminalForeground(for: cell, isDark: isDarkTerminal)
    }

    /// 需要画的背景块；等于终端底色时不画（省一次整屏填充）。
    private func backgroundFill(for cell: TerminalCell) -> NSColor? {
        guard let rgb = palette.resolvedBackground(for: cell), rgb != palette.background else { return nil }
        return Theme.nsColor(rgb)
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
        guard window?.firstResponder === self else {
            // 失焦时只描一个空心框：块状光标在失焦窗口里会显得"这里还能打字"。
            Theme.nsColor(palette.cursor).withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
            return
        }

        // 块状光标 + **把光标下的字用底色重画**（反白）。
        // 半透明块会让字符看起来发脏，而真正终端里块光标下就是反白的。
        Theme.nsColor(palette.cursor).setFill()
        rect.fill()

        let line = model.screen.line(model.screen.cursorRow)
        let column = model.screen.cursorColumn
        guard line.indices.contains(column) else { return }
        let text = line[column].displayText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: Theme.nsColor(palette.background)
            ]
        ).draw(at: rect.origin)
    }

    // MARK: 颜色

    // MARK: 输入

    /// 触控板给的是带小数的精确位移，先攒够一行再滚，免得疯狂抖动。
    private var scrollRemainder: CGFloat = 0
    /// 窗口焦点通知的观察者（`?1004` 焦点上报用；换窗口时先摘掉旧的）。
    private var focusObservers: [NSObjectProtocol] = []

    /// 前台程序是否接管了鼠标，且这次事件**不是**"强制本地选中"。
    ///
    /// 惯例（VS Code / PuTTY 等）：按住 **⌥** 时把鼠标还给本地 —— 否则在 vim / tmux 里
    /// 一个字都选不了。代价是这类事件里不报 Meta 修饰键，这一点写在 `help` 与文档里。
    private func isReportingMouse(_ event: NSEvent) -> Bool {
        model.screen.isMouseReportingActive && !event.modifierFlags.contains(.option)
    }

    private func mouseModifiers(for event: NSEvent) -> TerminalInput.MouseModifiers {
        var modifiers: TerminalInput.MouseModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    private func sendMouse(_ action: TerminalInput.MouseAction, button: TerminalInput.MouseButton, event: NSEvent) {
        let position = cellPosition(for: event)
        let report = TerminalInput.MouseEvent(
            action: action,
            button: button,
            modifiers: mouseModifiers(for: event),
            column: position.column + 1,
            row: position.row + 1
        )
        guard TerminalInput.shouldReport(report, mode: model.screen.mouseTrackingMode) else { return }
        model.send(TerminalInput.mouseReport(report, sgr: model.screen.isSGRMouseEnabled))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if isReportingMouse(event) {
            sendMouse(.press, button: event.buttonNumber == 1 ? .right : .left, event: event)
            return
        }
        let position = cellPosition(for: event)
        if event.modifierFlags.contains(.shift), model.selection != nil {
            model.extendSelection(to: position)
        } else {
            model.beginSelection(at: position)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isReportingMouse(event) {
            let button: TerminalInput.MouseButton = switch event.buttonNumber {
            case 1: .right
            case 2: .middle
            default: .left
            }
            sendMouse(.motion, button: button, event: event)
            return
        }
        model.extendSelection(to: cellPosition(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        if isReportingMouse(event) {
            sendMouse(.release, button: event.buttonNumber == 1 ? .right : .left, event: event)
            return
        }
        // 只是点了一下（没拖出范围）：清掉那一格高亮，不然屏幕上会留个孤零零的方块。
        if model.selection?.isEmpty == true { model.clearSelection() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isReportingMouse(event) else { return super.rightMouseDown(with: event) }
        sendMouse(.press, button: .right, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isReportingMouse(event) else { return super.rightMouseUp(with: event) }
        sendMouse(.release, button: .right, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard isReportingMouse(event) else { return super.otherMouseDown(with: event) }
        sendMouse(.press, button: .middle, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard isReportingMouse(event) else { return super.otherMouseUp(with: event) }
        sendMouse(.release, button: .middle, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // 前台程序要鼠标时，滚轮也要报给它（否则 TUI 里滚不动）；
        // 每越过一格就报一次，避免一次手势刷出几百条消息。
        if isReportingMouse(event) {
            scrollRemainder += event.scrollingDeltaY
            let steps = Int(scrollRemainder / cellSize.height)
            guard steps != 0 else { return }
            scrollRemainder -= CGFloat(steps) * cellSize.height
            for _ in 0..<abs(steps) {
                sendMouse(steps > 0 ? .wheelUp : .wheelDown, button: .left, event: event)
            }
            return
        }
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
            // ⌘V 粘贴：整段文本喂给 shell（括号粘贴包装见 `pasteFromPasteboard`）。
            case "v":
                if model.pasteFromPasteboard() { return }
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
        if let bytes = Self.controlBytes(
            for: event,
            applicationCursorKeys: model.screen.isApplicationCursorKeysEnabled
        ) {
            model.send(bytes)
            return
        }

        // 其余（含中文）交给输入法：组字 → 候选 → 上屏 走 NSTextInputClient。
        // 没这一步，输入法切换对终端完全不起作用。
        interpretKeyEvents([event])
    }

    /// 控制键 / 方向键 / 功能键 → 写进 PTY 的字节序列；不是这类键时返回 nil。
    ///
    /// - Parameter applicationCursorKeys: DECCKM（`?1`）。置位时方向键 / Home / End 走 SS3
    ///   （`ESC O A`），否则 CSI（`ESC [ A`）—— vim / less 靠这个区分两种键序。
    static func controlBytes(for event: NSEvent, applicationCursorKeys: Bool = false) -> [UInt8]? {
        func cursorKey(_ key: TerminalInput.CursorKey) -> [UInt8] {
            TerminalInput.cursorKey(key, applicationCursorKeys: applicationCursorKeys)
        }
        switch event.keyCode {
        case 36, 76: return [0x0D]                 // Return / 小键盘 Enter
        case 51: return [0x7F]                     // Delete（退格）
        case 48: return [0x09]                     // Tab
        case 53: return [0x1B]                     // Esc
        case 123: return cursorKey(.left)
        case 124: return cursorKey(.right)
        case 125: return cursorKey(.down)
        case 126: return cursorKey(.up)
        case 115: return cursorKey(.home)
        case 119: return cursorKey(.end)
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
            model.send(TerminalInput.cursorKey(.left, applicationCursorKeys: model.screen.isApplicationCursorKeysEnabled))
        case #selector(NSResponder.moveRight(_:)):
            model.send(TerminalInput.cursorKey(.right, applicationCursorKeys: model.screen.isApplicationCursorKeysEnabled))
        case #selector(NSResponder.moveUp(_:)):
            model.send(TerminalInput.cursorKey(.up, applicationCursorKeys: model.screen.isApplicationCursorKeysEnabled))
        case #selector(NSResponder.moveDown(_:)):
            model.send(TerminalInput.cursorKey(.down, applicationCursorKeys: model.screen.isApplicationCursorKeysEnabled))
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            model.send(TerminalInput.cursorKey(.home, applicationCursorKeys: model.screen.isApplicationCursorKeysEnabled))
        case #selector(NSResponder.scrollToEndOfDocument(_:)):
            model.send(TerminalInput.cursorKey(.end, applicationCursorKeys: model.screen.isApplicationCursorKeysEnabled))
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
    /// 订阅等宽字体偏好：族一变就重跑 `updateNSView` → 宿主换成新字体（FR-EDIT-26）。
    @ObservedObject private var fonts = FontManager.shared
    /// 外观偏好（跟随系统 / 总是深色 / 总是浅色），来自用户在「外观」面板里的选择。
    var appearance: TerminalAppearance = .followSystem
    /// 终端字号（pt）。
    var fontSize: Int = TerminalFontSize.default

    func makeNSView(context: Context) -> TerminalHostView {
        let view = TerminalHostView(model: model, appearance: appearance, fontSize: fontSize)
        model.attach { [weak view] in
            view?.needsDisplay = true
        }
        return view
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        // 设置改了要**真的应用**（重建字体 / 换色板），不是只重画一次。
        nsView.apply(appearance: appearance, fontSize: fontSize)
    }
}
