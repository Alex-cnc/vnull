import SwiftUI
import DoyahCore

/// 命令面板（FR-EDIT-25）：⌘K 唤起，输入即筛，↑↓ 选择，↩ 执行。
///
/// 设计取舍：
/// - **命令清单在 App 侧**（`AppCommandCatalog`），Core 只做匹配排序 —— Core 不做本地化。
/// - 面板本身**不执行任何动作**，只把选中的命令 id 交回 `AppState`；
///   动作的实现仍留在它们原本的地方（工具栏按钮调的是同一批）。
/// - 空查询时**把所有命令列出来**：面板的第一用途是"看看有什么能做"。
struct CommandPaletteView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    private var matches: [CommandPalette.Match] {
        CommandPalette.search(query, in: AppCommandCatalog.all(), limit: 40)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.text(.tertiary))
                TextField(L(.commandPalettePlaceholder), text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.font(.body))
                    .focused($isSearchFocused)
                    .onSubmit { run(matches[safe: selectedIndex]) }
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
            }
            .padding(Spacing.m)

            HairlineView()

            if matches.isEmpty {
                Text(L(.commandPaletteNoMatch))
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text(.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.item.id) { index, match in
                                row(match: match, index: index)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
            }

            HairlineView()
            HStack(spacing: Spacing.s) {
                Text(L(.commandPaletteHint))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                Spacer()
                Text("\(matches.count)")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
        }
        .frame(width: 560, height: 420)
        .background(Theme.surface(.panel))
        .onAppear { isSearchFocused = true }
        // ↑↓ 与 Esc：面板自己的键盘语义，不走全局快捷键表。
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, max(matches.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func row(match: CommandPalette.Match, index: Int) -> some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(match.item.title)
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text(.primary))
                if let category = match.item.category {
                    Text(category)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.tertiary))
                }
            }
            Spacer()
            if let shortcut = AppCommandCatalog.shortcutHint(for: match.item.id) {
                Text(shortcut)
                    .font(Theme.font(.monoSmall))
                    .foregroundStyle(Theme.text(.tertiary))
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index == selectedIndex ? Theme.accentColor.opacity(Theme.isDarkAppearance ? Overlay.Selection.darkAlpha : Overlay.Selection.lightAlpha) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { run(match) }
    }

    private func run(_ match: CommandPalette.Match?) {
        guard let match else { return }
        dismiss()
        appState.performPaletteCommand(match.item.id)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
