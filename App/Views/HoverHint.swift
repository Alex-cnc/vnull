import SwiftUI
import DoyahCore

/// **即时**悬停提示（替代系统 tooltip）。
///
/// 为什么不用 `.help`：系统 tooltip 的首次延迟是**秒级**的，实测反馈「悬停响应的时间太长了，
/// 应该是鼠标悬停即时弹出，我等了好几秒还以为没反应」。对"看一眼就走"的信息来说，
/// 即时出现才是这类提示的全部价值 —— 慢半拍就等于没有。
///
/// 做法：`onHover` + 一个画在**同一窗口内**的小面板（不是系统 tooltip 窗口）：
/// 立刻出现、移开即消失、`allowsHitTesting(false)` 不挡鼠标、位置贴在宿主下方右对齐。
private struct HoverHintModifier: ViewModifier {
    let text: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .overlay(alignment: .topTrailing) {
                if isHovering, !text.isEmpty {
                    Text(text)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.primary))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.control)
                                .fill(Theme.surface(.raised))
                                .shadow(color: .black.opacity(HintStyle.shadowAlpha), radius: HintStyle.shadowRadius, y: HintStyle.shadowOffsetY)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control)
                                .strokeBorder(Theme.text(.tertiary).opacity(HintStyle.borderAlpha))
                        )
                        // 让开宿主自身（宿主大约一行高），否则提示会盖住鼠标。
                        .offset(y: HintStyle.offsetY)
                        .allowsHitTesting(false)
                        .zIndex(1)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: HintStyle.fadeDuration), value: isHovering)
    }
}

/// 提示框的几个与"内容无关"的度量（集中放，便于统一调）。
private enum HintStyle {
    static let offsetY: CGFloat = 22
    static let fadeDuration: Double = 0.08
    static let shadowAlpha: Double = 0.18
    static let shadowRadius: CGFloat = 4
    static let shadowOffsetY: CGFloat = 2
    static let borderAlpha: Double = 0.25
}

extension View {
    /// 即时悬停提示（见 `HoverHintModifier`）。传空串则不显示。
    func hoverHint(_ text: String) -> some View {
        modifier(HoverHintModifier(text: text))
    }
}
