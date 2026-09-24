import Foundation

/// 终端调色板（FR-EDIT-29 的配色层）。
///
/// ## 为什么要有这一层
///
/// 终端颜色以前是**视图里的 16 个裸 `NSColor(calibratedRed:…)`**：换主题不会跟着动、
/// 深浅两种外观共用同一套（浅色下"亮黄"几乎看不见）、也没有任何东西守着"可读"。
/// 现在它是一份**纯数据 + 纯函数**：深 / 浅两套各 16 个 ANSI 色，加上背景 / 前景 /
/// 光标 / 选中底；对比度与可区分性有单测门槛（`TerminalPaletteTests`）守着。
///
/// ## 配色口径（两条硬约束 + 一条设计取向）
///
/// 1. **可读**：色板里当正文的槽位对背景的 WCAG 对比度 ≥ 4.5；前景对背景 ≥ 7（AAA）。
///    例外只有四个"背景槽"：深色档的 0 / 8（黑与亮黑）与浅色档的 7 / 15（白与亮白）——
///    它们天生就是拿来当背景的，标准终端里也一样（浅色主题的"白"就是白）。
///    对这些槽位我们换一条要求：**与背景的 ΔE ≥ 8**（当作背景时看得出边界）。
/// 2. **可区分**：不同色相之间 ΔE ≥ 25（红不是橙、青不是蓝）；同一色相的"常规 / 亮"
///    两档 ΔE ≥ 8（看得出是更艳的一档，而不是另一个颜色）。
/// 3. **设计取向**：底色取app 深色窗体的近邻（`#14171E`）而不是纯黑 —— 纯黑在深色界面里
///    会像一块洞；浅色档取 `#FBFBFD`（比纯白低一档，久看不刺眼）。蓝 / 青 / 品红三槽
///    与产品的强调色（鲸鱼蓝 / 深海青 / 鲸心品红）同族，终端因此像"这个 App 的一部分"。
///
/// ## 与真实终端的一致性
///
/// ANSI 序号语义**不许改**（1 必须是红、4 必须是蓝），因为颜色是**程序**在用的：
/// `ls` 认为它是蓝的目录、测试框架认为它是红的失败。我们只决定"红是哪一种红"。
public struct TerminalPalette: Equatable, Sendable {

    /// 一个 8 位 RGB 色（放 Core 是为了不 import AppKit，且能直接算对比度）。
    public struct RGB: Equatable, Hashable, Sendable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public init(hex: UInt32) {
            self.red = UInt8((hex >> 16) & 0xFF)
            self.green = UInt8((hex >> 8) & 0xFF)
            self.blue = UInt8(hex & 0xFF)
        }

        public var hex: UInt32 {
            (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
        }

        /// `#1A2B3C`（文档与脚本用）。
        public var hexString: String {
            String(format: "#%06X", hex)
        }
    }

    /// 色板的可读名字（界面上不显示，用于文档 / 排障输出）。
    public var name: String
    /// 这是深色档还是浅色档。
    public var isDark: Bool
    public var background: RGB
    public var foreground: RGB
    public var cursor: RGB
    /// 选中区域的底色（不透明，避免与半透明叠加后又算出别的对比度）。
    public var selectionBackground: RGB
    /// 16 个 ANSI 槽位：0…7 常规，8…15 亮色。
    public var ansi: [RGB]

    public init(
        name: String,
        isDark: Bool,
        background: RGB,
        foreground: RGB,
        cursor: RGB,
        selectionBackground: RGB,
        ansi: [RGB]
    ) {
        self.name = name
        self.isDark = isDark
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.ansi = ansi
    }

    // MARK: - 两套色板

