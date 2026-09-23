import SwiftUI
import DoyahCore

/// 全库对象搜索面板（FR-META-12 的界面部分）。
///
/// 界面只做三件事：**防抖**、**呈现**、**把选中项交给 AppState**。
/// 匹配、排序、以及"结果可能被截断"的判定全在 Core 的 `ObjectSearch` 里（可单测）——
/// 视图里再算一遍分值，等于给同一个问题写第二份答案。
///
/// 入口有两个：对象树工具条的放大镜，以及 ⌘K 里的「全库对象搜索」。
struct ObjectSearchPanel: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    /// `nil` = 还没搜过（或输入被清空）。空关键词**不列结果**，理由见 `ObjectSearch.search`。
    @State private var outcome: ObjectSearch.Outcome?
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var selected: ObjectSearch.Match?
    @FocusState private var isKeywordFocused: Bool

    /// 输入停顿多久才真的查库。
    ///
    /// 250ms 是量出来的折中：低于它，中文输入法每敲一个字母就发一次请求；
    /// 高于它，手感上会"慢半拍"。
    private static let debounce = Duration.milliseconds(250)

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 「浏览数据」只对表 / 视图成立：列是字段、函数不是可查对象。
    private var canBrowse: Bool {
        switch selected?.hit.kind {
        case .table, .view: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.objectSearchTitle))
                .font(Theme.font(.title))

            searchField

            HairlineView()

            resultArea

            HairlineView()

            footer
        }
        .padding(Spacing.l)
        .frame(width: 640, height: 480)
        .background(Theme.surface(.panel))
        .onAppear { isKeywordFocused = true }
        // 防抖：`.task(id:)` 在关键词变化时**自动取消**上一次，所以慢的旧结果不会覆盖新结果。
        .task(id: keyword) {
            let needle = trimmedKeyword
            guard !needle.isEmpty else {
                outcome = nil
                selected = nil
                searchError = nil
                return
            }

            try? await Task.sleep(for: Self.debounce)
            // 睡醒后先看有没有被取消 —— 否则会为已作废的输入打一次库。
            guard !Task.isCancelled else { return }
            await search(needle)
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.text(.tertiary))
            TextField(L(.objectSearchPlaceholder), text: $keyword)
                .textFieldStyle(.plain)
                .font(Theme.font(.body))
                .focused($isKeywordFocused)
                .onSubmit { if canBrowse { browseSelected() } }
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(Spacing.s)
        .background(Theme.surface(.raised))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }

    // MARK: - 结果

    @ViewBuilder
    private var resultArea: some View {
        if let searchError {
            Label(searchError, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.status(.danger))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        } else if trimmedKeyword.isEmpty {
            Text(L(.objectSearchHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        } else if let outcome, outcome.matches.isEmpty {
            Text(L(.objectSearchNoMatch))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array((outcome?.matches ?? []).enumerated()), id: \.offset) { _, match in
                        row(match)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ match: ObjectSearch.Match) -> some View {
        HStack(spacing: Spacing.s) {
            kindBadge(match.hit.kind)
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(match.hit.qualifiedName)
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text(.primary))
                    .lineLimit(1)
                // 补充信息（表类型 / 列类型 / 函数签名）有才显示：空一行会让列表看起来缺了什么。
                if let detail = match.hit.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.tertiary))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(
            match == selected
                ? Theme.accentColor.opacity(
                    Theme.isDarkAppearance ? Overlay.Selection.darkAlpha : Overlay.Selection.lightAlpha
                )
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { selected = match }
    }

    /// 类型徽标：颜色只用来表达**身份**（表 / 视图 / 列 / 函数），不是状态。
    private func kindBadge(_ kind: ObjectSearch.Kind) -> some View {
        Text(L(Self.titleKey(for: kind)))
            .font(Theme.font(.caption))
            .foregroundStyle(tone(for: kind))
            .frame(width: 44, alignment: .leading)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.hair)
            .background(Theme.surface(.raised))
            .clipShape(RoundedRectangle(cornerRadius: Radius.badge))
    }

    private func tone(for kind: ObjectSearch.Kind) -> Color {
        switch kind {
        case .table: return Theme.categorical(.blue)
        case .view: return Theme.categorical(.teal)
        case .column: return Theme.categorical(.amber)
        case .function: return Theme.categorical(.magenta)
        case .other: return Theme.text(.tertiary)
        }
    }

    private static func titleKey(for kind: ObjectSearch.Kind) -> LKey {
        switch kind {
        case .table: return .objectSearchKindTable
        case .view: return .objectSearchKindView
        case .column: return .objectSearchKindColumn
        case .function: return .objectSearchKindFunction
        case .other: return .objectSearchKindOther
        }
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: Spacing.s) {
            // 元数据到顶：醒目但不用红色 —— 结果本身仍然可用，只是可能不全。
            if let outcome, outcome.isTruncated {
                Label(L(.objectSearchTruncated), systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(L(.objectSearchBrowse)) { browseSelected() }
                .disabled(!canBrowse)

            Button(L(.commonClose)) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - 动作

    private func search(_ needle: String) async {
        isSearching = true
        searchError = nil
        defer { isSearching = false }

        do {
            let result = try await appState.searchObjects(needle)
            // 期间用户又改了关键词：这份结果已经作废，写进去只会闪一下旧内容。
            guard !Task.isCancelled else { return }
            outcome = result
            // 结果换了，原来的选中项可能已经不在列表里 —— 留着它，
            // 「浏览数据」会作用在一个用户已经看不到的对象上。
            selected = nil
        } catch {
            guard !Task.isCancelled else { return }
            outcome = nil
            selected = nil
            searchError = ErrorPresenter.message(for: error)
        }
    }

    private func browseSelected() {
        guard let hit = selected?.hit else { return }
        appState.browseSearchHit(schema: hit.schema, name: hit.name)
        // 关掉面板：新页签在它后面，留着面板的话"点了什么也没看见"。
        dismiss()
    }
}
