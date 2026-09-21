import Foundation

/// 编辑器文本 ↔ SwiftUI 绑定的同步判定（纯逻辑，便于单测）。
///
/// 背景（缺陷 BUG-005）：中文等输入法在组字（marked text）期间，`NSTextView` 的
/// `textDidChange` 会把**尚未提交**的文本写进绑定；SwiftUI 随后回写时若整段替换
/// `textView.string`，会连同输入上下文（input context）与光标一起重置，
/// 表现为「回车提交中文后，再输入的英文字符被插到串首」。
///
/// 判定规则（`updateNSView` 每次调用一次 `evaluateUpdate`）：
/// 1. 组字期间（`hasMarkedText == true`）**绝不**回写编辑器；
/// 2. 绑定值与编辑器当前内容相同 → 无需回写；
/// 3. 绑定值等于「最近一次由编辑器发布的内容」→ 是编辑器自己产生的变化，不回写；
/// 4. 绑定值与「上一次渲染观察到的绑定值」相同 → 绑定没有新变化（可能是滞后的渲染），不回写；
/// 5. 其余情况视为真正的外部改动（载入文件 / 切换页签 / 载入已保存查询）才回写。
///
/// 已知取舍：若外部改动写入的值恰好等于上一次观察到的绑定值（即绑定经历 A → B → A），
/// 会被规则 4 判为「无新变化」而跳过。该场景概率极低，且后果只是编辑器保留当前内容，
/// 用户重新载入即可。
public struct EditorTextSync: Sendable, Equatable {
    /// 最近一次由编辑器发布给绑定的文本。
    public private(set) var lastPublishedText: String
    /// 上一次渲染时观察到的绑定值。
    public private(set) var lastObservedBindingText: String

    public init(
        lastPublishedText: String = "",
        lastObservedBindingText: String = ""
    ) {
        self.lastPublishedText = lastPublishedText
        self.lastObservedBindingText = lastObservedBindingText
    }

    /// 编辑器内容变化（含输入法组字）后记录「已发布」文本。
    public mutating func notePublished(_ text: String) {
        lastPublishedText = text
    }

    /// 外部改动已写回编辑器后调用：把新内容记为已发布 / 已观察，避免重复回写。
    public mutating func noteAppliedExternal(_ text: String) {
        lastPublishedText = text
        lastObservedBindingText = text
    }

    /// `updateNSView` 每次调用一次：返回是否需要回写编辑器，并记录本次绑定值。
    public mutating func evaluateUpdate(
        _ text: String,
        editorText: String,
        hasMarkedText: Bool
    ) -> Bool {
        let shouldApply = shouldApplyExternal(
            text,
            editorText: editorText,
            hasMarkedText: hasMarkedText
        )
        lastObservedBindingText = text
        return shouldApply
    }

    /// 纯判定（不改变状态），便于阅读与单测。
    public func shouldApplyExternal(
        _ text: String,
        editorText: String,
        hasMarkedText: Bool
    ) -> Bool {
        if hasMarkedText { return false }
        if text == editorText { return false }
        if text == lastPublishedText { return false }
        if text == lastObservedBindingText { return false }
        return true
    }
}
