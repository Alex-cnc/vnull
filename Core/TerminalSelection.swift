import Foundation

/// 终端网格里的一个位置（行 / 列，均 0 基）。
public struct TerminalCellPosition: Equatable, Sendable, Comparable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: TerminalCellPosition, rhs: TerminalCellPosition) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

/// 终端里的文本选区（鼠标拖出来的范围）。
///
/// 放在 Core 而不是视图里：**选中之后"复制到的是什么文本"是纯逻辑**，
/// 可以不打开图形界面单测（宽字符右半格、行尾空白、跨行拼接都是容易出错的地方）。
/// 视图只负责把鼠标位置换算成格子位置、把高亮画出来。
///
/// 语义：
/// - `anchor` 是按下时那一格，`focus` 是当前拖到的那一格，**两端都算选中**；
/// - 选区落在一行的行尾空白上时，复制出来的文本**裁掉行尾空白**（与终端惯例一致）；
/// - 宽字符被选中一半时按整字选中（`snapped`）。
public struct TerminalSelection: Equatable, Sendable {
    public var anchor: TerminalCellPosition
    public var focus: TerminalCellPosition

    public init(anchor: TerminalCellPosition, focus: TerminalCellPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    /// 起点（不论往哪个方向拖）。
    public var start: TerminalCellPosition { min(anchor, focus) }
    /// 终点（含）。
    public var end: TerminalCellPosition { max(anchor, focus) }

    /// 只点了一下、没有拖出范围。
    public var isEmpty: Bool { anchor == focus }

    /// 把位置吸附到整字：落在宽字符右半格上时退回它左边的起始格。
    public static func snapped(
        _ position: TerminalCellPosition,
        in lines: [[TerminalCell]]
    ) -> TerminalCellPosition {
        guard lines.indices.contains(position.row) else { return position }
        let row = lines[position.row]
        guard row.indices.contains(position.column) else { return position }
        guard row[position.column].content == .continuation else { return position }
        return TerminalCellPosition(row: position.row, column: max(0, position.column - 1))
    }

    /// 某一格是否在选区内。
    public func contains(row: Int, column: Int) -> Bool {
        let start = self.start
        let end = self.end
        if row < start.row || row > end.row { return false }
        if start.row == end.row { return column >= start.column && column <= end.column }
        if row == start.row { return column >= start.column }
        if row == end.row { return column <= end.column }
        return true
    }

    /// 取出选区文本：空白格给空格、宽字符右半格不重复出字、每行裁行尾空白、`\n` 连接。
    ///
    /// 传入的 `lines` 是**当前显示的那几行**（含回滚区偏移后的结果），
    /// 因此选区是在"看到什么就复制什么"的语义下工作的。
    public func text(in lines: [[TerminalCell]]) -> String {
        guard !lines.isEmpty else { return "" }
        let start = Self.snapped(self.start, in: lines)
        let end = self.end
        guard start.row < lines.count else { return "" }

        var result: [String] = []
        for row in start.row...min(end.row, lines.count - 1) {
            let cells = lines[row]
            guard !cells.isEmpty else {
                result.append("")
                continue
            }
            let from = row == start.row ? min(start.column, cells.count - 1) : 0
            let to = row == end.row ? min(end.column, cells.count - 1) : cells.count - 1
            guard from <= to else {
                result.append("")
                continue
            }
            var line = ""
            for column in from...to where cells.indices.contains(column) {
                // `.empty` → 空格；`.character` → 字符；`.continuation` → ""（左半格已出过）
                line += cells[column].displayText
            }
            result.append(line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
        }
        return result.joined(separator: "\n")
    }
}
