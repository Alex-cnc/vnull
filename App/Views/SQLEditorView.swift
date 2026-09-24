import SwiftUI
import AppKit
import DoyahCore

/// SQL 编辑器：NSTextView 桥接。
///
/// - 关键字自动变成紫色，函数、字符串、注释、数字分别配色
/// - 静态检查（未闭合字符串/注释/括号）以红色下划线和提示条展示
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    let databaseType: DatabaseType
    let diagnostics: [SQLDiagnostic]
    /// 命令通道只对当前页签生效。
    let tabID: UUID
    /// 查询记忆索引（FR-AI-13 S4）：默认空索引 —— 无记忆时补全行为与历史版本一致。
    var memoryIndex = QueryMemory.Index()
    /// 记忆的隔离键（连接名）；nil 表示不按连接过滤。
    var memoryConnection: String?

    @ObservedObject private var commandCenter = EditorCommandCenter.shared

    /// 编辑器字体（FR-EDIT-26）：字体族与字号来自用户偏好，由 `FontManager` 统一交付。
    ///
    /// 改成计算属性（原来是一次性 `static let`）：偏好一改，这里必须跟着变 ——
    /// 否则会出现"设置里换了字体、编辑器还是旧字形"。
    static var baseFont: NSFont { Theme.nsFont(.mono) }
    static var keywordFont: NSFont {
        FontManager.shared.monospaceBoldNSFont(size: Theme.nsFont(.mono).pointSize)
    }

    /// 订阅字体偏好：偏好一变，SwiftUI 会重跑 `updateNSView`，编辑器据此换字体（无需父视图转发）。
    @ObservedObject private var fonts = FontManager.shared

    private static let tokenizers: [DatabaseType: SQLTokenizer] = [
        .postgresql: SQLTokenizer.standard(.postgresql),
        .gbase8a: SQLTokenizer.standard(.gbase8a)
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SQLTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = Self.baseFont
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.string = text

        context.coordinator.textView = textView
        context.coordinator.applyHighlighting()

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SQLTextView else { return }

        context.coordinator.parent = self

        // 只有「外部改动」（载入文件 / 切换页签 / 工具栏命令）才覆写编辑器内容。
        // 中文输入法组字期间绝不覆写：整段替换会重置 NSTextInputContext，
        // 提交后光标会跳到串首（BUG-005）。
        if context.coordinator.textSync.evaluateUpdate(
            text,
            editorText: textView.string,
            hasMarkedText: textView.hasMarkedText()
        ) {
            context.coordinator.applyExternalText(text, to: textView)
        }

        // 字体偏好变了 → 换字体（含输入法用的 typingAttributes），再重着色一次。
        // 与高亮一样，重设文本属性要避开输入法回调栈，所以也走延后执行。
        if textView.font?.fontName != Self.baseFont.fontName
            || textView.font?.pointSize != Self.baseFont.pointSize {
            context.coordinator.applyFontChange(to: textView)
        }

        // 着色统一延后到下一个 runloop：在 SwiftUI 更新 / 输入法回调栈里重设
        // 文本属性会破坏输入上下文（BUG-005）。
        context.coordinator.scheduleHighlighting()

        if let request = commandCenter.request,
           request.tabID == tabID,
           request.id != context.coordinator.lastCommandID {
            context.coordinator.lastCommandID = request.id
            context.coordinator.perform(request.command)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: SQLTextView?
        var isUpdatingFromSwiftUI = false
        var lastCommandID: UUID?

        /// 编辑器文本 ↔ 绑定 的同步判定（中文输入法缺陷 BUG-005）。
        var textSync = EditorTextSync()
        /// 延后执行的高亮任务：提交回调栈里重设属性会破坏输入法上下文。
        private var highlightWorkItem: DispatchWorkItem?

        init(_ parent: SQLEditorView) {
            self.parent = parent
        }

        /// 字体偏好变化时换字体（FR-EDIT-26）。
        ///
        /// 与高亮一样**延后到下一个 runloop**：在 SwiftUI 更新 / 输入法回调栈里重设
        /// 文本属性会破坏输入上下文（BUG-005 的同一类问题）。
        func applyFontChange(to textView: NSTextView) {
            let base = SQLEditorView.baseFont
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                textView.font = base
                textView.typingAttributes = [
                    .font: base,
                    .foregroundColor: Theme.nsColor(TextTone.primary)
                ]
                self.scheduleHighlighting()
            }
        }

        /// 光标 / 选区变化时上报给命令通道（FR-EXEC-14「只跑光标所在语句」要用）。
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            EditorCommandCenter.shared.reportSelection(
                tabID: parent.tabID,
                range: textView.selectedRange()
            )
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !isUpdatingFromSwiftUI, !textView.isApplyingAttributes else { return }

            textSync.notePublished(textView.string)
            parent.text = textView.string

            // 组字（marked text）期间不要重设属性，否则会打断输入法。
            guard !textView.hasMarkedText() else { return }

            // 提交后立刻重设属性同样危险：此时仍在输入法回调栈里，
            // 会重置输入上下文导致下次输入插到串首（BUG-005）。
            // 因此延后到下一个 runloop 再着色。
            scheduleHighlighting()
        }

        /// 把外部改动写回编辑器（载入文件 / 切换页签 / 载入已保存查询等）。
        ///
        /// 关键点：用「文本编辑」的方式整段替换，而不是 `textView.string = text`。
        /// 后者是一次性重置：会清空撤销栈，并让 `NSTextInputContext` 失效——
        /// 中文输入法提交后光标会跳到串首（BUG-005）。
        func applyExternalText(_ text: String, to textView: SQLTextView) {
            isUpdatingFromSwiftUI = true
            defer { isUpdatingFromSwiftUI = false }

            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: fullRange, replacementString: text),
               let storage = textView.textStorage {
                storage.replaceCharacters(in: fullRange, with: text)
                textView.didChangeText()
            } else {
                textView.string = text
            }

            // 整段替换属于「载入 / 切换」语义，不进撤销栈，
            // 避免 ⌘Z 把页签内容换成上一次的内容。
            textView.undoManager?.removeAllActions()

            textSync.noteAppliedExternal(text)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }

        /// 延后一次高亮，避免与输入法 / 文本编辑回调重入。
        func scheduleHighlighting() {
            highlightWorkItem?.cancel()

            let item = DispatchWorkItem { [weak self] in
                self?.applyHighlighting()
            }
            highlightWorkItem = item
            DispatchQueue.main.async(execute: item)
        }

        func applyHighlighting() {
            guard let textView else { return }
            // 组字期间不重设属性（会打断输入法 / 丢 marked text）。
            guard !textView.hasMarkedText() else { return }
            guard let tokenizer = SQLEditorView.tokenizers[parent.databaseType] else { return }

            let currentText = textView.string
            if currentText == lastHighlightedText && parent.diagnostics == lastDiagnostics {
                return
            }

            let tokens = tokenizer.tokenize(currentText)
            textView.apply(
                tokens: tokens,
                diagnostics: parent.diagnostics,
                baseFont: SQLEditorView.baseFont,
                keywordFont: SQLEditorView.keywordFont
            )
            lastHighlightedText = currentText
            lastDiagnostics = parent.diagnostics
        }


        // MARK: - 补全（FR-EDIT-09）

        /// NSTextView 标准补全回调：F5 / Esc / ⌃Space 触发。
        /// 候选项来自方言层（关键字 + 内置函数，与语法高亮共用同一份定义）；
        /// **接上查询记忆后**，当前连接跑过的语句按前缀排在关键字之后（FR-AI-13 S4）。
        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange)
            let suggestions = SQLCompleter.suggestions(
                for: prefix,
                dialect: SQLDialectFactory.make(for: parent.databaseType),
                memory: parent.memoryIndex,
                connection: parent.memoryConnection
            )
            index?.pointee = suggestions.isEmpty ? -1 : 0
            return suggestions
        }

        // MARK: - 编辑菜单命令

        func perform(_ command: EditorCommand) {
            guard let textView else { return }

            switch command {
            case .showFind:
                showFindPanel(replace: false, in: textView)
            case .showReplace:
                showFindPanel(replace: true, in: textView)
            case .goToLine(let line, let column):
                goTo(line: line, column: column, in: textView)
            case .indent:
                changeIndent(add: true, in: textView)
            case .outdent:
                changeIndent(add: false, in: textView)
            case .clear:
                clear(in: textView)
            case .format:
                format(in: textView)
            case .selectNextOccurrence:
                textView.window?.makeFirstResponder(textView)
                textView.selectNextOccurrence()
            case .addCursorAbove:
                textView.window?.makeFirstResponder(textView)
                textView.addCursorAbove()
            case .addCursorBelow:
                textView.window?.makeFirstResponder(textView)
                textView.addCursorBelow()
            }
        }

        private func showFindPanel(replace: Bool, in textView: NSTextView) {
            textView.window?.makeFirstResponder(textView)
            let action: NSTextFinder.Action = replace ? .showReplaceInterface : .showFindInterface
            let item = NSMenuItem()
            item.tag = Int(action.rawValue)
            textView.performTextFinderAction(item)
        }

        private func goTo(line: Int, column: Int?, in textView: NSTextView) {
            guard line >= 1 else { return }
            let text = textView.string as NSString

            var location = 0
            var currentLine = 1
            while currentLine < line, location < text.length {
                let range = text.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(range)
                currentLine += 1
            }

            var target = min(location, text.length)
            if let column, column > 1 {
                let lineRange = text.lineRange(for: NSRange(location: target, length: 0))
                let lineEnd = max(NSMaxRange(lineRange) - 1, target)
                target = min(target + column - 1, min(lineEnd, text.length))
            }

            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: target, length: 0))
            textView.scrollRangeToVisible(NSRange(location: target, length: 0))
        }

        private func changeIndent(add: Bool, in textView: NSTextView) {
            let unit = "    "
            let text = textView.string as NSString
            let selection = textView.selectedRange()

            // 无选区：插入 / 删除光标前的缩进。
            if selection.length == 0 {
                if add {
                    textView.insertText(unit, replacementRange: selection)
                } else {
                    let start = max(0, selection.location - unit.count)
                    let length = selection.location - start
                    guard length > 0 else { return }
                    let prefix = text.substring(with: NSRange(location: start, length: length))
                    let removable = prefix.reversed().prefix(while: { $0 == " " }).count
                    guard removable > 0 else { return }
                    textView.insertText(
                        "",
                        replacementRange: NSRange(location: selection.location - removable, length: removable)
                    )
                }
                return
            }

            let lineRange = text.lineRange(for: selection)
            let block = text.substring(with: lineRange)
            let lines = block.components(separatedBy: "\n")
            var newLines: [String] = []

            for (index, line) in lines.enumerated() {
                // 选区结束处的换行会产生一个空尾段，保持原样。
                if index == lines.count - 1, line.isEmpty {
                    newLines.append(line)
                    continue
                }

                if add {
                    newLines.append(unit + line)
                } else if line.hasPrefix(unit) {
                    newLines.append(String(line.dropFirst(unit.count)))
                } else if line.hasPrefix("\t") {
                    newLines.append(String(line.dropFirst(1)))
                } else {
                    let spaces = line.prefix(while: { $0 == " " }).count
                    newLines.append(String(line.dropFirst(min(spaces, unit.count))))
                }
            }

            let replaced = newLines.joined(separator: "\n")
            textView.insertText(replaced, replacementRange: lineRange)
            textView.setSelectedRange(
                NSRange(location: lineRange.location, length: (replaced as NSString).length)
            )
        }

        private func clear(in textView: NSTextView) {
            let length = (textView.string as NSString).length
            guard length > 0 else { return }
            let fullRange = NSRange(location: 0, length: length)
            textView.setSelectedRange(fullRange)
            // 走 insertText 以保留 ⌘Z 撤销能力。
            textView.insertText("", replacementRange: fullRange)
        }

        private func format(in textView: NSTextView) {
            let current = textView.string
            let formatted = SQLFormatter(databaseType: parent.databaseType).format(current)
            guard formatted != current else { return }
            let fullRange = NSRange(location: 0, length: (current as NSString).length)
            textView.setSelectedRange(fullRange)
            textView.insertText(formatted, replacementRange: fullRange)
        }

        private var lastHighlightedText: String?
        private var lastDiagnostics: [SQLDiagnostic] = []
    }
}