    /// 深色档「深海·夜」。
    ///
    /// 底色 `#14171E` 紧贴 app 深色窗体的 `#141619`，但带一点点蓝 —— 铺在界面里像"更深的一层"，
    /// 而不是贴了块黑。黑槽被抬到 `#2B303C`：纯黑在深色底上是看不见的，"亮黑"才是可见的深灰。
    public static let deepSeaDark = TerminalPalette(
        name: "深海·夜",
        isDark: true,
        background: RGB(hex: 0x14171E),
        foreground: RGB(hex: 0xD6DBE4),
        cursor: RGB(hex: 0x6E8BFF),
        selectionBackground: RGB(hex: 0x24304A),
        ansi: [
            RGB(hex: 0x2B303C),  // 0 黑（抬亮，否则在深底上不可见）
            RGB(hex: 0xF0716F),  // 1 红
            RGB(hex: 0x5FC98C),  // 2 绿
            RGB(hex: 0xE3BF63),  // 3 黄
            RGB(hex: 0x6E8BFF),  // 4 蓝（与强调色鲸鱼蓝同族）
            RGB(hex: 0xD06FBF),  // 5 品红（与鲸心品红同族）
            RGB(hex: 0x4FBDBD),  // 6 青（与深海青同族）
            RGB(hex: 0xC2C8D4),  // 7 白（这个"白"是浅灰：纯白当正文太刺眼）
            RGB(hex: 0x5A6272),  // 8 亮黑
            RGB(hex: 0xFF8D8A),  // 9 亮红
            RGB(hex: 0x86E0A8),  // 10 亮绿
            RGB(hex: 0xF3D98C),  // 11 亮黄
            RGB(hex: 0x9DB4FF),  // 12 亮蓝
            RGB(hex: 0xE795CB),  // 13 亮品红
            RGB(hex: 0x7FDCDC),  // 14 亮青
            RGB(hex: 0xF0F3F8)   // 15 亮白
        ]
    )

    /// 浅色档「深海·昼」。
    ///
    /// 底色 `#FBFBFD` 比纯白低一档。**浅色档的难点是黄与青**：同样的色相在近白底上要压到
    /// 4.5 对比度就必然偏暗，于是"亮黄"只能拿到 ΔE 8（仍在门槛内，但这是这一档的**已知最紧的一处**，
    /// 单测里单独标注了）。白槽 `#E7E9EF` 按行业惯例保持"白"（当背景用），不参与 4.5 门槛。
    public static let deepSeaLight = TerminalPalette(
        name: "深海·昼",
        isDark: false,
        background: RGB(hex: 0xFBFBFD),
        foreground: RGB(hex: 0x23252C),
        cursor: RGB(hex: 0x2F55D4),
        selectionBackground: RGB(hex: 0xD8E3FF),
        ansi: [
            RGB(hex: 0x3B404C),  // 0 黑
            RGB(hex: 0xB23327),  // 1 红
            RGB(hex: 0x146B47),  // 2 绿
            RGB(hex: 0x7E5500),  // 3 黄（近白底上的黄必须压成暗金，否则不可读）
            RGB(hex: 0x2F55D4),  // 4 蓝
            RGB(hex: 0x9C2C86),  // 5 品红
            RGB(hex: 0x0A6370),  // 6 青
            RGB(hex: 0xE7E9EF),  // 7 白（浅色档里它是**背景槽**）
            RGB(hex: 0x5C6270),  // 8 亮黑
            RGB(hex: 0xC01A19),  // 9 亮红
            RGB(hex: 0x00703A),  // 10 亮绿
            RGB(hex: 0x926200),  // 11 亮黄
            RGB(hex: 0x0053EF),  // 12 亮蓝
            RGB(hex: 0xA9098F),  // 13 亮品红
            RGB(hex: 0x0E7F8A),  // 14 亮青
            RGB(hex: 0xFFFFFF)   // 15 亮白（同上：背景槽）
        ]
    )

    /// 按外观取色板。
    public static func standard(dark: Bool) -> TerminalPalette {
        dark ? .deepSeaDark : .deepSeaLight
    }

    /// 哪些槽位是"背景槽"（不参与 4.5 的正文对比度门槛）。
    ///
    /// 深色档是黑与亮黑，浅色档是白与亮白 —— 与真实终端的惯例一致：这四个槽位
    /// 主要被程序当**背景**用（`ls` 的目录底色、`diff` 的增删底色）。
    public static func isBackgroundSlot(index: Int, isDark: Bool) -> Bool {
        isDark ? (index == 0 || index == 8) : (index == 7 || index == 15)
    }

    /// 粗体是否顺带用亮色（xterm 的老习惯）。
    ///
    /// 保留这个行为是有意的：很多 CLI（`ls --color`、`grep --color`）只发 `1;3x`
    /// 来表示"强调"，不认它就是一片同色的粗体。做成常量便于日后按需关掉。
    public static let brightensBold = true

    // MARK: - 解析

    /// 16 槽位取色。
    public func color(index: Int) -> RGB? {
        guard ansi.indices.contains(index) else { return nil }
        return ansi[index]
    }

