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

    /// 表头排序 / 筛选条 / 分页条的状态。
    @State private var gridState = ResultGridState()

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
                        ResultGrid(
                            result: result,
                            displayedRows: page.rows,
                            sortDescriptors: gridState.sortDescriptors,
                            onToggleSort: { columnIndex, additive in
                                gridState.toggleSort(columnIndex: columnIndex, additive: additive)
                            }
                        )
                        if gridState.isPaged {
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
                // 换结果集（重新执行 / 切结果集页签）时把客户端视图归零：
                // 上一批数据上的筛选条件套到新数据上，只会让人以为"查询结果不对"。
                .onChange(of: result.id) { _, _ in
                    gridState = ResultGridState()
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
