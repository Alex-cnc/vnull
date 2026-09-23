import Foundation

/// 颜色对比度计算（WCAG 2.1）—— **全工程唯一的一份**。
///
/// 为什么单独抽出来：强调色（`AccentTheme`）与设计令牌（`DesignTokens`）都要用它，
/// 而"两处各算一套对比度"迟早会出现两套不一致的阈值，
/// 那时候"过了 AA"就成了一句谁也不知道真假的话。
public enum ColorContrast {

    /// 把 `0xRRGGBB` 拆成 0...1 的 sRGB 分量。
    public static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// WCAG 相对亮度（0 = 黑，1 = 白）。
    public static func relativeLuminance(_ hex: UInt32) -> Double {
        let (red, green, blue) = components(hex)
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// 对比度（1...21）。白/黑为 21，同色为 1。
    public static func ratio(_ lhs: UInt32, _ rhs: UInt32) -> Double {
        let a = relativeLuminance(lhs)
        let b = relativeLuminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// 两个颜色的归一化距离（0 = 相同）—— 用来判断"两个表面是不是肉眼能分开"。
    ///
    /// 不用亮度差：两个亮度相同但色相不同的颜色仍然可以分得很开。
    public static func distance(_ lhs: UInt32, _ rhs: UInt32) -> Double {
        let a = components(lhs)
        let b = components(rhs)
        return sqrt(
            pow(a.red - b.red, 2) + pow(a.green - b.green, 2) + pow(a.blue - b.blue, 2)
        ) / sqrt(3)
    }

    /// 可访问性门槛 —— 写死在这里，免得各处在魔法数字上讨价还价。
    public enum Threshold {
        /// 正文（WCAG AA）。
        public static let bodyText = 4.5
        /// 大字号 / 次要信息。
        public static let largeText = 3.0
        /// 非文本的 UI 组件（图标、选中条、焦点环、状态点）。
        public static let component = 3.0
        /// 两个相邻表面必须能被看出来是两块（不是"相等"就行，相等等于没有层次）。
        public static let surfaceSeparation = 0.02
    }
}
