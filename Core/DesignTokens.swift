import Foundation

// MARK: - 设计令牌（FR-EDIT-33 的落地底座）
//
// 这一层存在的理由，是量出来的：改造前 App/ 里
//   · 显式字号只有 3 个（14 / 15 / 9），其余全靠默认 `.body` → 没有排版级差；
//   · padding 值里 `2` 出现 139 次，还混着 1 / 3 / 6 / 10 / 12 / 20 / 150 → 没有刻度；
//   · 颜色是零散的系统色 + 裸 `Color.orange/.red/.blue` → 同一种"警告橙"在不同面板里不是同一个橙。
//
// 所以令牌层做三件事：**刻度化、语义化、可校验**。
// 它只放纯数据（十六进制 + 数值），平台绑定（NSColor / Font / Color）在 App/AppTheme.swift ——
// 这样 Core 不 import AppKit，而全部数值都能单测（`DesignTokensTests`）。
//
// **用法规矩（很重要，写在这里免得日后走样）**
//   1. 间距只用 `Spacing` 里的值；确需 1pt 像素微调时用 `Metrics.hairline`，不要新造数字。
//   2. 表面层次靠**明度差 + 发丝线**，不靠描边：`window < sidebar/content/panel < raised`（深色由暗到亮）。
//   3. 浅色主题下 `raised` 与 `content` 同为白色，**浮层必须靠外加发丝线或阴影**才能看出来；
//      因此"页签条 / 分段控件的轨道"要用 `panel`，选中块才用 `raised` ——
//      两者都铺在 `content` 上时，选中块是看不见的（这是浅色界面最常见的一处走样）。
//   4. 强调色**不在这一层**：它由用户配置（`AccentTheme`），只在选中态 / 主按钮 / 焦点环出现。

/// 间距刻度（4 / 8 网格；`hair` 是唯一的例外，用于图标与文字之间的紧贴）。
public enum Spacing {
    public static let hair: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32

    /// 允许出现的全部取值 —— 校验脚本按它判断"裸数字"。
    public static let scale: [CGFloat] = [hair, xs, s, m, l, xl, xxl]

    public static func isOnScale(_ value: CGFloat) -> Bool {
        scale.contains(value)
    }
}

/// 圆角刻度。
public enum Radius {
    /// 发丝级圆角：给 2pt 强调条这类"线"用（线的圆角只能是线宽的一半）。
    public static let hairline: CGFloat = 1
    public static let badge: CGFloat = 4
    public static let control: CGFloat = 6
    public static let card: CGFloat = 8
    public static let panel: CGFloat = 10

    public static let scale: [CGFloat] = [hairline, badge, control, card, panel]
}

/// 度量：尺寸类常量。
public enum Metrics {
    /// 发丝线（1 物理像素 @2x）。
    public static let hairline: CGFloat = 0.5
    /// 标签 / 列表 / 表格行高 —— "紧凑但留白严格"的具体含义。
    public static let rowHeight: CGFloat = 26
    public static let listRowHeight: CGFloat = 26
    public static let tabHeight: CGFloat = 30
    public static let toolbarHeight: CGFloat = 44
    public static let statusBarHeight: CGFloat = 24
    public static let controlHeight: CGFloat = 26
    /// 侧栏宽度（对象树 / 工作区）。
    public static let sidebarWidth: CGFloat = 248
    /// 最左侧活动栏宽度（FR-EDIT-32）。
    public static let activityBarWidth: CGFloat = 46
    /// 活动栏图标边长。
    public static let activityIconSize: CGFloat = 20
}

// MARK: - 颜色语义

/// 一个颜色在两套主题下的取值（十六进制）。
public struct ThemeColor: Equatable, Sendable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    public func hex(dark isDark: Bool) -> UInt32 { isDark ? dark : light }
}

/// 表面（层次由暗到亮：window → sidebar → content → panel → raised）。
///
/// 语义而不是色值：视图里写 `Surface.panel` 而不是 `#262A31`，
/// 这样换配色只改这一处，也不会出现"表头用了三个不同的灰"。
public enum Surface: String, CaseIterable, Sendable {
    case window
    case sidebar
    case content
    case panel
    case raised

