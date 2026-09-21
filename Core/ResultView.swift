import Foundation

/// 结果集的客户端视图层：排序、筛选、分页（FR-RES-08 ~ FR-RES-10）。
///
/// 设计约束：
/// - 纯逻辑，不依赖 AppKit / SwiftUI，便于单测覆盖；
/// - 不修改原始 `QueryResult`，只产出「要显示哪些行」的下标序列，
///   因此刷新、重新执行、切页签都不会污染服务端返回的数据；
/// - 比较规则对用户可见值友好：能解析成数字的按数值比较，
///   其余按本地化自然序比较（`item2` 排在 `item10` 之前）。

/// 排序方向。
public enum ResultSortOrder: String, CaseIterable, Sendable {
    case ascending
    case descending

    public var isAscending: Bool { self == .ascending }

    /// 切换方向，供表头点击循环使用。
    public var toggled: ResultSortOrder {
        self == .ascending ? .descending : .ascending
    }
}

/// 单列排序描述。
public struct ResultSortDescriptor: Hashable, Sendable {
    public var columnIndex: Int
    public var order: ResultSortOrder
    /// NULL 是否排在最前（默认排在最后，与 PostgreSQL 的 `NULLS LAST` 一致）。
    public var nullsFirst: Bool

    public init(
        columnIndex: Int,
        order: ResultSortOrder = .ascending,
        nullsFirst: Bool = false
    ) {
        self.columnIndex = columnIndex
        self.order = order
        self.nullsFirst = nullsFirst
    }
}

/// 筛选运算符。
public enum ResultFilterOperator: String, CaseIterable, Sendable {
    case contains
    case notContains
    case equals
    case notEquals
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
    /// 空值：SQL NULL 或空字符串。
    case isEmpty
    case isNotEmpty

    /// 是否需要用户在界面上填一个比较值（`isEmpty` / `isNotEmpty` 不需要）。
    public var requiresValue: Bool {
        switch self {
        case .isEmpty, .isNotEmpty: return false
        default: return true
        }
    }

    /// 运算符的界面标签（本地化由调用方决定，这里给稳定的技术标识）。
    public var displayName: String {
        switch self {
        case .contains: return "contains"
        case .notContains: return "notContains"
        case .equals: return "equals"
        case .notEquals: return "notEquals"
        case .greaterThan: return "greaterThan"
        case .greaterThanOrEqual: return "greaterThanOrEqual"
        case .lessThan: return "lessThan"
        case .lessThanOrEqual: return "lessThanOrEqual"
        case .isEmpty: return "isEmpty"
        case .isNotEmpty: return "isNotEmpty"
        }
    }
}

/// 单元格筛选条件。
public struct ResultFilter: Hashable, Sendable {
    public var columnIndex: Int
    public var op: ResultFilterOperator
    public var value: String
    /// 文本比较是否区分大小写（默认不区分，符合「过滤」的直觉）。
    public var caseSensitive: Bool

    public init(
        columnIndex: Int,
        op: ResultFilterOperator,
        value: String = "",
        caseSensitive: Bool = false
    ) {
        self.columnIndex = columnIndex
        self.op = op
        self.value = value
        self.caseSensitive = caseSensitive
    }

    /// 判断一个单元格是否满足条件。
    /// - `nil` 视为 SQL NULL；NULL 只在 `isEmpty` 下匹配，其余运算符一律不匹配
    ///   （与 SQL 的 `WHERE col = 'x'` 遇到 NULL 返回 UNKNOWN 的行为一致）。
    public func matches(_ cell: String?) -> Bool {
        switch op {
        case .isEmpty:
            guard let cell else { return true }
            return cell.isEmpty
        case .isNotEmpty:
            guard let cell else { return false }
            return !cell.isEmpty
        default:
            break
        }

        // NULL 只在 isEmpty 下匹配，其余运算符一律不匹配（见上方文档注释）。
        guard let cell else { return false }

        switch op {
        case .equals, .notEquals:
            let equal = compareText(cell, value) == .orderedSame
            return op == .equals ? equal : !equal
        case .contains, .notContains:
            let contained = containsText(cell, value)
            return op == .contains ? contained : !contained
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            let order = ResultView.compareValues(cell, value, nullsFirst: false)
            switch op {
            case .greaterThan: return order == .orderedDescending
            case .greaterThanOrEqual: return order != .orderedAscending
            case .lessThan: return order == .orderedAscending
            case .lessThanOrEqual: return order != .orderedDescending
            default: return false
            }
        case .isEmpty, .isNotEmpty:
            return false
        }
    }

    private func compareText(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let options: String.CompareOptions = caseSensitive
            ? [.numeric]
            : [.numeric, .caseInsensitive]
        return lhs.compare(rhs, options: options, range: nil, locale: Locale.current)
    }

    private func containsText(_ cell: String, _ needle: String) -> Bool {
        if !caseSensitive {
            return cell.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return cell.contains(needle)
    }
}

/// 一页结果。
public struct ResultPage: Sendable, Equatable {
    /// 本页要显示的行（已经过筛选与排序）。
    public var rows: [[String?]]
    /// 0 起的页号。
    public var pageIndex: Int
    /// 总页数（总行为 0 时为 1，保证界面不出现「第 1 / 0 页」）。
    public var pageCount: Int
    /// 筛选后的总行数。
    public var totalRows: Int
    /// 每页行数（0 表示不分页）。
    public var pageSize: Int

