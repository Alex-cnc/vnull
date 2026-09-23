import SwiftUI
import DoyahCore

/// 「按条件浏览 / 统计行数」面板（FR-DATA-02）。
///
/// 与客户端筛选（结果区里那个筛选条）的区别必须在界面上说清：
/// **这里的条件是在服务端执行的** —— 填什么都发给数据库，因此配一份**实时预览**，
/// 看到什么就执行什么（与表设计器同一个原则）。
struct BrowseRowsSheet: View {
    @EnvironmentObject private var appState: AppState
    let object: DatabaseObject

    var onDismiss: () -> Void

    @State private var filter = RowBrowsingQuery.Filter()
    @State private var limitText = "\(ObjectTreeActions.defaultBrowseLimit)"
    @State private var offsetText = "0"

    private var dialect: any SQLDialect {
        SQLDialectFactory.make(for: appState.selectedConnection?.dbType ?? .postgresql)
    }

    /// 预览用的条件（把文本行数解析进来）。
    private var resolvedFilter: RowBrowsingQuery.Filter {
        var resolved = filter
        resolved.limit = Int(limitText.trimmingCharacters(in: .whitespaces)) ?? ObjectTreeActions.defaultBrowseLimit
        resolved.offset = Int(offsetText.trimmingCharacters(in: .whitespaces)) ?? 0
        return resolved
    }

    private var browseResult: Result<String, RowBrowsingQuery.BuildError> {
        RowBrowsingQuery.browse(
            table: object.name,
            schema: object.schema,
            filter: resolvedFilter,
            dialect: dialect
        )
    }

    private var countResult: Result<String, RowBrowsingQuery.BuildError> {
        RowBrowsingQuery.count(
            table: object.name,
            schema: object.schema,
            filter: resolvedFilter,
            dialect: dialect
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.browseSheetTitle, object.name))
                .font(Theme.font(.title))

            // 这是与「结果区客户端筛选」最容易混淆的地方，明说一句。
            Text(L(.browseSheetServerSideNote))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            field(L(.browseSheetWhere)) {
                TextField(L(.browseSheetWherePlaceholder), text: $filter.whereClause)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font(.mono))
            }

            field(L(.browseSheetOrderBy)) {
                TextField(L(.browseSheetOrderByPlaceholder), text: $filter.orderBy)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font(.mono))
            }

            HStack(spacing: Spacing.m) {
                field(L(.browseSheetLimit)) {
                    TextField("", text: $limitText)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.font(.data))
                        .frame(width: 90)
                }
                field(L(.browseSheetOffset)) {
                    TextField("", text: $offsetText)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.font(.data))
                        .frame(width: 90)
                }
            }

            Text(L(.browseSheetPreview))
                .font(Theme.font(.bodyStrong))

            ScrollView {
                Text(previewText)
                    .font(Theme.font(.monoSmall))
                    .foregroundStyle(previewIsError ? Theme.status(.danger) : Theme.text(.primary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.s)
            }
            .frame(height: 96)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(Theme.surface(.panel))
            )

            Text(L(.browseSheetHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))

            HStack {
                Spacer()
                Button(L(.commonCancel)) { onDismiss() }
                Button(L(.browseSheetCount)) {
                    appState.countRows(object, filter: resolvedFilter)
                    onDismiss()
                }
                .disabled(previewIsError)
                Button(L(.browseSheetBrowse)) {
                    appState.browseRows(object, filter: resolvedFilter)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(previewIsError)
            }
        }
        .padding(Spacing.l)
        .frame(width: 560)
        .onAppear {
            limitText = "\(filter.limit)"
            offsetText = "\(filter.offset)"
        }
    }

    private var previewIsError: Bool {
        if case .failure = browseResult { return true }
        return false
    }

    private var previewText: String {
        switch browseResult {
        case .success(let sql):
            return sql
        case .failure(let error):
            return L(.browseSheetRefused, error.identifier)
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            content()
        }
    }
}