/// 只做属性渲染的 NSTextView。
final class SQLTextView: NSTextView {
    private(set) var isApplyingAttributes = false
    /// ⌥ 拖拽列选择时的起始文本偏移（nil = 当前不是列选择）。
    private var columnSelectionAnchor: Int?

    /// `NSTextView.selectedRanges` 在 Swift 里是 `[NSValue]`（不是 `[NSRange]`），
    /// 而 Core 的多光标引擎按 `[NSRange]` 工作 —— 两处转换集中在这里，免得散落十几处。
    private var rangeValues: [NSRange] { selectedRanges.map(\.rangeValue) }
    private func setRangeValues(_ ranges: [NSRange]) {
        selectedRanges = ranges.map { NSValue(range: $0) }
    }

    /// 补全使用「SQL 标识符」范围：字母、数字、下划线，
    /// 这样 `my_table` 这类名字不会被系统按标点切成两段。
    override var rangeForUserCompletion: NSRange {
        let text = string as NSString
        let selection = selectedRange()
        var location = min(selection.location, text.length)
        var length = 0

        while location > 0 {
            let character = text.character(at: location - 1)
            guard let scalar = UnicodeScalar(character),
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "_" else {
                break
            }
            location -= 1
            length += 1
        }

        return NSRange(location: location, length: length)
    }