    public init(rows: [[String?]], pageIndex: Int, pageCount: Int, totalRows: Int, pageSize: Int) {
        self.rows = rows
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.totalRows = totalRows
        self.pageSize = pageSize
    }

    /// 本页在筛选结果中的起始行号（0 起）。
    public var startRowIndex: Int {
        pageSize <= 0 ? 0 : pageIndex * pageSize
    }

    /// 人话描述，例如 `第 2 / 5 页 · 共 421 行`。
    public var displayDescription: String {
        "\(pageIndex + 1) / \(max(pageCount, 1)) · \(totalRows)"
    }
}

public enum ResultView {
    /// 每页行数的常用档位，供界面下拉使用。
    public static let pageSizeOptions: [Int] = [50, 100, 200, 500, 1_000]

    /// 依次应用筛选、排序，返回要显示的行。
    public static func rows(
        _ rows: [[String?]],
        filters: [ResultFilter] = [],
        sortDescriptors: [ResultSortDescriptor] = []
    ) -> [[String?]] {
        let filtered = apply(filters: filters, to: rows)
        guard !sortDescriptors.isEmpty else { return filtered }
        return sort(filtered, by: sortDescriptors)
    }

    /// 只做筛选（多条件之间是 AND）。
    public static func apply(filters: [ResultFilter], to rows: [[String?]]) -> [[String?]] {
        guard !filters.isEmpty else { return rows }
        return rows.filter { row in
            filters.allSatisfy { filter in
                filter.matches(cell(row, at: filter.columnIndex))
            }
        }
    }

    /// 只做排序：稳定排序，多列按顺序依次比较。
    public static func sort(
        _ rows: [[String?]],
        by descriptors: [ResultSortDescriptor]
    ) -> [[String?]] {
        guard !descriptors.isEmpty else { return rows }

        // 用「下标 + 行」做稳定排序：Swift 的 sort 不保证稳定，
        // 这里显式用原始下标兜底，避免同值行在每次排序时乱跳。
        return rows.enumerated()
            .sorted { lhs, rhs in
                for descriptor in descriptors {
                    let left = cell(lhs.element, at: descriptor.columnIndex)
                    let right = cell(rhs.element, at: descriptor.columnIndex)
                    let base = compareValues(left, right, nullsFirst: descriptor.nullsFirst)
                    guard base != .orderedSame else { continue }
                    let ordered = base == .orderedAscending
                    return descriptor.order.isAscending ? ordered : !ordered
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    /// 切片分页。`pageSize <= 0` 时不分页，整段返回。
    public static func page(
        _ rows: [[String?]],
        pageIndex: Int,
        pageSize: Int
    ) -> ResultPage {
        guard pageSize > 0 else {
            return ResultPage(rows: rows, pageIndex: 0, pageCount: 1, totalRows: rows.count, pageSize: 0)
        }

        let pageCount = max(1, Int(ceil(Double(rows.count) / Double(pageSize))))
        let clamped = min(max(pageIndex, 0), pageCount - 1)
        let start = clamped * pageSize
        guard start < rows.count else {
            return ResultPage(rows: [], pageIndex: clamped, pageCount: pageCount, totalRows: rows.count, pageSize: pageSize)
        }
        let end = min(start + pageSize, rows.count)
        return ResultPage(
            rows: Array(rows[start..<end]),
            pageIndex: clamped,
            pageCount: pageCount,
            totalRows: rows.count,
            pageSize: pageSize
        )
    }

    /// 一步到位：筛选 → 排序 → 分页。
    public static func page(
        _ rows: [[String?]],
        filters: [ResultFilter] = [],
        sortDescriptors: [ResultSortDescriptor] = [],
        pageIndex: Int = 0,
        pageSize: Int = 200
    ) -> ResultPage {
        page(self.rows(rows, filters: filters, sortDescriptors: sortDescriptors),
             pageIndex: pageIndex,
             pageSize: pageSize)
    }

    /// 取值：越界返回 nil。
    public static func cell(_ row: [String?], at index: Int) -> String? {
        guard index >= 0, index < row.count else { return nil }
        return row[index]
    }

    /// 比较两个可空值。
    ///
    /// 规则（对用户可见值友好，不做严格的类型系统推断）：
    /// 1. NULL 与任何值比较：NULL 按 `nullsFirst` 决定前后；两个 NULL 相等；
    /// 2. 两侧都能解析成数字 → 按数值比较（`2 < 10`，而不是字符串的 `"10" < "2"`）；
    /// 3. 其余 → 本地化自然序、忽略大小写比较（`item2 < item10`）。
    public static func compareValues(
        _ lhs: String?,
        _ rhs: String?,
        nullsFirst: Bool
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return nullsFirst ? .orderedAscending : .orderedDescending
        case (_, nil):
            return nullsFirst ? .orderedDescending : .orderedAscending
        case let (left?, right?):
            if let leftNumber = number(from: left), let rightNumber = number(from: right) {
                if leftNumber == rightNumber { return .orderedSame }
                return leftNumber < rightNumber ? .orderedAscending : .orderedDescending
            }
            return left.compare(
                right,
                options: [.numeric, .caseInsensitive, .widthInsensitive],
                range: nil,
                locale: Locale.current
            )
        }
    }

    /// 宽松数字解析：允许前后空白与千分位逗号；失败返回 nil。
    public static func number(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed) { return value }
        let withoutSeparators = trimmed.replacingOccurrences(of: ",", with: "")
        if withoutSeparators != trimmed, let value = Double(withoutSeparators) { return value }
        return nil
    }
}
