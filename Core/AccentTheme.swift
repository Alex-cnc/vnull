import Foundation

/// 强调色主题（FR-EDIT-33）。
///
/// 放在 Core 而不是 App：这是**纯数据 + 纯函数**（解析、回退、色值换算、对比度），
/// 不打开图形界面就能单测；`NSColor` / `Color` 的绑定留在 App 层（与 `Localization` 同构）。
///
/// **为什么每个强调色有两个色值**（这不是冗余，是实测出来的）：
/// - `accent` 用于「选中行淡填充 / 左侧强调条 / 图标 / 焦点环」——它是跟**表面**比，
///   门槛是 WCAG 对 UI 组件的 3.0；
/// - `fill` 用于**实心按钮**，上面压白字 —— 门槛是正文的 4.5。
///
/// 同一个亮度做不到两件事都合格：实测 `#4E6FFF` 上白字只有 **4.17**、`#17A2A2` 只有 **3.12**
/// （都不够 4.5），所以 `fill` 是压暗过的那一档。这条由 `AccentThemeTests` 守着。
public struct AccentTheme: Equatable, Sendable, Identifiable {

    /// 持久化用的稳定标识 —— **不随界面语言变化**（否则切一次语言就把用户的选择丢了）。
    public let id: String
    /// 显示名的文案键。
    public let nameKey: LKey
    /// 主色：选中条 / 图标 / 焦点环 / 淡填充底色。
    public let accentHex: UInt32
    /// 实心填充（压白字，必须过 WCAG AA 4.5）。
    public let fillHex: UInt32

    public init(id: String, nameKey: LKey, accentHex: UInt32, fillHex: UInt32) {
        self.id = id
        self.nameKey = nameKey
        self.accentHex = accentHex
        self.fillHex = fillHex
    }

    // MARK: 三个候选
    //
    // 其中两个取自 dsh-tui 鲸鱼自身的调色板（在其源码里量到的 B 与心形 H）：
    // 这样"品牌色"与用户每天看到的那个 TUI 是同源的，而不是我另外挑的。

    /// 鲸鱼蓝（`B[78,111,255]`）。
    public static let whaleBlue = AccentTheme(
        id: "whale-blue",
        nameKey: .accentWhaleBlue,
        accentHex: 0x4E6FFF,
        fillHex: 0x3B57E0
    )

    /// 深海青 —— 与红 / 橙告警区分度最大。
    public static let deepTeal = AccentTheme(
        id: "deep-teal",
        nameKey: .accentDeepTeal,
        accentHex: 0x17A2A2,
        fillHex: 0x0F7F7F
    )

    /// 鲸心品红（心形 `H[204,51,153]`）。
    public static let whaleMagenta = AccentTheme(
        id: "whale-magenta",
        nameKey: .accentWhaleMagenta,
        accentHex: 0xCC3399,
        fillHex: 0xB02A83
    )

    public static let all: [AccentTheme] = [whaleBlue, deepTeal, whaleMagenta]

    /// 默认与回退都是鲸鱼蓝（与 App 图标同系）。
    public static let fallback = AccentTheme.whaleBlue

    /// 由持久化的 id 解析；**未知 id 一律回退而不是报错** ——
    /// 配置文件被手改、或将来删掉某个候选时，界面都必须照常起来。
    public static func resolve(id: String?) -> AccentTheme {
        guard let id, !id.isEmpty else { return fallback }
        return all.first { $0.id == id } ?? fallback
    }

    /// 偏好设置里的存储键（与工程内其它 UI 偏好同一套 `ui.` 前缀）。
    public enum Storage {
        public static let key = "ui.accentTheme"
    }

    // MARK: 色值与对比度（纯函数，便于单测）

    /// 把 `0xRRGGBB` 拆成 0...1 的分量。
    public static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// WCAG 相对亮度。
    public static func relativeLuminance(_ hex: UInt32) -> Double {
        let (red, green, blue) = components(hex)
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 对比度（1...21）。
    public static func contrastRatio(_ lhs: UInt32, _ rhs: UInt32) -> Double {
        let a = relativeLuminance(lhs)
        let b = relativeLuminance(rhs)
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
