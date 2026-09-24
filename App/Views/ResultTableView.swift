import SwiftUI
import DoyahCore

/// 结果区：结果表的**外壳**（标题、结果集选择器、导出、客户端排序 / 筛选 / 分页、无结果集状态）。
///
/// 与 `ResultGrid`（表格本体）是一整块，所以外观必须同一套令牌：
/// 系统文本样式（`.headline` / `.caption`）与 `.secondary` 这类语义色
/// **不在我们的字号刻度与色板里**，混着用就会出现"标题比别处大一点点、
/// 次要文字比别处灰一点点"——单看不觉得，整屏看就是不精致。
///
/// 客户端视图状态（FR-RES-08~10）放在这里而不是 Core：Core 只回答
/// 「按这些条件该显示哪些行」（`ResultGridState`），这里负责把它接上界面。
struct ResultTableView: View {
    let result: QueryResult?
    var resultCount: Int = 0
    var selectedIndex: Int = 0
    var onSelectResult: ((Int) -> Void)?
    var isExecuting: Bool = false
    /// 导出当前结果集（FR-RES-06）。为 nil 时不显示导出按钮。
    var onExport: ((ResultExportFormat) -> Void)?
    /// R-21：把筛选条件生成的 WHERE 交给编辑器（为 nil 时不显示该入口）。
    var onGenerateWhere: ((String) -> Void)?
    /// 右键「跳到被引用行…」回调：`(列名, 单元格值)`（FR-DATA-06）。
    var onJumpToReferencedRow: ((String, String?) -> Void)?

    /// 表头排序 / 筛选条 / 分页条的状态。
    @State private var gridState = ResultGridState()

    /// 结果表里选中的行。**是分页内索引**（`ResultGrid` 渲染的是 `page.rows`），
    /// 所以取行必须用 `page.rows[index]`；一旦"显示的是哪些行"变了，这个索引就指向另一行了。
    @State private var selectedRows: Set<Int> = []
    /// 行详情侧栏是否打开（FR-DATA-05）。
    @State private var isRowDetailPresented = false

