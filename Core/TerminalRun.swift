import Foundation

/// 一行单元格的**绘制分段**：把列号连续、属性相同的格子并成一段，每段带起始列。
///
/// 为什么需要它（这是一处真实缺陷的修法）：
/// 原先视图把**一整行**拼成一个 `NSAttributedString`，再一次性 `draw(at:)`，
/// 于是每个字形的落点完全由**字体 advance** 决定，与我们的格子宽度无关。
/// 实测（`NSFont.monospacedSystemFont(ofSize: 12)`）：
///
/// | 字符 | advance ÷ 基准「W」 | 实际字体 |
/// |---|---|---|
/// | `W` / 空格 / `▀ ▄ █ ░ ─` / `·` | 全部 **1.000** | `.AppleSystemUIFontMonospaced` |
/// | `中` / `鲸` | **1.607**（不是 2！） | `.PingFangUITextSC`（回落） |
///
/// 也就是说：**块字符没问题（鲸鱼拼图不受影响），但中日韩字符会回落成 PingFang，
/// 一格宽只有 1.607 个格子宽** —— 整行绘制时，含中文的行从第一个汉字起逐步偏左，
/// 越画越错，行越长越明显。
///
/// 按段绘制时每段都从**自己的格子原点**开始，advance 的差异只影响段内、
/// 不可能跨格累积，因此对任何字体回落都免疫。
///
/// 由此推出两条**必须**遵守的分段规则（都是上面那张表逼出来的）：
/// 1. **宽字符自己占一段**，不能和别的字符合并 —— 它 1.607 格的 advance 会把
///    同一段里它后面的字符全部带偏（`中文abc` 会被画成 `中@0 文@1.6 abc@3.2`，
///    而正确位置是 `0 / 2 / 4`）。
/// 2. 宽字符后面那个字符**另起一段** —— 否则同理。
///
/// 结果是：**段内只可能有窄字符**，而窄字符在等宽字体里 advance 恰好一格（实测 1.000），
/// 段内也不会漂。
public struct TerminalRun: Equatable, Sendable {
    /// 起始列（0 基）。视图用 `column × 格子宽度` 定位，不靠上一个字形的落点。
    public var column: Int
    /// 这一段要画的文本。
    public var text: String
    /// 这一段共用的绘制属性（取段内第一格）。
    public var cell: TerminalCell

    public init(column: Int, text: String, cell: TerminalCell) {
        self.column = column
        self.text = text
        self.cell = cell
    }
}

extension TerminalScreen {

    /// 把一行切成绘制段。空白格与宽字符右半格不产生段（背景仍由背景层按格画）。
    ///
    /// 分段条件：**列号连续 + 属性一致 + 段内不含宽字符**（原因见 `TerminalRun` 文档）。
    public static func runs(in row: [TerminalCell]) -> [TerminalRun] {
        var runs: [TerminalRun] = []
        /// 上一段结束后的下一个列号；只有它等于当前列号才允许并进上一段。
        var lastRunEnd: Int?
        /// 上一个画出来的格子是不是宽字符（宽字符后面必须另起一段）。
        var lastWasWide = false

        var index = 0
        while index < row.count {
            let cell = row[index]
            guard case .character(let character) = cell.content else {
                // `.empty` / `.continuation` 不画字形，也不打断「当前列号」的推进：
                // 宽字符的右半格本来就属于左边那个字形。
                index += 1
                continue
            }

            let consumed = (index + 1 < row.count && row[index + 1].content == .continuation) ? 2 : 1
            let isWide = consumed == 2
            let canMerge = consumed == 1
                && !lastWasWide
                && lastRunEnd == index
                && runs.last.map { sameAttributes($0.cell, cell) } == true

            if canMerge, var last = runs.last {
                last.text.append(character)
                runs[runs.count - 1] = last
            } else {
                runs.append(TerminalRun(column: index, text: String(character), cell: cell))
            }
            lastWasWide = isWide
            lastRunEnd = index + consumed
            index += 1
        }
        return runs
    }

    /// 影响绘制的属性是否一致（内容不参与比较）。
    static func sameAttributes(_ lhs: TerminalCell, _ rhs: TerminalCell) -> Bool {
        lhs.bold == rhs.bold
            && lhs.underline == rhs.underline
            && lhs.inverse == rhs.inverse
            && lhs.foreground == rhs.foreground
            && lhs.background == rhs.background
    }
}
