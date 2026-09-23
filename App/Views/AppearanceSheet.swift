import DoyahCore
import SwiftUI

/// 「外观」面板（FR-EDIT-33）：选强调色。
///
/// 关键设计：**每一项都画出真实效果**，而不是只给一块色卡 ——
/// 选中行（淡填充 + 左侧 2pt 强调条）、主按钮（实心填充 + 白字）、焦点环，
/// 这三个正是强调色在整个界面里**唯一**会出现的地方。
/// 用户看到的就是以后每天看到的东西，选色不再是"凭想象"。
struct AppearanceSheet: View {

    @EnvironmentObject private var accent: AccentManager
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            accentSection
            Divider()
            footer
        }
        .frame(width: 560)
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.appearanceTitle))
                .font(.system(size: 15, weight: .semibold))
            Text(L(.appearanceThemeNote))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: 强调色

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(.appearanceAccentSection))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(AccentTheme.all) { theme in
                AccentOptionRow(theme: theme, isSelected: theme == accent.theme) {
                    accent.select(theme)
                }
            }

            Text(L(.appearanceAccentHint))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Spacer()
            Button(L(.commonClose)) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// 一个强调色候选：左边是名字与选中标记，右边是三个真实使用场景的预览。
private struct AccentOptionRow: View {

    let theme: AccentTheme
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var accentColor: Color { Color(nsColor: AccentManager.dynamic(theme.accentHex)) }
    private var fillColor: Color { Color(nsColor: AccentManager.dynamic(theme.fillHex)) }
    private var tintColor: Color { accentColor.opacity(scheme == .dark ? 0.16 : 0.11) }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 14) {
                // 选中标记 + 色点 + 名称
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? accentColor : Color.secondary.opacity(0.5))

                Circle()
                    .fill(accentColor)
                    .frame(width: 14, height: 14)

                Text(L(theme.nameKey))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .frame(width: 78, alignment: .leading)

                preview
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? tintColor : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? accentColor.opacity(0.55) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 三个真实场景：选中行 / 主按钮 / 焦点环。
    private var preview: some View {
        HStack(spacing: 10) {
            // 选中行：淡填充 + 左侧 2pt 强调条
            HStack(spacing: 6) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 2, height: 14)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tintColor)
                    .frame(width: 46, height: 14)
            }

            // 主按钮：实心填充 + 白字
            Text(L(theme.nameKey).prefix(2))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fillColor))

            // 焦点环
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(accentColor, lineWidth: 1.5)
                .frame(width: 34, height: 18)
        }
        .opacity(0.95)
    }
}
