import SwiftUI
import DoyahCore

/// 结果区的**客户端视图条**（FR-RES-08 / FR-RES-09）：
/// 排序键、筛选条件、以及 R-21 要求的「只作用于已加载行」提示 + 生成 WHERE 入口。
///
/// 为什么排序要在这里也露一次脸（表头已经能排）：
/// 表头的指示器由 AppKit 画，**只表达第一排序键**。多列排序（Shift 点击）时，
/// 用户看不到「谁是次要键、次序如何、怎么单独去掉」，所以把排序键做成可点的实体。
struct ResultClientViewBar: View {

    let columns: [ColumnMeta]
    /// 已取回的行数（R-21 提示里要说清「仅对已加载的 N 行生效」）。
    let loadedRowCount: Int
    let filters: [ResultFilter]
    let sortDescriptors: [ResultSortDescriptor]

    var onChangeFilter: ((Int, ResultFilter) -> Void)?
    var onRemoveFilter: ((Int) -> Void)?
    var onAddFilter: (() -> Void)?
    var onClearFilters: (() -> Void)?
    var onClearSort: (() -> Void)?
    var onRemoveSortKey: ((Int) -> Void)?
    var onGenerateWhere: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    // 单列排序的指示器在表头上；多列才需要在这里列出来。
                    if sortDescriptors.count > 1 {
                        ForEach(Array(sortDescriptors.enumerated()), id: \.offset) { index, descriptor in
                            sortChip(rank: index + 1, descriptor: descriptor)
                        }
                        Button {
                            onClearSort?()
                        } label: {
                            Image(systemName: "arrow.up.arrow.down.circle")
                                .font(Theme.font(.caption))
                        }
                        .buttonStyle(.borderless)
                        .fixedSize()
                        .help(L(.resultSortClear))

                        Divider().frame(height: Metrics.controlHeight)
                    }

                    ForEach(Array(filters.enumerated()), id: \.offset) { index, filter in
                        filterChip(index: index, filter: filter)
                    }

                    Button {
                        onAddFilter?()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(L(.resultFilterAdd))
                }
                .padding(.vertical, Spacing.hair)
            }

            Spacer(minLength: Spacing.s)

            // R-21：客户端排序 / 筛选只作用于已取回的行 —— 不写这一句，用户会把它当成服务端过滤。
            Text(L(.resultFilterClientOnlyNote, loadedRowCount))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .fixedSize()

            if !filters.isEmpty {
                Button(L(.resultFilterGenerateWhere)) { onGenerateWhere?() }
                    .buttonStyle(.borderless)
                    .font(Theme.font(.caption))
                    .help(L(.resultFilterGenerateWhere))
                Button(L(.resultFilterClear)) { onClearFilters?() }
                    .buttonStyle(.borderless)
                    .font(Theme.font(.caption))
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .background(Theme.surface(.panel))
    }

    // MARK: 排序键

    private func sortChip(rank: Int, descriptor: ResultSortDescriptor) -> some View {
        let name = columns.indices.contains(descriptor.columnIndex)
            ? columns[descriptor.columnIndex].name
            : "?"
        return HStack(spacing: Spacing.xs) {
            Text("\(rank)")
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
            Text(name)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.primary))
            Image(systemName: descriptor.order.isAscending ? "arrow.up" : "arrow.down")
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            Button {
                onRemoveSortKey?(descriptor.columnIndex)
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.font(.caption))
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help(L(.resultSortClear))
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.hair)
        .background(
            RoundedRectangle(cornerRadius: Radius.badge)
                .fill(Theme.surface(.raised))
        )
    }

    // MARK: 筛选条件

    private func filterChip(index: Int, filter: ResultFilter) -> some View {
        let columnName = columns.indices.contains(filter.columnIndex)
            ? columns[filter.columnIndex].name
            : "?"

        return HStack(spacing: Spacing.xs) {
            Menu(columnName) {
                ForEach(Array(columns.enumerated()), id: \.offset) { columnIndex, meta in
                    Button(meta.name) {
                        var updated = filter
                        updated.columnIndex = columnIndex
                        onChangeFilter?(index, updated)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(Theme.font(.caption))

            Menu(filterOperatorLabel(filter.op)) {
                ForEach(ResultFilterOperator.allCases, id: \.self) { op in
                    Button(filterOperatorLabel(op)) {
                        var updated = filter
                        updated.op = op
                        onChangeFilter?(index, updated)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(Theme.font(.caption))

            if filter.op.requiresValue {
                TextField(L(.resultFilterValue), text: Binding(
                    get: { filter.value },
                    set: { newValue in
                        var updated = filter
                        updated.value = newValue
                        onChangeFilter?(index, updated)
                    }
                ))
                .textFieldStyle(.plain)
                .font(Theme.font(.data))
                .frame(width: 110)
            }

            // 大小写只对文本比较有意义（数值、空值判断用不到）。
            if filter.op.requiresValue {
                Button {
                    var updated = filter
                    updated.caseSensitive.toggle()
                    onChangeFilter?(index, updated)
                } label: {
                    Image(systemName: filter.caseSensitive ? "textformat" : "textformat.size")
                        .font(Theme.font(.caption))
                        .foregroundStyle(filter.caseSensitive ? Theme.accentColor : Theme.text(.tertiary))
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(L(.resultFilterCaseSensitive))
            }

            Button {
                onRemoveFilter?(index)
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.font(.caption))
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help(L(.resultFilterRemove))
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.hair)
        .background(
            RoundedRectangle(cornerRadius: Radius.badge)
                .fill(Theme.surface(.raised))
        )
    }
}

/// 运算符的界面文案。放在视图层是因为它要 `L(...)`（Core 只提供稳定标识）。
func filterOperatorLabel(_ op: ResultFilterOperator) -> String {
    switch op {
    case .contains: return L(.filterOpContains)
    case .notContains: return L(.filterOpNotContains)
    case .equals: return L(.filterOpEquals)
    case .notEquals: return L(.filterOpNotEquals)
    case .greaterThan: return L(.filterOpGreaterThan)
    case .greaterThanOrEqual: return L(.filterOpGreaterThanOrEqual)
    case .lessThan: return L(.filterOpLessThan)
    case .lessThanOrEqual: return L(.filterOpLessThanOrEqual)
    case .isEmpty: return L(.filterOpIsEmpty)
    case .isNotEmpty: return L(.filterOpIsNotEmpty)
    }
}
