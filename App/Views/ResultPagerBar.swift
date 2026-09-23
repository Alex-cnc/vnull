import SwiftUI
import DoyahCore

/// 结果区的**分页条**（FR-RES-10）：每页行数档位、页码指示、翻页。
///
/// 页码显示一律用 `page.pageIndex`（已被 `ResultView.page` 夹取过），
/// 而不是外部状态里那个可能越界的值 —— 否则会出现「共 1 页却写着第 3 / 1 页」。
struct ResultPagerBar: View {

    let page: ResultPage
    /// 当前每页行数（0 = 全部）。
    let pageSize: Int

    var onChangePageSize: ((Int) -> Void)?
    var onGoToPage: ((Int) -> Void)?

    private let allRowsTag = 0

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(L(.resultPageSize))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            Picker("", selection: Binding(
                get: { pageSize },
                set: { onChangePageSize?($0) }
            )) {
                ForEach(ResultView.pageSizeOptions, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
                Text(L(.resultPageAll)).tag(allRowsTag)
            }
            .labelsHidden()
            .frame(width: 96)

            Spacer()

            Button {
                onGoToPage?(0)
            } label: {
                Image(systemName: "chevron.left.2")
            }
            .buttonStyle(.borderless)
            .disabled(page.pageIndex <= 0)
            .help(L(.resultPageFirst))

            Button {
                onGoToPage?(max(page.pageIndex - 1, 0))
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(page.pageIndex <= 0)
            .help(L(.resultPagePrevious))

            Text(L(.resultPageIndicator, page.pageIndex + 1, page.pageCount, page.totalRows))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize()

            Button {
                onGoToPage?(min(page.pageIndex + 1, page.pageCount - 1))
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(page.pageIndex >= page.pageCount - 1)
            .help(L(.resultPageNext))

            Button {
                onGoToPage?(page.pageCount - 1)
            } label: {
                Image(systemName: "chevron.right.2")
            }
            .buttonStyle(.borderless)
            .disabled(page.pageIndex >= page.pageCount - 1)
            .help(L(.resultPageLast))

            Spacer()
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .background(Theme.surface(.panel))
    }
}