    /// 把一个 `TerminalColor` 解成实际颜色。
    ///
    /// 256 色与真彩色按 xterm 标准：`16…231` 是 6×6×6 立方（步长 0/95/135/175/215/255），
    /// `232…255` 是 8…238 的灰阶（步长 10）。
    public func resolve(_ color: TerminalColor) -> RGB {
        switch color {
        case .default:
            return foreground
        case .rgb(let red, let green, let blue):
            return RGB(red: red, green: green, blue: blue)
        case .indexed(let value):
            let index = Int(value)
            if let slot = self.color(index: index) { return slot }
            if index >= 16, index <= 231 {
                let offset = index - 16
                let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
                return RGB(
                    red: levels[offset / 36],
                    green: levels[(offset % 36) / 6],
                    blue: levels[offset % 6]
                )
            }
            let level = UInt8(clamping: 8 + (index - 232) * 10)
            return RGB(red: level, green: level, blue: level)
        }
    }

    /// 一格文字最终用的前景色（把粗体 / 反显 / 暗淡都算进去）。
    ///
    /// 顺序有讲究：先定"本来是什么色"，再算粗体提亮，最后做反显交换 ——
    /// 反过来会把"反显后的背景"也提亮，得到一张与程序预期不符的脸。
    public func resolvedForeground(for cell: TerminalCell) -> RGB {
        var color = baseForeground(for: cell)
        if Self.brightensBold, cell.bold {
            color = brightened(color, original: cell.foreground)
        }
        if cell.isDim {
            color = dimmed(color)
        }
        if cell.inverse {
            // 反显：前景用"本来的背景"（没有显式背景时就是终端底色），
            // 背景用"本来的前景"。
            return baseBackground(for: cell) ?? background
        }
        return color
    }

    /// 一格文字最终用的背景色；`nil` 表示"就是调色板背景"（不必铺底）。
    public func resolvedBackground(for cell: TerminalCell) -> RGB? {
        if cell.inverse {
            return resolvedForegroundWithoutInverse(for: cell)
        }
        return baseBackground(for: cell)
    }

    private func baseForeground(for cell: TerminalCell) -> RGB {
        switch cell.foreground {
        case .default: return foreground
        default: return resolve(cell.foreground)
        }
    }

    private func baseBackground(for cell: TerminalCell) -> RGB? {
        switch cell.background {
        case .default: return background
        default: return resolve(cell.background)
        }
    }

    private func resolvedForegroundWithoutInverse(for cell: TerminalCell) -> RGB {
        var color = baseForeground(for: cell)
        if Self.brightensBold, cell.bold {
            color = brightened(color, original: cell.foreground)
        }
        if cell.isDim {
            color = dimmed(color)
        }
        return color
    }

    /// 粗体提亮：**只对 0…7 的索引色**生效（真彩色与亮色原样）。
    private func brightened(_ color: RGB, original: TerminalColor) -> RGB {
        guard case .indexed(let value) = original, value < 8 else { return color }
        return self.color(index: Int(value) + 8) ?? color
    }

    /// 暗淡：按 55% 混进背景色 —— 比"降透明度"稳（透明度叠在别的底色上会变味）。
    public func dimmed(_ color: RGB) -> RGB {
        Self.blend(color, over: background, ratio: 0.55)
    }

    static func blend(_ color: RGB, over background: RGB, ratio: Double) -> RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(clamping: Int((Double(a) * ratio + Double(b) * (1 - ratio)).rounded()))
        }
        return RGB(
            red: mix(color.red, background.red),
            green: mix(color.green, background.green),
            blue: mix(color.blue, background.blue)
        )
    }

    // MARK: - 度量（门禁与文档用同一套算法）

    /// WCAG 相对亮度。
    public static func relativeLuminance(_ color: RGB) -> Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    /// WCAG 对比度（1…21）。1.0 表示同色。
    public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let hi = max(la, lb)
        let lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// CIE76 色差（可区分性用；不用 CIEDE2000 是因为这里只需要一个稳定、可解释的门槛）。
    public static func deltaE(_ a: RGB, _ b: RGB) -> Double {
        let la = lab(a)
        let lb = lab(b)
        return sqrt(
            pow(la.0 - lb.0, 2) + pow(la.1 - lb.1, 2) + pow(la.2 - lb.2, 2)
        )
    }

    private static func lab(_ color: RGB) -> (Double, Double, Double) {
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.red)
        let g = linear(color.green)
        let b = linear(color.blue)
        let x = r * 0.4124 + g * 0.3576 + b * 0.1805
        let y = r * 0.2126 + g * 0.7152 + b * 0.0722
        let z = r * 0.0193 + g * 0.1192 + b * 0.9505
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116
        }
        let fx = f(x / 0.95047)
        let fy = f(y / 1.0)
        let fz = f(z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
