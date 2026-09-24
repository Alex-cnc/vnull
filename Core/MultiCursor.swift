import Foundation

/// 多光标 / 列编辑的**纯逻辑**（FR-EDIT-27）。
///
/// ## 为什么要单独一层
///
/// "一次改多处"听起来只是循环，但有三处**错了很难查**的语义，而它们都能脱离图形界面验证：
///
/// 1. **位置漂移**：直接在原地按顺序替换，前面的插入会把后面所有光标的位置顶偏 ——
///    必须**从后往前**应用（`applying` / `deletingBackward` 都这么做）。
/// 2. **偏移口径**：`NSTextView.selectedRanges` 用的是 **UTF-16 偏移**，不是 `Character` 个数。
///    中文、emoji 上两种口径会差好几倍，搞混就会出现"光标落在半个字符里"。
///    这一层统一用 UTF-16（`NSString` 语义），与 AppKit 一致。
/// 3. **选区规范化**：重叠、重复、乱序的选区必须先合并排序，否则同一次输入会被写两遍。
///
/// 视图只负责"把鼠标/按键变成选区集合"，以及"把结果选区集合设回去"。
public struct MultiCursor: Equatable, Sendable {

    /// 已排序、互不重叠的选区（`NSRange` 语义：UTF-16 location + length）。
    public private(set) var selections: [NSRange]

    /// 规范化：夹进文本范围、去重、合并重叠、按位置排序。
    ///
    /// - Parameter textLength: 文本的 UTF-16 长度（越界的选区会被夹回来，而不是丢弃 ——
    ///   丢弃会让"选了三处、只改了两处"这种问题无声发生）。
    public init(selections: [NSRange], textLength: Int = .max) {
        self.selections = Self.normalized(selections, textLength: textLength)
    }

    /// 单个光标 / 选区。
    public init(range: NSRange, textLength: Int = .max) {
        self.init(selections: [range], textLength: textLength)
    }