    public var color: ThemeColor {
        switch self {
        case .window: return ThemeColor(light: 0xE8E8EC, dark: 0x141619)
        case .sidebar: return ThemeColor(light: 0xEDEDF2, dark: 0x17191E)
        case .content: return ThemeColor(light: 0xFFFFFF, dark: 0x1F2229)
        case .panel: return ThemeColor(light: 0xF6F6F9, dark: 0x262A31)
        case .raised: return ThemeColor(light: 0xFFFFFF, dark: 0x2F343C)
        }
    }
}

/// 文本层级。
public enum TextTone: String, CaseIterable, Sendable {
    case primary
    case secondary
    case tertiary

    public var color: ThemeColor {
        switch self {
        case .primary: return ThemeColor(light: 0x1D1D1F, dark: 0xE7E9EE)
        case .secondary: return ThemeColor(light: 0x6E6E73, dark: 0x9AA1AE)
        // 辅助信息（表头 / 行号 / 状态栏）。浅色档实测过：原来的 #9A9AA0 只有 2.80，
        // 连 3.0 的非文本门槛都不到，故压到 #7C7C82（4.15）。
        case .tertiary: return ThemeColor(light: 0x7C7C82, dark: 0x6C7380)
        }
    }
}

/// 状态色（成功 / 警告 / 危险）。
public enum StatusTone: String, CaseIterable, Sendable {
    case success
    case warning
    case danger

    public var color: ThemeColor {
        switch self {
        case .success: return ThemeColor(light: 0x1E9E5A, dark: 0x4CC38A)
        case .warning: return ThemeColor(light: 0xB9791B, dark: 0xD9A343)
        case .danger: return ThemeColor(light: 0xD03A32, dark: 0xE5534B)
        }
    }
}

/// 语法着色。
public enum SyntaxTone: String, CaseIterable, Sendable {
    case keyword
    case identifier
    case string
    case number
    case function
    case comment

    public var color: ThemeColor {
        switch self {
        case .keyword: return ThemeColor(light: 0x8B33C4, dark: 0x9BA8FF)
        case .identifier: return TextTone.primary.color
        case .string: return ThemeColor(light: 0x1E7A3C, dark: 0x9ED37A)
        case .number: return ThemeColor(light: 0xA35B00, dark: 0xE6C07B)
        case .function: return ThemeColor(light: 0x0B6E99, dark: 0x62C6C0)
        // 注释同样按"次要信息"处理：浅色档压到 #7C7C82（原 #9A9AA0 只有 2.80）。
        case .comment: return ThemeColor(light: 0x7C7C82, dark: 0x6C7380)
        }
    }
}

/// 发丝线颜色：不是固定的灰，而是"当前表面上的 1px 亮/暗线"。
public enum Hairline {
    /// 深色主题用白色低透明度、浅色主题用黑色低透明度 —— 这样在任何表面上都成立。
    public static let lightAlpha: Double = 0.09
    public static let darkAlpha: Double = 0.08
}

// MARK: - 排版级差

/// 字号与字重。
///
/// 改造前全 App 只有 3 个显式字号 —— 标题、正文、表头、辅助信息长得一样，
/// 这是"简陋"最直接的来源。这里定 6 级，够用且不臃肿。
public enum TypeScale {
    /// 窗口 / 面板主标题。
    public static let displaySize: CGFloat = 17
    /// 区块标题。
    public static let titleSize: CGFloat = 15
    public static let bodySize: CGFloat = 13
    /// 数值列（配等宽数字，保证小数点对齐）。
    public static let dataSize: CGFloat = 12
    public static let monoSize: CGFloat = 12
    public static let monoSmallSize: CGFloat = 11
    public static let captionSize: CGFloat = 11

    /// 允许出现的字号（去重后的刻度）—— 校验脚本按它判断"裸字号"。
    ///
    /// 注意：`dataSize` 与 `monoSize` 是同一个字号（12）但语义不同（数值列 / 代码），
    /// 所以命名常量比刻度多 —— 由 `DesignTokensTests` 保证"每个命名常量都在刻度上"。
    public static let scale: [CGFloat] = [11, 12, 13, 15, 17]

    public static func isOnScale(_ size: CGFloat) -> Bool {
        scale.contains(size)
    }
}
