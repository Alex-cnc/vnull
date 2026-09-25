import DoyahCore
import SwiftUI

/// 最左侧的活动栏（FR-EDIT-32）—— 窄的固定宽度竖条，切换右侧面板。
///
/// 信息架构上它把两件事分开了：**「看哪个视图」**（本组件）与**「视图里看什么」**（右侧面板）。
/// 好处是将来加搜索 / Git / 扩展时只加一个切换项，不动布局。
///
/// 视觉规范（与外观方案一致，逐条都有理由）：
///   · 宽度与图标尺寸取自 `Metrics`，不写字面量；
///   · 选中态 = **左侧 2pt 强调条 + 图标提亮**，不铺整块背景 ——
///     46pt 宽的窄条上铺背景会显得很脏，而且会和右侧面板的选中态抢视觉；
///   · 未选中用 `text(.tertiary)`，悬停才给一点极淡的底 —— 静止时应当是安静的；
///   · 底部「账户 / 设置」是**动作**不是视图（`ActivityBarAction`），故没有选中态。
struct ActivityBarView: View {

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accent: AccentManager
    @Environment(\.colorScheme) private var scheme

    @State private var hoveredItem: ActivityBarItem?

    var body: some View {
        VStack(spacing: 0) {
            // **按许可证显示**（FR-LIC-02）：未授权的区不是灰掉，而是不出现 ——
            // 所以这里必须用 `visibleActivityItems` 而不是 `allCases`。
            // 忘了改这一行，Standard 用户就会看到两个点了没反应的图标（比"看不到"更糟）。
            ForEach(appState.visibleActivityItems) { item in
                viewButton(item)
            }

            Spacer(minLength: Spacing.s)

            // 底部动作与视图之间用发丝线分开：它们是两类东西
            Rectangle()
                .fill(Theme.hairline(scheme))
                .frame(height: Metrics.hairline)
                .padding(.horizontal, Spacing.s)

            ForEach(ActivityBarAction.allCases) { action in
                actionButton(action)
            }
        }
        .frame(width: Metrics.activityBarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.surface(.window))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.hairline(scheme))
                .frame(width: Metrics.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(activityBarLabel)
    }

    /// 无障碍标签也要跟着许可证走：写死"数据库 / 工作区"会让 Standard 用户的读屏
    /// 念出两个根本不存在的区。
    private var activityBarLabel: String {
        appState.visibleActivityItems.map { L($0.titleKey) }.joined(separator: " / ")
    }

    // MARK: 视图切换项

    private func viewButton(_ item: ActivityBarItem) -> some View {
        let isSelected = appState.selectedActivityItem == item
        let isHovered = hoveredItem == item

        return Button {
            // 走 AppState 的统一入口：它会再过一遍许可证（这里已经在可见列表里，
            // 但保持"只有一个写入口"这条结构，将来加别的来源也不会漏）。
            appState.selectActivityItem(item)
        } label: {
            ZStack(alignment: .leading) {
                // 选中：左侧强调条
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.hairline, style: .continuous)
                        .fill(accent.accentColor)
                        .frame(width: Spacing.hair, height: 26)
                }
                // 悬停：极淡的底（未选中时才给，避免和选中态混淆）
                if isHovered && !isSelected {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Theme.text(.primary).opacity(0.06))
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, Spacing.xs)
                }
                Image(systemName: item.symbolName)
                    .font(.system(size: Metrics.activityIconSize * 0.85, weight: .regular))
                    .foregroundStyle(isSelected ? Theme.text(.primary) : Theme.text(.tertiary))
                    .frame(maxWidth: .infinity)
            }
            .frame(height: Metrics.toolbarHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
            }
        }
        .help(L(item.titleKey))
        .accessibilityLabel(L(item.titleKey))
        .accessibilityIdentifier("activity-bar-\(item.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: 底部动作

    private func actionButton(_ action: ActivityBarAction) -> some View {
        Button {
            switch action {
            case .account:
                // 语义未定（R-23）：只放占位，不实现登录流程 —— 宁可诚实地说明，也不做假的登录页。
                appState.isAccountNoticePresented = true
            case .settings:
                appState.isAppearancePresented = true
            }
        } label: {
            Image(systemName: action.symbolName)
                .font(.system(size: Metrics.activityIconSize * 0.85, weight: .regular))
                .foregroundStyle(Theme.text(.tertiary))
                .frame(width: Metrics.activityBarWidth, height: Metrics.toolbarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(action.titleKey))
        .accessibilityLabel(L(action.titleKey))
        .accessibilityIdentifier("activity-bar-\(action.rawValue)")
    }
}
