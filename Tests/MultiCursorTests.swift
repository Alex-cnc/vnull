import XCTest
@testable import DoyahCore

/// 多光标 / 列编辑引擎（FR-EDIT-27）。
///
/// 这组测试盯的是三处"错了很难查"的语义：**从后往前应用**（否则前面的插入会把后面的光标顶偏）、
/// **UTF-16 偏移口径**（中文 / emoji 上按 `Character` 数会差好几倍）、**选区规范化**（重叠会被写两遍）。
final class MultiCursorTests: XCTestCase {

    // MARK: - 规范化

    func testNormalizationSortsAndMergesOverlaps() {
        let cursor = MultiCursor(selections: [
            NSRange(location: 5, length: 3),
            NSRange(location: 0, length: 2),
            NSRange(location: 6, length: 4)   // 与第一个重叠
        ], textLength: 20)
        XCTAssertEqual(cursor.selections, [
            NSRange(location: 0, length: 2),
            NSRange(location: 5, length: 5)
        ])
    }

    /// 同一个零长度位置出现两次必须合并成一处 —— 否则一次输入会被写两遍。
    func testDuplicateCaretCollapses() {
        let cursor = MultiCursor(selections: [
            NSRange(location: 3, length: 0),
            NSRange(location: 3, length: 0)
        ], textLength: 10)
        XCTAssertEqual(cursor.count, 1)
        XCTAssertEqual(cursor.selections, [NSRange(location: 3, length: 0)])
    }

    /// 越界选区**夹回来**而不是丢弃（丢弃会变成"选了三处只改了两处"）。
    func testOutOfRangeSelectionsAreClampedNotDropped() {
        let cursor = MultiCursor(selections: [
            NSRange(location: 8, length: 99),
            NSRange(location: 100, length: 5)
        ], textLength: 10)
        XCTAssertEqual(cursor.count, 2)
        XCTAssertEqual(cursor.selections[0], NSRange(location: 8, length: 2))
        XCTAssertEqual(cursor.selections[1], NSRange(location: 10, length: 0))
    }

    func testEmptyInputYieldsSingleCaretAtZero() {
        let cursor = MultiCursor(selections: [], textLength: 0)
        XCTAssertEqual(cursor.selections, [NSRange(location: 0, length: 0)])
    }

    // MARK: - 批量应用（位置漂移）

    /// 核心不变量：**从后往前改文本**，且光标位置要**按左侧编辑的净变化累加**。
    ///
    /// （第一版两处都错了：光标只记"应用那一刻的位置"，于是左边插入 1 个字符后，
    /// 右边的光标少加了 1 —— 这个测试当场把它抓出来。）
    func testApplyingDoesNotShiftLaterCursors() {
        let text = "abc"
        let cursor = MultiCursor(selections: [
            NSRange(location: 0, length: 0),
            NSRange(location: 3, length: 0)
        ], textLength: 3)
        let result = cursor.applying("X", to: text)
        XCTAssertEqual(result.text, "XabcX", "两个光标各自插入一个 X")
        // 光标落在各自插入内容的末尾：1 与 5（后者含左侧插入带来的 +1）
        XCTAssertEqual(result.cursors.selections, [
            NSRange(location: 1, length: 0),
            NSRange(location: 5, length: 0)
        ])
    }

    /// 多行替换内容也要正确（每一处都展开）。
    func testApplyingMultiLineReplacementAtEachSelection() {
        let text = "a;b;"
        let cursor = MultiCursor(selections: [
            NSRange(location: 0, length: 1),
            NSRange(location: 2, length: 1)
        ], textLength: 4)
        let result = cursor.applying("x\ny", to: text)
        XCTAssertEqual(result.text, "x\ny;x\ny;")
        XCTAssertEqual(result.cursors.count, 2)
    }

    // MARK: - 退格（含代理对）

    func testDeletingBackwardDeletesSelectionOrOneCharacter() {
        let text = "abcdef"
        let cursor = MultiCursor(selections: [
            NSRange(location: 6, length: 0),   // 删 f
            NSRange(location: 1, length: 3)    // 删 bcd
        ], textLength: 6)
        let result = cursor.deletingBackward(in: text)
        XCTAssertEqual(result.text, "ae")
        // 右侧那个光标（原在末尾）要跟着左边删掉的 3 个字符一起左移：5 → 2
        XCTAssertEqual(result.cursors.selections, [
            NSRange(location: 1, length: 0),
            NSRange(location: 2, length: 0)
        ])
    }

    /// 行首退格不该吃掉上一行的换行（零长度光标在 0 位置时是 no-op）。
    func testDeletingBackwardAtStartIsNoOp() {
        let result = MultiCursor(range: NSRange(location: 0, length: 0), textLength: 3)
            .deletingBackward(in: "abc")
        XCTAssertEqual(result.text, "abc")
    }