    /// ⌃Space 主动唤出补全（系统默认只有 F5 / Esc）；⌥⌘ 系列是多光标操作（FR-EDIT-27）。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.contains(.control) {
            complete(nil)
            return
        }
        // Esc：**收敛多光标**。这是"我怎么会一次插两行"的出口 ——
        // 需求提出者实测踩到过：有个多余光标在同时打字，而它没被画出来（见 `drawInsertionPoint`）。
        if event.keyCode == 53, selectedRanges.count > 1 {
            setRangeValues([selectedRange()])
            needsDisplay = true
            return
        }
        if event.modifierFlags.contains([.command, .option]) {
            switch event.charactersIgnoringModifiers {
            case "d":
                selectNextOccurrence()
                return
            case "\u{F700}":   // ↑
                addCursorAbove()
                return
            case "\u{F701}":   // ↓
                addCursorBelow()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - 多光标与列编辑（FR-EDIT-27）

    /// 把**次光标**也画出来。
    ///
    /// 为什么必须画：`NSTextView` 只画主光标，而零长度选区**连高亮都没有** ——
    /// 于是"其实有两个光标在同时打字"在界面上完全看不出来，用户只会觉得
    /// 「我按一下回车怎么换了两行」「我打一个字怎么出来两个」（实测反馈）。
    /// 这里的画法很朴素：在次光标位置补一个 2pt 宽的小竖条，颜色用主光标同色。
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)

        let ranges = rangeValues
        guard ranges.count > 1 else { return }
        color.setFill()
        for range in ranges.dropFirst() {
            // 有选区的那个已经由系统高亮显示，只需要补零长度光标的竖条。
            guard range.length == 0, let caret = caretRect(atCharacterIndex: range.location) else { continue }
            caret.fill()
        }
    }

    /// 某个文本偏移处的光标矩形（零长度：取该处字形位置的竖条）。
    private func caretRect(atCharacterIndex index: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let text = string as NSString
        let clamped = min(max(0, index), text.length)
        let probeIndex = clamped < text.length ? clamped : max(0, text.length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: probeIndex)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyphIndex)
        let origin = textContainerOrigin

        // 行尾（index == length）时，用最后一个字形的推进宽度把竖条挪到行尾之后。
        var x = lineRect.minX + location.x
        if clamped >= text.length, text.length > 0 {
            x = lineRect.maxX
        }
        return NSRect(
            x: origin.x + x,
            y: origin.y + lineRect.minY,
            width: 2,
            height: lineRect.height
        )
    }

    /// ⌥⌘D：选中下一处与当前选区相同的内容。
    ///
    /// **注意键位与需求原文不同**：需求写的是 ⌘D，但 ⌘D 在本产品已绑定「保存查询」
    /// （FR-EDIT-28 的快捷键表），所以这里用 ⌥⌘D，并在帮助面板登记。冲突是实测出来的，
    /// 不静默改需求 —— 已写进需求行的「仍未做 / 已知偏差」。
    func selectNextOccurrence() {
        var cursor = MultiCursor(selections: rangeValues, textLength: string.utf16.count)
        guard cursor.selectNextOccurrence(in: string) else { return }
        setRangeValues(cursor.selections)
        scrollRangeToVisible(cursor.primary)
    }

    /// ⌥⌘↑ / ⌥⌘↓：在相邻行的同列处加一个光标。
    func addCursorAbove() {
        var cursor = MultiCursor(selections: rangeValues, textLength: string.utf16.count)
        guard cursor.addCursorAbove(in: string) else { return }
        setRangeValues(cursor.selections)
    }

    func addCursorBelow() {
        var cursor = MultiCursor(selections: rangeValues, textLength: string.utf16.count)
        guard cursor.addCursorBelow(in: string) else { return }
        setRangeValues(cursor.selections)
    }

    /// 把一批编辑一次性写回去：**一次撤销**、保留输入法上下文。
    private func applyMultiCursor(_ transform: (String) -> (text: String, cursors: MultiCursor)) {
        let (newText, cursors) = transform(string)
        guard newText != string else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: newText) else { return }
        textStorage?.replaceCharacters(in: full, with: newText)
        didChangeText()
        setRangeValues(cursors.selections)
    }

    /// 多选区打字：走引擎统一应用（AppKit 对"多个选区同时输入"的行为不保证，
    /// 自己算能保证语义，也能保证**整批改动是一次撤销**）。
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? String)
            ?? (insertString as? NSAttributedString)?.string
            ?? ""
        guard selectedRanges.count > 1, !text.isEmpty else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let cursor = MultiCursor(selections: rangeValues, textLength: string.utf16.count)
        applyMultiCursor { cursor.applying(text, to: $0) }
    }

    /// 回车：多光标时**自己应用**（与打字 / 退格同一套 Core 引擎）。
    ///
    /// 为什么必须显式拦：交给 AppKit 的话行为不保证（它对"多个零长度选区"的处理是实现细节），
    /// 而且容易出现"插入了一次但撤销要按两下"。走 Core 引擎则每个光标插一个换行、整批一次撤销 ——
    /// 与打字、退格完全一致。
    override func insertNewline(_ sender: Any?) {
        guard selectedRanges.count > 1 else {
            super.insertNewline(sender)
            return
        }
        let cursor = MultiCursor(selections: rangeValues, textLength: string.utf16.count)
        applyMultiCursor { cursor.applying("\n", to: $0) }
    }

    /// 多选区退格：每个光标删一个完整字符（emoji 的代理对一起删）。
    override func deleteBackward(_ sender: Any?) {
        guard selectedRanges.count > 1 else {
            super.deleteBackward(sender)
            return
        }
        let cursor = MultiCursor(selections: rangeValues, textLength: string.utf16.count)
        applyMultiCursor { cursor.deletingBackward(in: $0) }
    }

    /// ⌥ 拖拽：列选择。
    ///
    /// 用 `characterIndexForInsertion(at:)` 把鼠标位置换算成文本偏移，再交给 Core
    /// 逐行取列（短行夹到行尾、绝不跨换行）—— 换算与语义都在 Core 里，这里只搬坐标。
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            super.mouseDown(with: event)
            return
        }
        columnSelectionAnchor = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        updateColumnSelection(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = columnSelectionAnchor else {
            super.mouseDragged(with: event)
            return
        }
        updateColumnSelection(to: event, anchor: anchor)
    }

    override func mouseUp(with event: NSEvent) {
        columnSelectionAnchor = nil
        super.mouseUp(with: event)
    }

    private func updateColumnSelection(to event: NSEvent, anchor: Int? = nil) {
        guard let anchor = anchor ?? columnSelectionAnchor else { return }
        let current = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let ranges = MultiCursor.columnSelection(in: string, from: anchor, to: current)
        setRangeValues(MultiCursor.normalized(ranges, textLength: string.utf16.count))
    }

    func apply(
        tokens: [SQLToken],
        diagnostics: [SQLDiagnostic],
        baseFont: NSFont,
        keywordFont: NSFont
    ) {
        guard let storage = textStorage else { return }

        isApplyingAttributes = true
        defer { isApplyingAttributes = false }

        let length = storage.length
        let fullRange = NSRange(location: 0, length: length)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: Theme.nsColor(TextTone.primary)
        ]

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: fullRange)

        for token in tokens {
            guard isValid(token.range, in: length) else { continue }
            let attributes = Self.attributes(for: token.kind, baseFont: baseFont, keywordFont: keywordFont)
            if !attributes.isEmpty {
                storage.addAttributes(attributes, range: token.range)
            }
        }

        for diagnostic in diagnostics {
            let range = NSRange(location: diagnostic.utf16Location, length: max(diagnostic.utf16Length, 1))
            guard isValid(range, in: length) else { continue }
            storage.addAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: diagnostic.severity == .error
                        ? Theme.nsColor(StatusTone.danger)
                        : Theme.nsColor(StatusTone.warning)
                ],
                range: range
            )
        }

        storage.endEditing()

        typingAttributes = [
            .font: baseFont,
            .foregroundColor: Theme.nsColor(TextTone.primary)
        ]
    }

    private func isValid(_ range: NSRange, in length: Int) -> Bool {
        range.location >= 0 && range.length > 0 && range.location + range.length <= length
    }

    private static func attributes(
        for kind: SQLToken.Kind,
        baseFont: NSFont,
        keywordFont: NSFont
    ) -> [NSAttributedString.Key: Any] {
        // 语法色一律走令牌（`SyntaxTone`）：深浅两套各有一份，且对比度由单测守着。
        // `quotedIdentifier` 归到 `identifier`：外观方案里标识符就是一档，
        // 引号本身已经把它和普通标识符区分开了，再给一个颜色反而更花。
        switch kind {
        case .keyword:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.keyword), .font: keywordFont]
        case .function:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.function)]
        case .string:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.string)]
        case .quotedIdentifier:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.identifier)]
        case .comment:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.comment)]
        case .number:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.number)]
        case .operatorSymbol:
            return [:]
        }
    }
}
