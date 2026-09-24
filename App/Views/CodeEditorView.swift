import SwiftUI
import AppKit
import DoyahCore

/// 工作区的**代码编辑器**（FR-EDIT-36）：按语言着色 + 补全 + ⌘S 保存。
///
/// 与 SQL 编辑器（`SQLEditorView`）的关系：**同一个套路、不同的语言层**。
/// SQL 编辑器那套多光标 / 列选择 / 诊断下划线是 SQL 专用能力，这里不搬过来
/// （工作区编辑器的第一版目标是"能读能改能存"，把功能堆满反而不好验）。
struct CodeEditorView: NSViewRepresentable {
    let tabID: UUID
    let text: String
    let language: TextLanguage
    var onTextChange: (String) -> Void
    var onSave: () -> Void

    /// 订阅字体偏好：偏好一变，SwiftUI 重跑 `updateNSView` → 编辑器换字体。
    @ObservedObject private var fonts = FontManager.shared

    static var baseFont: NSFont { Theme.nsFont(.mono) }
    static var keywordFont: NSFont {
        FontManager.shared.monospaceBoldNSFont(size: Theme.nsFont(.mono).pointSize)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = Self.baseFont
        textView.textColor = Theme.nsColor(TextTone.primary)
        textView.backgroundColor = Theme.nsColor(Surface.content)
        textView.insertionPointColor = Theme.nsColor(TextTone.primary)
        textView.drawsBackground = true
        // 代码里不要"智能"替换：把 `"` 换成 `"`、把 `--` 换成 `—` 会直接改坏代码。
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
        textView.onSave = onSave

        context.coordinator.textView = textView
        context.coordinator.language = language
        textView.completionLanguage = language
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
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        context.coordinator.parent = self
        textView.onSave = onSave
        let fontChanged = textView.font?.fontName != Self.baseFont.fontName
            || textView.font?.pointSize != Self.baseFont.pointSize
        if fontChanged {
            textView.font = Self.baseFont
        }
        // 切页签 / 外部改了内容：把文本同步过去（带上语言变化一起重着色）。
        let languageChanged = context.coordinator.language != language
        context.coordinator.language = language
        textView.completionLanguage = language
        if textView.string != text {
            context.coordinator.isApplyingExternalText = true
            textView.string = text
            context.coordinator.isApplyingExternalText = false
            context.coordinator.lastHighlightedText = nil
        }
        if fontChanged || languageChanged || context.coordinator.lastHighlightedText != textView.string {
            context.coordinator.applyHighlighting()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        var language: TextLanguage
        weak var textView: CodeTextView?
        var lastHighlightedText: String?
        var isApplyingExternalText = false
        private var highlightWorkItem: DispatchWorkItem?

        init(_ parent: CodeEditorView) {
            self.parent = parent
            self.language = parent.language
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !isApplyingExternalText else { return }
            parent.onTextChange(textView.string)
            scheduleHighlighting()
        }

        /// 延后一次高亮：避免与输入法 / 文本编辑回调重入。
        func scheduleHighlighting() {
            highlightWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.applyHighlighting() }
            highlightWorkItem = item
            DispatchQueue.main.async(execute: item)
        }

        func applyHighlighting() {
            guard let textView else { return }
            // 组字期间不重设属性（会打断输入法、丢 marked text）。这条是从 SQL 编辑器学来的。
            guard !textView.hasMarkedText() else { return }
            let current = textView.string
            guard lastHighlightedText != current else { return }

            let tokens = CodeLexer.tokens(in: current, language: language)
            textView.apply(tokens: tokens, language: language)
            lastHighlightedText = current
        }

        // MARK: 补全（FR-EDIT-36）

        /// `NSTextView` 标准补全回调：⌃Space / F5 触发。
        /// 候选项来自**同一份** `CodeSyntax`（与着色共用），再加当前文档里的标识符。
        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange)
            let items = CodeCompletion.suggestions(
                prefix: prefix,
                language: language,
                documentWords: CodeCompletion.words(in: textView.string, language: language)
            )
            index?.pointee = items.isEmpty ? -1 : 0
            return items.map(\.insertText)
        }
    }
}

