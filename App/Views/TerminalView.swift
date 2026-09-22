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
        if session.start(columns: columns, rows: rows) {
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
        if columns != model.screen.columns || rows != model.screen.rows {
            model.resize(columns: columns, rows: rows)
        }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let lines = model.screen.visibleLines()
        for (rowIndex, cells) in lines.enumerated() {
            let origin = CGPoint(x: 0, y: CGFloat(rowIndex) * cellSize.height)
            drawBackgrounds(cells, at: origin, rowIndex: rowIndex)
            drawText(cells, at: origin)
        }
        drawCursor()
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

    private func drawText(_ cells: [TerminalCell], at origin: CGPoint) {
        let attributed = NSMutableAttributedString()
        for cell in cells {
            guard let character = cell.character else { continue }
            attributed.append(NSAttributedString(string: String(character), attributes: attributes(for: cell)))
        }
        guard attributed.length > 0 else { return }
        attributed.draw(at: origin)
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

    private func drawCursor() {
        guard model.screen.isCursorVisible else { return }
        let rect = NSRect(
            x: CGFloat(model.screen.cursorColumn) * cellSize.width,
            y: CGFloat(model.screen.cursorRow) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘V 粘贴：把整段文本喂给 shell。
            if event.charactersIgnoringModifiers == "v",
               let text = NSPasteboard.general.string(forType: .string) {
                model.send(text: text)
                return
            }
            super.keyDown(with: event)
            return
        }

        if let bytes = Self.bytes(for: event) {
            model.send(bytes)
        } else {
            super.keyDown(with: event)
        }
    }

    /// 按键 → 要写进 PTY 的字节序列。
    static func bytes(for event: NSEvent) -> [UInt8]? {
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

        guard let characters = event.characters, !characters.isEmpty else { return nil }

        if event.modifierFlags.contains(.control), let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return [UInt8(scalar.value)] }
            if scalar.value >= 0x61, scalar.value <= 0x7A { return [UInt8(scalar.value - 0x60)] }
            if scalar.value >= 0x40, scalar.value <= 0x5F { return [UInt8(scalar.value - 0x40)] }
        }
        return Array(characters.utf8)
    }

    // MARK: 输入法

    override func doCommand(by selector: Selector) {
        // 组字相关命令交给系统；其余不响应（否则 Tab / Esc 会被当成命令吃掉）。
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            model.send([0x0D])
        case #selector(NSResponder.insertTab(_:)):
            model.send([0x09])
        case #selector(NSResponder.cancelOperation(_:)):
            model.send([0x1B])
        case #selector(NSResponder.deleteBackward(_:)):
            model.send([0x7F])
        default:
            break
        }
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
