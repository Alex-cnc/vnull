import SwiftUI
import DoyahCore

/// 连接的环境徽标（FR-CONN-16）。
///
/// **侧边栏、查询上下文栏、审批单显示的是同一个组件** —— 这条需求的核心就是"到处一致"，
/// 各自画一遍必然出现"侧栏标了生产、上下文栏没标"，而那种不一致恰好会让人连错库。
struct ConnectionEnvironmentBadge: View {
    let appearance: ConnectionAppearance

    /// 紧凑模式（上下文栏那种一行里已经很挤的地方）。
    var isCompact: Bool = false

    var body: some View {
        if let environment = appearance.environment {
            Label {
                Text(L(environment.labelKey))
                    .font(Theme.font(.caption))
            } icon: {
                Image(systemName: environment.isProduction ? "exclamationmark.triangle.fill" : "circle.fill")
                    .font(Theme.font(.caption))
            }
            .foregroundStyle(Theme.status(environment.tone))
            .padding(.horizontal, isCompact ? Spacing.xs : Spacing.s)
            .padding(.vertical, Spacing.hair)
            .background(
                RoundedRectangle(cornerRadius: Radius.badge)
                    .fill(Theme.status(environment.tone).opacity(
                        Theme.isDarkAppearance ? Overlay.Zebra.darkAlpha : Overlay.Zebra.lightAlpha
                    ))
            )
            .fixedSize()
            .help(environment.isProduction ? L(.connectionProductionBadgeHelp) : L(environment.labelKey))
        }
    }
}

/// 连接前的那条 2pt 色条（侧边栏 / 上下文栏共用）。
///
/// 颜色优先级由 Core 的 `ConnectionAppearance.accent` 决定（环境标签 > 自选色），
/// 视图只负责把语义角色翻成颜色。
struct ConnectionAccentBar: View {
    let appearance: ConnectionAppearance
    var height: CGFloat = 22

    var body: some View {
        if let role = appearance.accent {
            RoundedRectangle(cornerRadius: Radius.hairline)
                .fill(color(for: role))
                .frame(width: Spacing.hair, height: height)
        }
    }

    private func color(for role: ConnectionAccentRole) -> Color {
        switch role {
        case .status(let tone): return Theme.status(tone)
        case .categorical(let tone): return Theme.categorical(tone)
        }
    }
}