    /// emoji 是 UTF-16 代理对：退格必须**整个字符**一起删，否则文本会损坏。
    func testDeletingBackwardRemovesWholeSurrogatePair() {
        let text = "a😀"
        let result = MultiCursor(range: NSRange(location: 3, length: 0), textLength: 3)
            .deletingBackward(in: text)
        XCTAssertEqual(result.text, "a")
        XCTAssertFalse(result.text.unicodeScalars.contains { (0xD800...0xDFFF).contains($0.value) })
    }

    // MARK: - ⌘D：选下一处

    func testSelectNextOccurrenceExtendsByWordFirst() {
        var cursor = MultiCursor(range: NSRange(location: 1, length: 0), textLength: 20)
        let text = "id + id + id"
        XCTAssertTrue(cursor.selectNextOccurrence(in: text))
        XCTAssertEqual(cursor.primary, NSRange(location: 0, length: 2), "第一下先选中光标处的词")
        XCTAssertTrue(cursor.selectNextOccurrence(in: text))
        XCTAssertEqual(cursor.count, 2)
        XCTAssertEqual(cursor.primary, NSRange(location: 5, length: 2))
        XCTAssertTrue(cursor.selectNextOccurrence(in: text))
        XCTAssertEqual(cursor.count, 3)
        XCTAssertFalse(cursor.selectNextOccurrence(in: text), "没有下一处了，不环绕")
        XCTAssertEqual(cursor.count, 3)
    }

    /// 相邻两处匹配必须留下**两个**光标。
    ///
    /// 场景是"用户先手选了第一处，再按 ⌘D"（`abab` 里手选 `ab` 再按一次）——
    /// 第一版把首尾相接的选区也合并了，这两处会塌成一段 4 字符的选择。
    ///
    /// 注意别用"光标在 `abab` 开头连按两次 ⌘D"来测：`abab` 整体是**一个词**，
    /// 第一下选中的是整串（第一版测试就是在这里写错的）。
    func testAdjacentOccurrencesStayAsSeparateCursors() {
        var cursor = MultiCursor(range: NSRange(location: 0, length: 2), textLength: 4)
        XCTAssertTrue(cursor.selectNextOccurrence(in: "abab"))
        XCTAssertEqual(cursor.selections, [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 2)
        ], "相邻两处必须是两个光标，不是一段")
    }

    func testSelectNextOccurrenceCaseSensitivity() {
        var sensitive = MultiCursor(range: NSRange(location: 0, length: 2), textLength: 20)
        XCTAssertFalse(sensitive.selectNextOccurrence(in: "ID id", caseSensitive: true))
        var insensitive = MultiCursor(range: NSRange(location: 0, length: 2), textLength: 20)
        XCTAssertTrue(insensitive.selectNextOccurrence(in: "ID id", caseSensitive: false))
    }

    /// 词边界：`id` 不该匹配到 `identifier` 里面去。
    func testWordRangeDoesNotMatchInsideLongerIdentifier() {
        let text = "identifier id" as NSString
        let word = MultiCursor.wordRange(in: text, at: 0)
        XCTAssertEqual(word, NSRange(location: 0, length: 10))
        XCTAssertEqual(MultiCursor.wordRange(in: text, at: 11), NSRange(location: 11, length: 2))
    }

    // MARK: - ⌥⌘↑ / ⌥⌘↓

    func testAddCursorBelowKeepsColumn() {
        var cursor = MultiCursor(range: NSRange(location: 4, length: 0), textLength: 20)
        let text = "abc\ndef\nghi"
        XCTAssertTrue(cursor.addCursorBelow(in: text))
        XCTAssertTrue(cursor.selections.contains(NSRange(location: 8, length: 0)), "第二行同列（列 1）")
    }

    /// 目标行比当前行短时**夹到行尾**，不越到下一行。
    func testAddCursorClampsToShorterLine() {
        var cursor = MultiCursor(range: NSRange(location: 7, length: 0), textLength: 20)
        let text = "abcdefgh\nxy\nlonger"
        XCTAssertTrue(cursor.addCursorBelow(in: text))
        XCTAssertTrue(cursor.selections.contains(NSRange(location: 11, length: 0)), "短行夹到行尾（xy 之后）")
    }

    func testAddCursorAtBoundaryReturnsFalse() {
        var cursor = MultiCursor(range: NSRange(location: 0, length: 0), textLength: 5)
        XCTAssertFalse(cursor.addCursorAbove(in: "abc"), "第一行之上没有行")
    }

    // MARK: - ⌥ 拖拽列选择

    func testColumnSelectionTakesWholeColumnsAcrossLines() {
        let text = "abcd\nefgh\nijkl"
        // 从第 0 行第 1 列拖到第 2 行第 2 列（列是 UTF-16 偏移：第 2 行偏移 10 起，列 2 = 12）
        let ranges = MultiCursor.columnSelection(in: text, from: 1, to: 12)
        XCTAssertEqual(ranges, [
            NSRange(location: 1, length: 2),   // bc
            NSRange(location: 6, length: 2),   // fg
            NSRange(location: 11, length: 2)   // jk
        ])
    }

    /// 短行夹到行尾，且**不跨过换行**去选下一行的内容。
    func testColumnSelectionClampsOnShortLines() {
        let text = "abcd\nx\nabcdef"
        // 第 0 行第 2 列 → 第 2 行第 2 列（偏移 9 在第三行）
        let ranges = MultiCursor.columnSelection(in: text, from: 2, to: 9)
        XCTAssertEqual(ranges, [
            NSRange(location: 2, length: 1),   // c
            NSRange(location: 6, length: 0),   // 中间那行只有 1 个字符：夹到行尾 → 零长度
            NSRange(location: 9, length: 1)    // 第三行的 c
        ])
        // 关键不变量：任何一段都**不能跨过换行**（列选择与普通选择的区别就在这里）
        let lines = MultiCursor.lineRanges(in: text as NSString)
        for range in ranges {
            let line = lines.first { range.location >= $0.location && range.location <= $0.location + $0.length }
            XCTAssertNotNil(line)
            XCTAssertLessThanOrEqual(range.location + range.length, (line?.location ?? 0) + (line?.length ?? 0))
        }
    }

    func testColumnSelectionDirectionDoesNotMatter() {
        let text = "abcd\nefgh"
        let forward = MultiCursor.columnSelection(in: text, from: 1, to: 6)
        let backward = MultiCursor.columnSelection(in: text, from: 6, to: 1)
        XCTAssertEqual(forward, backward)
    }

    // MARK: - UTF-16 口径

    /// 中文 / emoji 上按 `Character` 数算会错位：这一层全部按 UTF-16 偏移。
    func testOffsetsFollowUTF16NotCharacterCount() {
        let text = "订单😀\nid"
        let ns = text as NSString
        XCTAssertEqual(MultiCursor.lineIndex(in: ns, at: 0), 0)
        // "订单😀" = 2 + 2 = 4 个 UTF-16 单元
        XCTAssertEqual(MultiCursor.column(in: ns, at: 4), 4)
        XCTAssertEqual(MultiCursor.lineIndex(in: ns, at: 5), 1)
        XCTAssertEqual(MultiCursor.column(in: ns, at: 6), 1)
        XCTAssertEqual(MultiCursor.offset(in: ns, line: 1, column: 1), 6)
    }

    /// 在后半行插入不该影响前半行的光标（同一不变量在非 ASCII 文本上再验一次）。
    func testApplyingOnNonASCIIText() {
        let text = "订单 id;客户 id;"
        // UTF-16 偏移：订(0) 单(1) 空格(2) i(3) d(4) ;(5) 客(6) 户(7) 空格(8) i(9) d(10) ;(11)
        let cursor = MultiCursor(selections: [
            NSRange(location: 3, length: 2),
            NSRange(location: 9, length: 2)
        ], textLength: (text as NSString).length)
        let result = cursor.applying("order_id", to: text)
        XCTAssertEqual(result.text, "订单 order_id;客户 order_id;")
    }
}