/// 代码编辑器用的 `NSTextView`：只多做一件事 —— **把 ⌘S 交出去**。
///
/// 为什么在这里拦：`NSTextView` 不处理保存（那是应用级动作），而 SwiftUI 侧的
/// `.keyboardShortcut` 在文本视图获得焦点时收不到这个按键。拦在这里最稳。
final class CodeTextView: NSTextView {
    var onSave: (() -> Void)?

    /// 补全落光标用：插入的是哪个语言，决定片段插入后的落点约定。
    var completionLanguage: TextLanguage = .plainText

    /// 补全**自己插**，不交给 `NSTextView` 默认实现。
    ///
    /// 为什么：默认实现把候选原样塞进去、光标留在末尾。对多行片段（`function name() {\n  \n}`）
    /// 与带括号的片段（`console.log()`）那都不对 —— 用户的下一步是"在括号里 / 空行里继续写"。
    /// 落点约定在 Core（`CodeCompletion.caretOffset`，有单测），这里只负责搬。
    override func insertCompletion(
        _ word: String,
        forPartialWordRange charRange: NSRange,
        movement: Int,
        isFinal flag: Bool
    ) {
        guard flag, let storage = textStorage else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
            return
        }
        let characters = Array(word)
        let offset = min(max(0, CodeCompletion.caretOffset(inInsertText: word)), characters.count)
        let prefix = String(characters[0..<offset])

        let replacement = NSRange(location: charRange.location, length: charRange.length)
        guard shouldChangeText(in: replacement, replacementString: word) else { return }
        storage.replaceCharacters(in: replacement, with: word)
        didChangeText()

        // 注意：`caretOffset` 数的是**字符**，而 `NSRange` 数的是 UTF-16 单元 —— 中文注释里插入
        // 片段时两者会差，所以按前缀的 utf16 长度换算（片段里出现宽字符时不换算就会偏到别处）。
        let caret = replacement.location + prefix.utf16.count
        setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        scrollRangeToVisible(NSRange(location: caret, length: 0))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 把记号涂上去。基色与字体先铺满，再逐段覆盖 —— 与 SQL 编辑器同一手法。
    func apply(tokens: [CodeToken], language: TextLanguage) {
        guard let storage = textStorage else { return }
        let length = storage.length
        let baseFont = CodeEditorView.baseFont
        let keywordFont = CodeEditorView.keywordFont

        storage.beginEditing()
        storage.setAttributes(
            [.font: baseFont, .foregroundColor: Theme.nsColor(TextTone.primary)],
            range: NSRange(location: 0, length: length)
        )
        for token in tokens where token.kind.isHighlighted {
            let range = NSRange(token.range, in: string)
            guard range.location >= 0, range.length > 0, range.location + range.length <= length else { continue }
            let attributes = Self.attributes(for: token.kind, keywordFont: keywordFont)
            if !attributes.isEmpty {
                storage.addAttributes(attributes, range: range)
            }
        }
        storage.endEditing()
        typingAttributes = [
            .font: baseFont,
            .foregroundColor: Theme.nsColor(TextTone.primary)
        ]
    }

    private static func attributes(
        for kind: CodeToken.Kind,
        keywordFont: NSFont
    ) -> [NSAttributedString.Key: Any] {
        // 颜色一律走 `SyntaxTone` 令牌（深浅两套各一份，对比度由单测守着）——
        // 与 SQL 编辑器共用同一套语法色，两个编辑器里的"关键字"才是同一个绿。
        switch kind {
        case .keyword, .tag:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.keyword), .font: keywordFont]
        case .builtin:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.function)]
        case .string:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.string)]
        case .comment:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.comment)]
        case .number:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.number)]
        case .attribute:
            return [.foregroundColor: Theme.nsColor(SyntaxTone.identifier)]
        case .identifier, .punctuation:
            return [:]
        }
    }
}
