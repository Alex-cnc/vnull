import AppKit
import DoyahCore
import SwiftUI

/// 设计令牌的**平台绑定**：把 `Core/DesignTokens` 的纯数据换成 AppKit / SwiftUI 的类型。
///
/// 为什么分两层：Core 不 import AppKit（NFR-MAINT-02 / DR-03），
/// 所以"色值与数值"留在 Core（可单测），"NSColor / Color / Font"在这里。
/// 颜色一律解析成**动态色**（跟随系统外观），视图里不必自己判断深浅色。
enum Theme {

    // MARK: 语义字体

    /// 排版级差里的角色 —— 视图里写 `Theme.font(.body)`，不写 `size: 13`。
    enum TextStyle: String, CaseIterable {
        case display      // 窗口 / 面板主标题
        case title        // 区块标题
        case body
        case bodyStrong
        case data         // 数值列（等宽数字，小数点对齐）
        case mono         // 代码 / 终端
        case monoSmall    // 行号 / 小代码
        case caption      // 表头 / 状态栏
    }

    // MARK: 颜色

    static func surface(_ surface: Surface) -> Color {
        Color(nsColor: nsColor(surface.color))
    }

    static func text(_ tone: TextTone) -> Color {
        Color(nsColor: nsColor(tone.color))
    }

    static func status(_ tone: StatusTone) -> Color {
        Color(nsColor: nsColor(tone.color))
    }

    static func syntax(_ tone: SyntaxTone) -> Color {
        Color(nsColor: nsColor(tone.color))
    }

    /// 发丝线：不是固定的灰，而是"当前外观下的 1px 亮/暗线"。
    ///
    /// 做法上它必须叠加在已有表面上，所以用低透明度而不是不透明色 ——
    /// 这样在 content / panel / sidebar 上都成立，不需要为每个表面各配一条线。
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(Hairline.darkAlpha)
            : Color.black.opacity(Hairline.lightAlpha)
    }

    // MARK: 字体

    static func font(_ style: TextStyle) -> Font {
        let font = nsFont(style)
        return Font(font)
    }

    static func nsFont(_ style: TextStyle) -> NSFont {
        switch style {
        case .display:
            return .systemFont(ofSize: TypeScale.displaySize, weight: .semibold)
        case .title:
            return .systemFont(ofSize: TypeScale.titleSize, weight: .semibold)
        case .body:
            return .systemFont(ofSize: TypeScale.bodySize, weight: .regular)
        case .bodyStrong:
            return .systemFont(ofSize: TypeScale.bodySize, weight: .semibold)
        case .data:
            return .monospacedDigitSystemFont(ofSize: TypeScale.dataSize, weight: .regular)
        case .mono:
            return .monospacedSystemFont(ofSize: TypeScale.monoSize, weight: .regular)
        case .monoSmall:
            return .monospacedSystemFont(ofSize: TypeScale.monoSmallSize, weight: .regular)
        case .caption:
            return .systemFont(ofSize: TypeScale.captionSize, weight: .medium)
        }
    }

    // MARK: 底层

    /// 把一个令牌色解析成动态 `NSColor`（自动跟随系统外观）。
    static func nsColor(_ color: ThemeColor) -> NSColor {
        let light = Self.nsColor(hex: color.light)
        let dark = Self.nsColor(hex: color.dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// 直接由十六进制构造动态色（强调色用得到）。
    static func nsColor(hex: UInt32) -> NSColor {
        let (red, green, blue) = ColorContrast.components(hex)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
