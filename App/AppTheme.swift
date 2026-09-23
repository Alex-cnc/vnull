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
        case icon         // 工具条上的图标（与正文同字号，但固定 medium 字重）
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

    static func categorical(_ tone: CategoricalTone) -> Color {
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
        case .icon:
            // 图标与正文同字号（13），字重固定 medium —— 这样一套工具条里的图标不会大小不一。
            return .systemFont(ofSize: TypeScale.bodySize, weight: .medium)
        }
    }

    // MARK: 强调色（AppKit 自绘视图用）
    //
    // 从 `AccentManager` 现取而不是缓存：强调色是用户可配置的，
    // 缓存下来就会出现"改了强调色但结果表的选中条还是旧的"。

    static var accentNSColor: NSColor { AccentManager.shared.accentNSColor }

    /// 强调色的 SwiftUI 形态（与根视图 `.tint` 同源）。
    static var accentColor: Color { AccentManager.shared.accentColor }

    /// 选中行的淡填充（与活动栏、侧栏同一套语言；透明度取自 `Overlay.Selection`）。
    static var accentTintNSColor: NSColor {
        AccentManager.shared.accentNSColor.withAlphaComponent(isDarkAppearance ? Overlay.Selection.darkAlpha : Overlay.Selection.lightAlpha)
    }

    /// 发丝线颜色（叠加在表面上，故用低透明度而不是不透明灰）。
    static var hairlineNSColor: NSColor {
        isDarkAppearance
            ? NSColor.white.withAlphaComponent(Hairline.darkAlpha)
            : NSColor.black.withAlphaComponent(Hairline.lightAlpha)
    }

    /// 当前绘图外观是否深色。
    static var isDarkAppearance: Bool {
        NSAppearance.current.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: 底层

    // AppKit 视图（编辑器 / 结果网格 / 终端）需要 NSColor，这里给三个语义重载。
    static func nsColor(_ surface: Surface) -> NSColor { nsColor(surface.color) }
    static func nsColor(_ tone: TextTone) -> NSColor { nsColor(tone.color) }
    static func nsColor(_ tone: SyntaxTone) -> NSColor { nsColor(tone.color) }
    static func nsColor(_ tone: StatusTone) -> NSColor { nsColor(tone.color) }

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

/// 发丝线视图：**替代系统 `Divider()`**（名字带 View 是为了不与 `Core.Hairline` 的透明度令牌重名）。
///
/// 系统分隔线在深浅两套外观下各是一个固定灰，与我们的表面令牌不总是一致；
/// 而"分隔"这件事在整个界面里出现几十次，差一点点就很显眼。
/// 用 1 物理像素 + 低透明度叠加在任意表面上都成立。
struct HairlineView: View {

    var vertical: Bool = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Theme.hairline(scheme))
            .frame(
                width: vertical ? Metrics.hairline : nil,
                height: vertical ? nil : Metrics.hairline
            )
    }
}
