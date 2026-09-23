import Foundation

/// 命令面板的**匹配与排序**（FR-EDIT-25）。
///
/// 面板好不好用几乎全在这一层：
/// - 输入 `fmt` 要能命中「格式化 SQL」（首字母缩写），输入 `格式` 也要命中（子串）；
/// - 结果顺序要**稳定**：同样相关的命令，每次打开都该在同一个位置 ——
///   否则用户记不住"按两下 ↓ 再回车"这条最省事的路径。
///
/// 界面只负责给一组带标题的命令、把选中的执行掉。排序规则放这里是因为它能单测，
/// 而"看起来差不多"的排序差异只有测试能钉住。
public enum CommandPalette {

    /// 参与匹配的一条命令。标题与关键词由界面层提供（**Core 不做本地化**）。
    public struct Item: Equatable, Sendable {
        /// 稳定标识（执行时用它分派）。
        public var id: String
        public var title: String
        /// 额外关键词（英文名、拼音首字母之类），参与匹配但不展示。
        public var keywords: [String]
        /// 分组标题（如「查询」「连接」「智能体」），仅用于展示排序。
        public var category: String?

        public init(id: String, title: String, keywords: [String] = [], category: String? = nil) {
            self.id = id
            self.title = title
            self.keywords = keywords
            self.category = category
        }
    }

    /// 命中结果。
    public struct Match: Equatable, Sendable {
        public var item: Item
        public var score: Int
        /// 标题里命中字符的位置（界面用来高亮）；子串命中时是连续区间。
        public var highlighted: [Int]

        public init(item: Item, score: Int, highlighted: [Int]) {
            self.item = item
            self.score = score
            self.highlighted = highlighted
        }
    }

    /// 排序用的分值档位（越大越靠前）。
    /// 分档而不是给任意分值：档位之间的关系一目了然，也便于测试断言。
    enum Score {
        static let exact = 1000
        static let prefix = 800
        static let wordPrefix = 700
        static let substring = 600
        static let acronym = 500
        static let subsequence = 300
        static let keywordBonus = 50
    }

    /// 搜索。**空查询返回全部**（面板刚打开时要能一屏看到有什么可用），按原顺序。
    public static func search(_ query: String, in items: [Item], limit: Int = 50) -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return items.prefix(max(0, limit)).map { Match(item: $0, score: 0, highlighted: []) }
        }

        var matches: [Match] = []
        for item in items {
            if let match = match(trimmed, item: item) {
                matches.append(match)
            }
        }

        // 稳定排序：分值相同 → 标题 → id。**不能只按分值**，否则同分命令的顺序取决于
        // 数组顺序（那是"实现细节"，用户看到的是"每次不一样"）。
        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.title != rhs.item.title { return lhs.item.title < rhs.item.title }
            return lhs.item.id < rhs.item.id
        }
        return Array(matches.prefix(max(0, limit)))
    }

    /// 单条匹配（对外暴露便于测试与调试）。
    public static func match(_ query: String, item: Item) -> Match? {
        let loweredQuery = query.lowercased()
        let title = item.title
        let loweredTitle = title.lowercased()

        // ① 完全相同
        if loweredTitle == loweredQuery {
            return Match(item: item, score: Score.exact, highlighted: Array(title.indices).map { title.distance(from: title.startIndex, to: $0) })
        }

        // ② 前缀
        if loweredTitle.hasPrefix(loweredQuery) {
            let count = loweredQuery.count
            return Match(item: item, score: Score.prefix, highlighted: Array(0..<count))
        }

        // ③ 词首（空格 / 标点分隔后的每个词的前缀）
        if let range = wordPrefixRange(loweredTitle: loweredTitle, query: loweredQuery) {
            let start = loweredTitle.distance(from: loweredTitle.startIndex, to: range.lowerBound)
            return Match(item: item, score: Score.wordPrefix, highlighted: Array(start..<(start + loweredQuery.count)))
        }

        // ④ 子串（中文标题几乎都走这条：`格式` 命中「格式化 SQL」）
        if let range = loweredTitle.range(of: loweredQuery) {
            let start = loweredTitle.distance(from: loweredTitle.startIndex, to: range.lowerBound)
            return Match(item: item, score: Score.substring, highlighted: Array(start..<(start + loweredQuery.count)))
        }

        // ⑤ 首字母缩写（`fmt` → 「Format SQL」/「格式化 SQL」的英文关键词）
        if let highlighted = acronymPositions(query: loweredQuery, title: title), !highlighted.isEmpty {
            return Match(item: item, score: Score.acronym, highlighted: highlighted)
        }

        // ⑥ 关键词：命中关键词但不命中标题
        for keyword in item.keywords {
            let lowered = keyword.lowercased()
            if lowered == loweredQuery || lowered.hasPrefix(loweredQuery) || lowered.contains(loweredQuery) {
                return Match(item: item, score: Score.substring + Score.keywordBonus, highlighted: [])
            }
            if let positions = acronymPositions(query: loweredQuery, title: keyword), !positions.isEmpty {
                return Match(item: item, score: Score.acronym + Score.keywordBonus, highlighted: [])
            }
        }

        // ⑦ 子序列（`gs` 命中「生成 SQL」这类跳字输入）
        if let highlighted = subsequencePositions(query: loweredQuery, title: loweredTitle) {
            return Match(item: item, score: Score.subsequence, highlighted: highlighted)
        }

        return nil
    }

    // MARK: 内部

    static func wordPrefixRange(loweredTitle: String, query: String) -> Range<String.Index>? {
        var index = loweredTitle.startIndex
        var isAtWordStart = true
        while index < loweredTitle.endIndex {
            let character = loweredTitle[index]
            if isAtWordStart, loweredTitle[index...].hasPrefix(query) {
                return index..<loweredTitle.index(index, offsetBy: query.count)
            }
            isAtWordStart = character == " " || character == "-" || character == "_" || character == "/" || character == "、"
            index = loweredTitle.index(after: index)
        }
        if isAtWordStart, loweredTitle[index...].hasPrefix(query) {
            return index..<loweredTitle.index(index, offsetBy: query.count)
        }
        return nil
    }

    /// 把查询当作"首字母缩写"，逐个匹配标题里各词的第一个字符。
    static func acronymPositions(query: String, title: String) -> [Int]? {
        guard !query.isEmpty else { return nil }
        var positions: [Int] = []
        var queryIndex = query.startIndex
        var index = title.startIndex
        var isAtWordStart = true

        while index < title.endIndex, queryIndex < query.endIndex {
            let character = title[index]
            let position = title.distance(from: title.startIndex, to: index)
            let isSeparator = character == " " || character == "-" || character == "_" || character == "/"

            if isAtWordStart, !isSeparator, String(character).lowercased() == String(query[queryIndex]) {
                positions.append(position)
                queryIndex = query.index(after: queryIndex)
            }
            isAtWordStart = isSeparator
            index = title.index(after: index)
        }

        return queryIndex == query.endIndex ? positions : nil
    }

    /// 子序列匹配：查询的字符按顺序出现在标题里（不要求连续）。
    static func subsequencePositions(query: String, title: String) -> [Int]? {
        var positions: [Int] = []
        var queryIndex = query.startIndex
        var index = title.startIndex

        while index < title.endIndex, queryIndex < query.endIndex {
            if String(title[index]).lowercased() == String(query[queryIndex]) {
                positions.append(title.distance(from: title.startIndex, to: index))
                queryIndex = query.index(after: queryIndex)
            }
            index = title.index(after: index)
        }

        return queryIndex == query.endIndex ? positions : nil
    }
}
