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

    @ObservedObject private var commandCenter = EditorCommandCenter.shared

    static let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let keywordFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

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
        /// 候选项来自方言层（关键字 + 内置函数），与语法高亮共用同一份定义。
        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange)
            let suggestions = SQLCompleter.suggestions(
                for: prefix,
                dialect: SQLDialectFactory.make(for: parent.databaseType)
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

    /// ⌃Space 主动唤出补全（系统默认只有 F5 / Esc）。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.contains(.control) {
            complete(nil)
            return
        }
        super.keyDown(with: event)
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
            .foregroundColor: NSColor.labelColor
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
                    .underlineColor: diagnostic.severity == .error ? NSColor.systemRed : NSColor.systemOrange
                ],
                range: range
            )
        }

        storage.endEditing()

        typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
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
        switch kind {
        case .keyword:
            return [.foregroundColor: NSColor.systemPurple, .font: keywordFont]
        case .function:
            return [.foregroundColor: NSColor.systemTeal]
        case .string:
            return [.foregroundColor: NSColor.systemRed]
        case .quotedIdentifier:
            return [.foregroundColor: NSColor.systemOrange]
        case .comment:
            return [.foregroundColor: NSColor.secondaryLabelColor]
        case .number:
            return [.foregroundColor: NSColor.systemBlue]
        case .operatorSymbol:
            return [:]
        }
    }
}
