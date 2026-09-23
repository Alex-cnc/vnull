import Foundation

/// 结果区的**客户端视图状态**：表头排序（FR-RES-08）、筛选条（FR-RES-09）、分页条（FR-RES-10）。
///
/// 为什么单独有个状态类型，而不是在视图里散着几个 `@State`：
/// - 这三件事**互相耦合**（改筛选要回第 1 页、改每页行数要回第 1 页、数据变少要夹取页码），
///   散着写迟早出现「筛掉一半行后停在第 7 页，看到一片空白」；
/// - 它是纯值类型，能脱离界面单测 —— 界面只负责把动作递进来、把 `page(of:)` 画出去。
///
/// 它**不修改** `QueryResult`：只回答「现在该显示哪些行」，所以重新执行、切页签都不会污染服务端结果。
public struct ResultGridState: Equatable, Sendable {

    /// 默认每页行数（FR-RES-10 的档位之一）。
    public static let defaultPageSize = 200

    /// 筛选条件（多条件之间 AND）。
    public var filters: [ResultFilter]
    /// 排序描述（第一个是主键，其后是次要键）。
    public var sortDescriptors: [ResultSortDescriptor]
    /// 0 起的页号；可能因数据变化被夹取，显示时以 `page(of:).pageIndex` 为准。
    public var pageIndex: Int
    /// 每页行数；`0` 表示不分页（整段显示）。
    public var pageSize: Int

    public init(
        filters: [ResultFilter] = [],
        sortDescriptors: [ResultSortDescriptor] = [],
        pageIndex: Int = 0,
        pageSize: Int = ResultGridState.defaultPageSize
    ) {
        self.filters = filters
        self.sortDescriptors = sortDescriptors
        self.pageIndex = max(0, pageIndex)
        self.pageSize = max(0, pageSize)
    }

    // MARK: - 概览

    public var isPaged: Bool { pageSize > 0 }

    /// 是否有客户端视图操作在生效。
    ///
    /// 「仅对已加载的 N 行生效」这条提示（R-21）只在为真时出现 ——
    /// 没做任何客户端操作时提示它，等于每次查询都提醒用户一件没发生的事。
    public var isClientViewActive: Bool { !filters.isEmpty || !sortDescriptors.isEmpty }

    public func order(forColumn columnIndex: Int) -> ResultSortOrder? {
        sortDescriptors.first { $0.columnIndex == columnIndex }?.order
    }

    /// 该列在排序键里的次序（1 起）；不在排序键里返回 nil。界面用它显示 ①②③。
    public func sortRank(forColumn columnIndex: Int) -> Int? {
        sortDescriptors.firstIndex { $0.columnIndex == columnIndex }.map { $0 + 1 }
    }

    // MARK: - 排序（FR-RES-08）

    /// 表头点击：无排序 → 升序 → 降序 → 取消该列。
    ///
    /// - Parameter additive: 按住 Shift 点击时为 `true`：把该列**追加**为次要排序键，
    ///   而不是替换整组排序键（多列排序的入口）。
    public mutating func toggleSort(columnIndex: Int, additive: Bool = false) {
        guard columnIndex >= 0 else { return }

        if additive, let index = sortDescriptors.firstIndex(where: { $0.columnIndex == columnIndex }) {
            // 已在排序键里：只翻方向；再翻一轮（降序 → 取消）时把它移出排序键。
            let current = sortDescriptors[index]
            if current.order == .ascending {
                sortDescriptors[index].order = .descending
            } else {
                sortDescriptors.remove(at: index)
            }
            return
        }

        if additive {
            // 追加次要键：默认升序，NULL 仍排在最后（与 PostgreSQL 的 NULLS LAST 一致）。
            sortDescriptors.append(ResultSortDescriptor(columnIndex: columnIndex))
            return
        }

        let current = sortDescriptors.first { $0.columnIndex == columnIndex }
        switch current?.order {
        case nil:
            sortDescriptors = [ResultSortDescriptor(columnIndex: columnIndex)]
        case .ascending:
            sortDescriptors = [ResultSortDescriptor(columnIndex: columnIndex, order: .descending)]
        case .descending:
            // 第三下取消：排序键清空，回到服务端返回的原始顺序。
            sortDescriptors = []
        }
    }

    public mutating func clearSort() {
        sortDescriptors = []
    }

    // MARK: - 筛选（FR-RES-09）

    /// 新增一条筛选条件。列号非法时忽略。
    public mutating func addFilter(
        columnIndex: Int,
        op: ResultFilterOperator = .contains,
        value: String = "",
        caseSensitive: Bool = false
    ) {
        guard columnIndex >= 0 else { return }
        filters.append(ResultFilter(columnIndex: columnIndex, op: op, value: value, caseSensitive: caseSensitive))
        goToFirstPage()
    }

    public mutating func updateFilter(at index: Int, to filter: ResultFilter) {
        guard filters.indices.contains(index) else { return }
        filters[index] = filter
        goToFirstPage()
    }

    public mutating func removeFilter(at index: Int) {
        guard filters.indices.contains(index) else { return }
        filters.remove(at: index)
        goToFirstPage()
    }

    public mutating func clearFilters() {
        filters = []
        goToFirstPage()
    }

    public mutating func clearAll() {
        filters = []
        sortDescriptors = []
        goToFirstPage()
    }

    // MARK: - 分页（FR-RES-10）

    /// 切换每页行数：回第 1 页（否则会停在「第 3 页 × 新档位」这种没人预期的位置）。
    public mutating func setPageSize(_ size: Int) {
        pageSize = max(0, size)
        goToFirstPage()
    }

    public mutating func goToFirstPage() {
        pageIndex = 0
    }

    public mutating func goToLastPage(pageCount: Int) {
        pageIndex = max(0, pageCount - 1)
    }

    /// 下一页的页号（已按真实页数夹取）——传当前页而不是自己加减，避免与夹取后的页码脱节。
    public func nextPageIndex(after page: ResultPage) -> Int {
        min(page.pageIndex + 1, max(page.pageCount - 1, 0))
    }

    public func previousPageIndex(after page: ResultPage) -> Int {
        max(page.pageIndex - 1, 0)
    }

    // MARK: - 取值

    /// 一步到位：筛选 → 排序 → 分页。
    ///
    /// 页码会被夹取到有效范围（`ResultView.page` 内置），所以「筛掉一半行后原本停在第 7 页」
    /// 不会显示空白页。调用方要显示页码时，用返回的 `ResultPage.pageIndex`，不要用 `self.pageIndex`。
    public func page(of rows: [[String?]]) -> ResultPage {
        ResultView.page(
            rows,
            filters: filters,
            sortDescriptors: sortDescriptors,
            pageIndex: pageIndex,
            pageSize: pageSize
        )
    }

    /// 把夹取后的页码记回来。视图在渲染后调用一次，之后翻页才不会从旧页码继续。
    public mutating func adopt(pageIndex newValue: Int) {
        pageIndex = max(0, newValue)
    }
}