/// 多光标下**回车**的语义（FR-EDIT-27）：每个光标插一个换行、整批一次生效。
///
/// 这条用例来自需求提出者的实测反馈「一个回车换 2 行」—— 真相是有第二个光标在同时插入，
/// 而它当时**没有被画出来**（`SQLTextView.drawInsertionPoint` 已修）。语义本身是对的，
/// 所以这里把"每个光标一个换行"钉住，免得以后为了"看起来像单个光标"而改坏它。
final class MultiCursorNewlineTests: XCTestCase {

    func testNewlineIsInsertedAtEveryCaret() {
        let text = "select 1\nselect 2"
        // 两行行尾各一个光标。
        let first = NSRange(location: 8, length: 0)
        let second = NSRange(location: 17, length: 0)
        let cursor = MultiCursor(selections: [first, second], textLength: text.utf16.count)
        let applied = cursor.applying("\n", to: text)
        XCTAssertEqual(applied.text, "select 1\n\nselect 2\n")
        XCTAssertEqual(applied.cursors.selections.count, 2, "两个光标都保留")
        XCTAssertEqual(applied.cursors.selections.map(\.location), [9, 19], "各自移到新换行之后")
    }

    /// 单个光标时与 `NSTextView` 默认行为一致（我们只在多光标时接管）。
    func testSingleCaretNewlineMatchesPlainInsertion() {
        let text = "select 1"
        let cursor = MultiCursor(selections: [NSRange(location: 8, length: 0)], textLength: text.utf16.count)
        XCTAssertEqual(cursor.applying("\n", to: text).text, "select 1\n")
    }
}
