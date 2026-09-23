import XCTest
@testable import DoyahCore

/// 绘制分段（`TerminalRun`）的单测。
///
/// 这些用例守的是一个**真实缺陷**：原先整行拼成一个 `NSAttributedString` 一次性绘制，
/// 字形落点由字体 advance 决定；实测中日韩字符会回落成 PingFang、advance 只有
/// **1.607 格而不是 2 格**，于是含中文的行从第一个汉字起越画越偏。
/// 按段绘制后每段都从自己的格子原点开始，这里断言的就是"起点必须等于列号"。
final class TerminalRunTests: XCTestCase {

    private func cell(_ character: Character, bold: Bool = false) -> TerminalCell {
        TerminalCell(content: .character(character), bold: bold)
    }

    /// 宽字符：字符格 + 右半格。
    private func wide(_ character: Character) -> [TerminalCell] {
        [TerminalCell(content: .character(character)), TerminalCell(content: .continuation)]
    }

    private func text(_ run: TerminalRun) -> String { run.text }
    private func columns(_ runs: [TerminalRun]) -> [Int] { runs.map(\.column) }

    func testContiguousSameAttributeCellsMergeIntoSingleRun() {
        let row = [cell("a"), cell("b"), cell("c")]
        let runs = TerminalScreen.runs(in: row)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.column, 0)
        XCTAssertEqual(runs.first?.text, "abc")
    }

    func testAttributeChangeBreaksRunButColumnKeepsExact() {
        let row = [cell("a"), cell("b", bold: true), cell("c", bold: true), cell("d")]
        let runs = TerminalScreen.runs(in: row)
        XCTAssertEqual(columns(runs), [0, 1, 3])
        XCTAssertEqual(runs.map { text($0) }, ["a", "bc", "d"])
        XCTAssertTrue(runs[1].cell.bold)
        XCTAssertFalse(runs[2].cell.bold)
    }

    /// 关键回归：中间有空白格时，后一段的起点必须是**它自己的列号**，
    /// 而不是"上一段起点 + 上一段字数" —— 后者正是字形漂移的来源。
    func testGapKeepsFollowingRunAtItsOwnColumn() {
        let row = [cell("a"), .blank, cell("c")]
        let runs = TerminalScreen.runs(in: row)
        XCTAssertEqual(columns(runs), [0, 2])
        XCTAssertEqual(runs.map { text($0) }, ["a", "c"])
    }

    /// 宽字符**自己占一段**：它 1.607 格的 advance 会把段内后面的字符全部带偏，
    /// 所以既不能和前面的并段，也不能让后面的字符并进来 —— 每段起点必须等于真列号。
    func testWideCharactersEachGetTheirOwnRunAtExactColumns() {
        let row = wide("中") + wide("文") + [cell("!")]
        let runs = TerminalScreen.runs(in: row)
        XCTAssertEqual(columns(runs), [0, 2, 4])
        XCTAssertEqual(runs.map { text($0) }, ["中", "文", "!"])
    }

    /// 宽字符之后紧跟的窄字符可以自己连成一段（段内全窄 → 不会漂）。
    func testNarrowRunStartsAfterWideCharacter() {
        let row = wide("中") + [cell("a"), cell("b"), cell("c")]
        let runs = TerminalScreen.runs(in: row)
        XCTAssertEqual(columns(runs), [0, 2])
        XCTAssertEqual(runs.map { text($0) }, ["中", "abc"])
    }

    func testWideCharacterThenAttributeChangeStartsAtCorrectColumn() {
        let row = wide("中") + [cell("x", bold: true)]
        let runs = TerminalScreen.runs(in: row)
        XCTAssertEqual(columns(runs), [0, 2])
        XCTAssertEqual(runs.map { text($0) }, ["中", "x"])
    }

    func testEmptyRowProducesNoRuns() {
        XCTAssertTrue(TerminalScreen.runs(in: [.blank, .blank, .blank]).isEmpty)
        XCTAssertTrue(TerminalScreen.runs(in: []).isEmpty)
    }

    func testLoneContinuationCellIsSkipped() {
        let row = [TerminalCell(content: .continuation), cell("a")]
        let runs = TerminalScreen.runs(in: row)
        XCTAssertEqual(columns(runs), [1])
        XCTAssertEqual(runs.map { text($0) }, ["a"])
    }

    /// 每个"逐格不同颜色"的格子都应以自己的列号起一段 —— 这正是真彩 TUI
    /// （鲸鱼拼图每格前景/背景都不同）的情形。
    func testEveryCellWithDistinctColorStartsAtItsOwnColumn() {
        let row = (0..<6).map { index in
            TerminalCell(
                content: .character("▀"),
                foreground: .rgb(UInt8(index), 0, 0),
                background: .rgb(0, UInt8(index), 0)
            )
        }
        let runs = TerminalScreen.runs(in: row)
        XCTAssertEqual(columns(runs), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(runs.map { text($0) }, Array(repeating: "▀", count: 6))
    }
}
