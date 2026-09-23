import XCTest
@testable import DoyahCore

/// 选区与复制文本（`TerminalSelection`）的单测。
///
/// 复制出去的内容是"用户唯一会拿走的东西"，所以这里的用例都按**终端惯例**写：
/// 行尾空白裁掉、宽字符按整字选中（不能复制出半个汉字）、反向拖动结果一致。
final class TerminalSelectionTests: XCTestCase {

    private func cells(_ text: String) -> [TerminalCell] {
        var row: [TerminalCell] = []
        for character in text {
            // 宽度判定复用 Core 的实现，避免测试自己再写一份（两处不一致就白测了）
            if TerminalScreen.cellWidth(character) == 2 {
                row.append(TerminalCell(content: .character(character)))
                row.append(TerminalCell(content: .continuation))
            } else {
                row.append(TerminalCell(content: .character(character)))
            }
        }
        // 补到 10 列，方便测行尾空白
        while row.count < 10 { row.append(.blank) }
        return row
    }

    private func select(_ from: (Int, Int), _ to: (Int, Int)) -> TerminalSelection {
        TerminalSelection(
            anchor: TerminalCellPosition(row: from.0, column: from.1),
            focus: TerminalCellPosition(row: to.0, column: to.1)
        )
    }

    func testSingleCell() {
        let lines = [cells("hello")]
        XCTAssertEqual(select((0, 1), (0, 1)).text(in: lines), "e")
    }

    func testRangeOnOneRowTrimsTrailingBlanks() {
        let lines = [cells("hi")]
        // 从第 0 列拖到第 7 列（含行尾空白）→ 只应得到 "hi"
        XCTAssertEqual(select((0, 0), (0, 7)).text(in: lines), "hi")
        XCTAssertEqual(select((0, 0), (0, 9)).text(in: lines), "hi")
    }

    func testReversedDragGivesSameText() {
        let lines = [cells("hello")]
        XCTAssertEqual(
            select((0, 4), (0, 1)).text(in: lines),
            select((0, 1), (0, 4)).text(in: lines)
        )
        XCTAssertEqual(select((0, 4), (0, 1)).text(in: lines), "ello")
    }

    func testMultipleRowsKeepLineBreaksAndTrimEachLine() {
        let lines = [cells("ab"), cells("cd"), cells("ef")]
        XCTAssertEqual(select((0, 1), (2, 0)).text(in: lines), "b\ncd\ne")
    }

    /// 拖到宽字符的右半格：必须按整字选中，不能只复制出右半格（也就是什么都没有）。
    func testSelectionSnapsToWholeWideCharacter() {
        let lines = [cells("a中文")]
        // "a" 在 0 列；"中" 占 1、2 列；"文" 占 3、4 列
        XCTAssertEqual(select((0, 2), (0, 2)).text(in: lines), "中")
        XCTAssertEqual(select((0, 2), (0, 3)).text(in: lines), "中文")
    }

    /// 起点落在右半格、终点落在左半格时也只出整字（不会出半个汉字）。
    func testWideCharacterSelectedFromBothHalves() {
        let lines = [cells("中文")]
        // 起手点在「中」的右半格 → 吸附回它的起始格；终点在「文」的左半格 → 「文」算选中。
        // 两端都碰到过，所以是两个字（与终端惯例一致）。
        XCTAssertEqual(select((0, 1), (0, 2)).text(in: lines), "中文")
        // 终点停在「中」的右半格上 → 只有「中」
        XCTAssertEqual(select((0, 0), (0, 1)).text(in: lines), "中")
    }

    func testContainsHandlesSingleRow() {
        let selection = select((2, 3), (2, 6))
        XCTAssertFalse(selection.contains(row: 2, column: 2))
        XCTAssertTrue(selection.contains(row: 2, column: 3))
        XCTAssertTrue(selection.contains(row: 2, column: 6))
        XCTAssertFalse(selection.contains(row: 2, column: 7))
        XCTAssertFalse(selection.contains(row: 1, column: 4))
    }

    func testContainsHandlesMultipleRows() {
        let selection = select((1, 4), (3, 2))
        XCTAssertFalse(selection.contains(row: 1, column: 3))
        XCTAssertTrue(selection.contains(row: 1, column: 4))
        XCTAssertTrue(selection.contains(row: 2, column: 0), "中间整行都在选区内")
        XCTAssertTrue(selection.contains(row: 2, column: 9))
        XCTAssertTrue(selection.contains(row: 3, column: 2))
        XCTAssertFalse(selection.contains(row: 3, column: 3))
    }

    func testEmptySelectionDetection() {
        XCTAssertTrue(select((0, 1), (0, 1)).isEmpty)
        XCTAssertFalse(select((0, 1), (0, 2)).isEmpty)
    }

    func testOutOfRangeRowsDoNotCrashAndYieldEmptyText() {
        let lines = [cells("a")]
        XCTAssertEqual(select((5, 0), (5, 1)).text(in: lines), "")
        XCTAssertEqual(select((0, 0), (0, 1)).text(in: []), "")
    }

    func testSnappedMovesContinuationToLeadingCell() {
        let lines = [cells("中")]
        XCTAssertEqual(
            TerminalSelection.snapped(TerminalCellPosition(row: 0, column: 1), in: lines),
            TerminalCellPosition(row: 0, column: 0)
        )
        // 非续格不受影响
        XCTAssertEqual(
            TerminalSelection.snapped(TerminalCellPosition(row: 0, column: 0), in: lines),
            TerminalCellPosition(row: 0, column: 0)
        )
        // 越界不动
        XCTAssertEqual(
            TerminalSelection.snapped(TerminalCellPosition(row: 9, column: 9), in: lines),
            TerminalCellPosition(row: 9, column: 9)
        )
    }

    /// 与 `TerminalScreen.text()`（整屏文本）保持同一套空白语义：都裁行尾空白。
    func testTrailingWhitespaceMatchesScreenTextSemantics() {
        let selection = select((0, 0), (0, 9))
        let lines = [cells("x  ")]
        XCTAssertEqual(selection.text(in: lines), "x")
    }
}