    public static func normalized(_ ranges: [NSRange], textLength: Int = .max) -> [NSRange] {
        let limit = max(0, textLength)
        let clamped = ranges.map { range -> NSRange in
            let location = min(max(0, range.location), limit)
            let length = min(max(0, range.length), limit - location)
            return NSRange(location: location, length: length)
        }
        let sorted = clamped.sorted { lhs, rhs in
            lhs.location == rhs.location ? lhs.length < rhs.length : lhs.location < rhs.location
        }
        var merged: [NSRange] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            let lastEnd = last.location + last.length
            // 合并规则（三条，都是踩过的坑）：
            // ① 真重叠（严格小于）→ 合并；
            // ② 同一个零长度位置出现两次（重复光标）→ 合并，否则一次输入会被写两遍；
            // **不合并**的两种相邻情形（都很常见，合并就出事）：
            //   · 零长度光标正好贴在上一段选区末尾 → 那是一个独立光标；
            //   · 两段非零长选区首尾相接 → 那是"相邻两处同词"，⌘D 连按两次必须留下两个光标
            //     （第一版把"相接"也合并了，`abab` 上连按 ⌘D 会塌成一段）。
            let duplicatesACaret = range.length == 0 && last.length == 0 && range.location == last.location
            if range.location < lastEnd || duplicatesACaret {
                let newEnd = max(lastEnd, range.location + range.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: newEnd - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged.isEmpty ? [NSRange(location: 0, length: 0)] : merged
    }

    public var count: Int { selections.count }
    public var isEmpty: Bool { selections.isEmpty }

    /// 主选区（最后一个 —— 与 AppKit 的约定一致：最后一个选区是"主"光标）。
    public var primary: NSRange { selections.last ?? NSRange(location: 0, length: 0) }

    /// 全部为零长度（只有光标、没有选中内容）。
    public var isAllCaret: Bool { selections.allSatisfy { $0.length == 0 } }

    // MARK: - ⌘D：选下一处相同内容

    /// 选出下一处与主选区内容相同的匹配。
    ///
    /// 语义（与常见编辑器对齐）：
    /// - 主选区为空 → 先按"当前光标处的词"扩展（`wordRange`），没有词就不动；
    /// - 已有匹配 → 从**最后一个选区的末尾**往后找，找不到返回 `false`（**不环绕**，
    ///   环绕会让人以为"已经全选完了"其实又绕回开头）；
    /// - 跳过与已有选区重叠的匹配。
    public mutating func selectNextOccurrence(
        in text: String,
        caseSensitive: Bool = true
    ) -> Bool {
        let source = text as NSString
        let current = primary
        var needleRange = current
        if current.length == 0 {
            guard let word = Self.wordRange(in: source, at: current.location) else { return false }
            needleRange = word
            // 第一下 ⌘D 只是"选中当前词"，不算新增光标。
            if !selections.contains(needleRange) {
                selections = Self.normalized(selections.filter { $0 != current } + [needleRange], textLength: source.length)
                return true
            }
        }
        let needle = source.substring(with: needleRange)
        guard !needle.isEmpty else { return false }

        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var searchStart = needleRange.location + needleRange.length
        while searchStart <= source.length - (needle as NSString).length {
            let found = source.range(
                of: needle,
                options: options,
                range: NSRange(location: searchStart, length: source.length - searchStart)
            )
            guard found.location != NSNotFound else { return false }
            let overlaps = selections.contains { existing in
                NSIntersectionRange(existing, found).length > 0
                    || (existing.length == 0 && found.location == existing.location)
            }
            if !overlaps {
                selections = Self.normalized(selections + [found], textLength: source.length)
                return true
            }
            searchStart = found.location + max(1, found.length)
        }
        return false
    }

    /// 光标处的"词"范围（字母 / 数字 / 下划线，与编辑器补全同一口径）。
    public static func wordRange(in text: NSString, at location: Int) -> NSRange? {
        guard text.length > 0 else { return nil }
        let index = min(max(0, location), text.length - 1)
        func isWord(_ value: unichar) -> Bool {
            guard let scalar = UnicodeScalar(value) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        // 光标可能正好停在词尾右侧：先往左看一格。
        var start = index
        if !isWord(text.character(at: start)), start > 0, isWord(text.character(at: start - 1)) {
            start -= 1
        }
        guard isWord(text.character(at: start)) else { return nil }
        var end = start
        while end + 1 < text.length, isWord(text.character(at: end + 1)) { end += 1 }
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: end - start + 1)
    }

    // MARK: - ⌥⌘↑ / ⌥⌘↓：在相邻行同列加光标

    public mutating func addCursorAbove(in text: String) -> Bool {
        addCursor(in: text, lineOffset: -1)
    }

    public mutating func addCursorBelow(in text: String) -> Bool {
        addCursor(in: text, lineOffset: 1)
    }

    private mutating func addCursor(in text: String, lineOffset: Int) -> Bool {
        let source = text as NSString
        let target = primary
        // 以主光标的**起始列**为准（选区有长度时，列取选区起点 —— 与列编辑一致）。
        let column = Self.column(in: source, at: target.location)
        guard let line = Self.lineIndex(in: source, at: target.location) else { return false }
        let targetLine = line + lineOffset
        let lineCount = Self.lineRanges(in: source).count
        guard targetLine >= 0, targetLine < lineCount else { return false }
        guard let offset = Self.offset(in: source, line: targetLine, column: column) else { return false }
        let range = NSRange(location: offset, length: 0)
        guard !selections.contains(range) else { return false }
        selections = Self.normalized(selections + [range], textLength: source.length)
        return true
    }

    // MARK: - ⌥ 拖拽：列选择

    /// 从两个文本偏移生成**列选择**：逐行取 `[minColumn, maxColumn]` 范围。
    ///
    /// 语义：
    /// - 两端按行 / 列取最小 / 最大，方向无所谓（往上拖或往下拖一样）；
    /// - 短行**夹到行尾**（不会跨过换行去选下一行 —— 那正是列选择与普通选择的区别）；
    /// - 列是 UTF-16 偏移口径（等宽字体下与视觉列一致）。
    public static func columnSelection(in text: String, from start: Int, to end: Int) -> [NSRange] {
        let source = text as NSString
        guard source.length > 0 else { return [NSRange(location: 0, length: 0)] }
        let ranges = lineRanges(in: source)
        guard let startLine = lineIndex(in: source, at: start),
              let endLine = lineIndex(in: source, at: end) else {
            return [NSRange(location: min(start, source.length), length: 0)]
        }
        let firstLine = min(startLine, endLine)
        let lastLine = max(startLine, endLine)
        let startColumn = column(in: source, at: start)
        let endColumn = column(in: source, at: end)
        let minColumn = min(startColumn, endColumn)
        let maxColumn = max(startColumn, endColumn)

        return (firstLine...lastLine).compactMap { line -> NSRange? in
            let range = ranges[line]
            // 行内容不含换行符（行尾的 \n 属于下一行的起点）。
            let contentLength = range.length
            let location = range.location + min(minColumn, contentLength)
            let end = range.location + min(maxColumn + 1, contentLength)
            guard end >= location else { return nil }
            return NSRange(location: location, length: end - location)
        }
    }

    // MARK: - 在多个选区上应用编辑

    /// 把 `replacement` 写到每个选区（零长度光标=插入），返回新文本与**新的光标集合**。
    ///
    /// 关键：**从后往前应用** —— 先改后面的位置，前面的偏移才不会被顶歪。
    /// 每个光标在应用后落在自己插入内容的**末尾**（连续输入时下一个字符接着写）。
    public func applying(_ replacement: String, to text: String)
        -> (text: String, cursors: MultiCursor) {
        applyEdits(selections.map { ($0, replacement) }, to: text)
    }

    /// 把「在 `range` 处写入 `replacement`」这批编辑一次性应用，并给出新文本与新光标。
    ///
    /// **两处必须做对**（第一版两处都错了，被单测抓出来）：
    /// 1. 光标位置要按**左侧编辑的净变化**累加：在左边插入 1 个字符，右边所有光标都要 +1。
    ///    只记"应用那一刻的位置"会得到一串偏左的光标。
    /// 2. 文本必须**从后往前**改：先改左边会把右边所有位置顶歪。
    private func applyEdits(
        _ edits: [(range: NSRange, replacement: String)],
        to text: String
    ) -> (text: String, cursors: MultiCursor) {
        let source = text as NSString
        let ordered = edits
            .map { (Self.clamped($0.range, in: source.length), $0.replacement) }
            .sorted { $0.0.location < $1.0.location }

        // ① 先按**原文本**坐标算出每个光标在新文本里的位置。
        var positions: [NSRange] = []
        var cumulative = 0
        for (range, replacement) in ordered {
            let replacementLength = (replacement as NSString).length
            positions.append(NSRange(location: range.location + replacementLength + cumulative, length: 0))
            cumulative += replacementLength - range.length
        }

        // ② 再从后往前改文本。
        let mutable = NSMutableString(string: text)
        for (range, replacement) in ordered.reversed() {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        let result = mutable as String
        return (result, MultiCursor(selections: positions, textLength: (result as NSString).length))
    }

    /// 退格：选区有内容则删掉选区，零长度光标则删掉**它左边一个 UTF-16 单元**。
    ///
    /// 注意"一个 UTF-16 单元"不等于"一个字符"：删到最后只剩 emoji 的高位代理时，
    /// 会把整个代理对一起删掉（见 `scalarAlignedDeletionRange`），否则文本会损坏。
    public func deletingBackward(in text: String) -> (text: String, cursors: MultiCursor) {
        let source = text as NSString
        let edits: [(range: NSRange, replacement: String)] = selections.map { range in
            if range.length > 0 { return (range, "") }
            return (Self.scalarAlignedDeletionRange(in: source, before: range.location), "")
        }
        // 没有可删的（例如光标都在 0 位置）→ 原样返回，不制造一次空编辑。
        guard edits.contains(where: { $0.range.length > 0 }) else {
            return (text, self)
        }
        return applyEdits(edits, to: text)
    }

    /// 删掉 `location` 左边一个**完整字符**（把代理对 / 组合序列一起带走）。
    static func scalarAlignedDeletionRange(in text: NSString, before location: Int) -> NSRange {
        guard location > 0, location <= text.length else { return NSRange(location: location, length: 0) }
        var start = location - 1
        // 落在低位代理上 → 连高位一起删（UTF-16 代理对是 2 个单元）。
        if start > 0, isLowSurrogate(text.character(at: start)), isHighSurrogate(text.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: location - start)
    }

    private static func isHighSurrogate(_ value: unichar) -> Bool { (0xD800...0xDBFF).contains(value) }
    private static func isLowSurrogate(_ value: unichar) -> Bool { (0xDC00...0xDFFF).contains(value) }

    // MARK: - 位置换算（全部 UTF-16 口径）

    /// 每一行的内容范围（**不含**换行符）。
    public static func lineRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            var contentLength = lineRange.length
            while contentLength > 0 {
                let last = text.character(at: lineRange.location + contentLength - 1)
                if last == 0x0A || last == 0x0D { contentLength -= 1 } else { break }
            }
            ranges.append(NSRange(location: lineRange.location, length: contentLength))
            let next = lineRange.location + lineRange.length
            if next <= location { break }
            location = next
            if location >= text.length { break }
        }
        return ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges
    }

    public static func lineIndex(in text: NSString, at location: Int) -> Int? {
        let ranges = lineRanges(in: text)
        let index = min(max(0, location), text.length)
        for (offset, range) in ranges.enumerated() where index <= range.location + range.length {
            return offset
        }
        return ranges.count - 1
    }

    public static func column(in text: NSString, at location: Int) -> Int {
        guard let line = lineIndex(in: text, at: location) else { return 0 }
        let range = lineRanges(in: text)[line]
        return max(0, min(location, range.location + range.length) - range.location)
    }

    public static func offset(in text: NSString, line: Int, column: Int) -> Int? {
        let ranges = lineRanges(in: text)
        guard ranges.indices.contains(line) else { return nil }
        let range = ranges[line]
        return range.location + min(max(0, column), range.length)
    }

    static func clamped(_ range: NSRange, in length: Int) -> NSRange {
        let location = min(max(0, range.location), max(0, length))
        let rangeLength = min(max(0, range.length), max(0, length) - location)
        return NSRange(location: location, length: rangeLength)
    }
}