    var body: some View {
        Group {
            if let result {
                let page = gridState.page(of: result.rows)

                VStack(spacing: 0) {
                    toolbar(for: result)

                    // 发丝线而不是系统 Divider：后者在两种外观下各是一个固定灰，
                    // 与我们的表面令牌不总一致。
                    HairlineView()

                    if gridState.isClientViewActive {
                        clientViewBar(for: result)
                        HairlineView()
                    }

                    if result.columns.isEmpty {
                        emptyResultSet(result)
                    } else {
                        HStack(spacing: 0) {
                            // `maxWidth: .infinity`：表格吃掉剩余宽度，侧栏只拿它自己那一段 ——
                            // 不写的话两者的伸缩范围都不明确，分栏宽度会随内容飘。
                            gridSection(for: result, page: page)
                                .frame(minWidth: RowDetailMetrics.minGridWidth, maxWidth: .infinity)

                            // 槽位 2 是恒定的 `_ConditionalContent`（关闭时是 EmptyView）：
                            // 表格在槽位 1，它的**结构身份不随侧栏开关变化** —— 用户调过的列宽、
                            // 表格滚动位置、当前高亮都留着。
                            //
                            // 这里刻意不用 `HSplitView`：它的子视图数量得在构建时固定（本仓
                            // `QueryWorkspaceView` 为此把 VSplitView 的四种组合各写了一条），
                            // 于是"开/关侧栏"只能整条换掉视图树，`ResultGrid` 跟着被重建，
                            // 上面那些状态就一次全丢。可拖动分隔条换不回这个代价。
                            if isRowDetailPresented {
                                HairlineView(vertical: true)
                                detailPanel(for: result, page: page)
                            }
                        }
                    }
                }
                // 换结果集（重新执行 / 切结果集页签）时把客户端视图归零：
                // 上一批数据上的筛选条件套到新数据上，只会让人以为"查询结果不对"。
                .onChange(of: result.id) { _, _ in
                    gridState = ResultGridState()
                    // 行号在新结果集里从零开始：旧索引只会指向另一行，必须作废。
                    selectedRows = []
                }
                // "显示的是哪些行"变了就作废选中索引：翻页、改每页条数、改筛选、改排序
                // 都会让同一个索引落到**另一行**上 —— 留着它，侧栏就会拿别行的值冒充
                // 用户选中的那行（欺骗性显示）。`ResultGridState` 只被用户动作改变，
                // 所以拿它整体当信号既够敏感也够准，不必逐个字段去凑。
                .onChange(of: gridState) { _, _ in
                    selectedRows = []
                }
            } else if isExecuting {
                VStack(spacing: Spacing.m) {
                    ProgressView()
                    Text(L(.resultExecuting))
                        .font(Theme.font(.body))
                        .foregroundStyle(Theme.text(.secondary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    L(.resultEmptyTitle),
                    systemImage: "tablecells",
                    description: Text(L(.resultEmptyDescription))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 顶部一行

    private func toolbar(for result: QueryResult) -> some View {
        HStack(spacing: Spacing.s) {
            Text(L(.resultTitle))
                .font(Theme.font(.title))

            if resultCount > 1 {
                Picker("", selection: Binding(
                    get: { selectedIndex },
                    set: { onSelectResult?($0) }
                )) {
                    ForEach(0..<resultCount, id: \.self) { index in
                        Text(L(.resultPickerItem, index + 1)).tag(index)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }

            Spacer()

            // 行详情侧栏（FR-DATA-05）：宽表与长 JSON 竖排看。
            // 没有列可展示时**禁用而不是隐藏**：能力要让人看见（结果表自己空着的时候
            // 打开一个空侧栏只会更让人费解）。
            Toggle(isOn: $isRowDetailPresented) {
                Label(L(.rowDetailTitle), systemImage: "sidebar.trailing")
            }
            .toggleStyle(.button)
            .disabled(result.columns.isEmpty)
            .help(L(.rowDetailTitle))

            if let onExport, ResultExporter.hasExportableContent(result) {
                Menu {
                    Button(L(.exportCSV)) { onExport(.csv) }
                    Button(L(.exportJSON)) { onExport(.json) }
                    Divider()
                    Button(L(.exportTSV)) { onExport(.tsv) }
                    Button(L(.exportMarkdown)) { onExport(.markdown) }
                    Button(L(.exportSQLInsert)) { onExport(.sqlInsert) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L(.resultExport))
            }

            if result.columnCount > 0 {
                Text(L(.resultSize, result.rowCount, result.columnCount))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
            // 截断必须**看得见**（R-33）：以前是静默 break，用户会把上限当成全部数据。
            if result.isTruncated {
                Text(L(.resultTruncatedTag))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.hair)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.badge)
                            .fill(Theme.status(.warning).opacity(Theme.isDarkAppearance ? Overlay.Zebra.darkAlpha : Overlay.Zebra.lightAlpha))
                    )
                    .help(L(.resultTruncated, result.truncationLimit ?? result.rowCount))
            }
            if result.executionTime > 0 {
                // 耗时用等宽数字：否则每次执行的小数位跳动会让这一小块"抖"
                Text("· \(String(format: "%.3f", result.executionTime))s")
                    .font(Theme.font(.data))
                    .foregroundStyle(Theme.text(.secondary))
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
    }

    // MARK: 客户端视图条（FR-RES-08 / FR-RES-09 + R-21）

    private func clientViewBar(for result: QueryResult) -> some View {
        ResultClientViewBar(
            columns: result.columns,
            loadedRowCount: result.rowCount,
            filters: gridState.filters,
            sortDescriptors: gridState.sortDescriptors,
            onChangeFilter: { index, filter in gridState.updateFilter(at: index, to: filter) },
            onRemoveFilter: { index in gridState.removeFilter(at: index) },
            onAddFilter: { gridState.addFilter(columnIndex: 0) },
            onClearFilters: { gridState.clearFilters() },
            onClearSort: { gridState.clearSort() },
            onRemoveSortKey: { columnIndex in gridState.toggleSort(columnIndex: columnIndex, additive: true) },
            onGenerateWhere: onGenerateWhere == nil ? nil : { generateWhere(for: result) }
        )
    }

    /// 把当前筛选条件翻成 SQL 交给编辑器（R-21 的兜底入口）。
    private func generateWhere(for result: QueryResult) {
        let columns = result.columns.map { meta in
            ResultFilterSQL.Column(
                name: meta.name,
                isNumeric: ColumnAlignment.isNumeric(typeName: meta.typeName)
            )
        }
        guard let clause = ResultFilterSQL.whereClause(filters: gridState.filters, columns: columns) else { return }
        onGenerateWhere?(clause)
    }

    // MARK: 结果表本体与行详情侧栏（FR-DATA-05）

    /// 结果表 + 分页条。侧栏收起时它就是整个结果区，打开时它是左半边 ——
    /// 分页条跟着表格走（它描述的是表格，不是详情）。
    /// 分页条是否出现。
    ///
    /// 判据不是"当前是否分页"，而是"用户有没有可能需要改分页"：
    /// 有多页要翻、或者用户正处在「全部」这一档（必须能切回去），都要给。
    private func showsPager(for result: QueryResult, page: ResultPage) -> Bool {
        guard !result.rows.isEmpty else { return false }
        return page.pageCount > 1 || !gridState.isPaged
    }

    private func gridSection(for result: QueryResult, page: ResultPage) -> some View {
        VStack(spacing: 0) {
            ResultGrid(
                result: result,
                displayedRows: page.rows,
                sortDescriptors: gridState.sortDescriptors,
                onToggleSort: { columnIndex, additive in
                    gridState.toggleSort(columnIndex: columnIndex, additive: additive)
                },
                onSelectionChange: { selection in
                    // 选中回调给的是**分页内索引**，原样存下；取行的地方统一走
                    // `selectedDetailRow(in:)`，那里会丢掉越界索引。
                    selectedRows = selection
                },
                onJumpToReferencedRow: onJumpToReferencedRow
            )

            // **只要结果里有行就给出分页条**，包括"每页 = 全部"这一档。
            //
            // 2026-09-23 修：原先只在 `isPaged`（pageSize > 0）时渲染，而**改每页条数的唯一入口
            // 就在这条分页条里** —— 用户一旦选「全部」，分页条消失，视图内再也切不回分页
            // （只能重跑查询或切页签）。这不是"不便"，是死路。
            if showsPager(for: result, page: page) {
                HairlineView()
                ResultPagerBar(
                    page: page,
                    pageSize: gridState.pageSize,
                    onChangePageSize: { size in gridState.setPageSize(size) },
                    onGoToPage: { index in gridState.adopt(pageIndex: index) }
                )
            }
        }
    }

    /// 右侧的行详情。行必须取自 `page.rows`（与 `ResultGrid` 渲染的是同一份），
    /// 否则侧栏显示的就是"另一行"。
    private func detailPanel(for result: QueryResult, page: ResultPage) -> some View {
        let selection = selectedDetailRow(in: page)
        let panel = RowDetailPanel(
            columns: result.columns,
            row: selection?.row,
            rowNumber: selection?.number
        )
        return panel.frame(
            minWidth: RowDetailMetrics.minPanelWidth,
            idealWidth: RowDetailMetrics.idealPanelWidth,
            maxWidth: RowDetailMetrics.maxPanelWidth
        )
    }

    /// 当前选中行（值已按**分页内索引**取好）。
    ///
    /// 只认在这一页里真实存在的索引：越界的（例如刚翻完页、作废还没跑到）一律当"没选中"——
    /// 宁可不显示，也不能拿邻行的值顶上。多选（结果表支持 ⌘ 多选）时取最小的那个索引：
    /// 详情只讲一行，规则必须简单且稳定，取"最先出现的那个"最容易说清楚。
    private func selectedDetailRow(in page: ResultPage) -> (row: [String?], number: Int)? {
        guard let index = selectedRows.filter({ page.rows.indices.contains($0) }).min() else { return nil }
        return (page.rows[index], page.startRowIndex + index + 1)
    }

    // MARK: 没有结果集的语句（DDL / DML）

    private func emptyResultSet(_ result: QueryResult) -> some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "checkmark.circle")
                .imageScale(.large)
                .foregroundStyle(Theme.status(.success))
            Text(L(.resultNoResultSet))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
            if let affected = result.affectedRows {
                Text(L(.resultAffectedRows, affected))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 行详情侧栏的宽度。
///
/// 需求给的区间是 280~340，取中值 320 当默认：再窄，列名 + 类型名 + 复制按钮会挤到换行；
/// 再宽，就从结果表手里抢横向空间了 —— 结果表本身就是宽表，横向空间比侧栏更值钱。
/// 上下限给到 280~440 的弹性区间（不是写死 320）：窗口窄的时候侧栏自己收窄，
/// 不会把表格挤没；长 JSON 想看得舒服时也有更宽的档位。
private enum RowDetailMetrics {
    static let minPanelWidth: CGFloat = 280
    static let idealPanelWidth: CGFloat = 320
    static let maxPanelWidth: CGFloat = 440
    /// 左半边表格的最小宽度：横向空间不够时先挤表格也不该被挤到看不见内容。
    static let minGridWidth: CGFloat = 240
}
