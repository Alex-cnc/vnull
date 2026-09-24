import DoyahCore
import SwiftUI

/// 「外观」面板（FR-EDIT-33）：选强调色。
///
/// 关键设计：**每一项都画出真实效果**，而不是只给一块色卡 ——
/// 选中行（淡填充 + 左侧 2pt 强调条）、主按钮（实心填充 + 白字）、焦点环，
/// 这三个正是强调色在整个界面里**唯一**会出现的地方。
/// 用户看到的就是以后每天看到的东西，选色不再是"凭想象"。
///
/// 本文件也是**令牌层的第一块迁移样板**：间距 / 圆角 / 字号 / 发丝线全部取自
/// `Spacing` / `Radius` / `Theme`，没有任何裸数字与裸颜色
/// （由 `Scripts/check-design-tokens.py` 的棘轮守着）。
struct AppearanceSheet: View {

    @EnvironmentObject private var accent: AccentManager
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            accentSection
            Divider()
            terminalSection
            Divider()
            footer
        }
        .frame(width: 560)
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(.appearanceTitle))
                .font(Theme.font(.title))
            Text(L(.appearanceThemeNote))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    // MARK: 强调色

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.appearanceAccentSection))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            ForEach(AccentTheme.all) { theme in
                AccentOptionRow(theme: theme, isSelected: theme == accent.theme) {
                    accent.select(theme)
                }
            }

            Text(L(.appearanceAccentHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    // MARK: 终端（FR-EDIT-29）

    /// 终端的**配色与字号**：终端可以独立于界面外观 —— 浅色界面里配深色终端是很多人的偏好
    /// （长时间看 shell 输出，浅底更刺眼）。两套色板各有对比度门槛，所以这里只是"选哪一套"。
    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.appearanceTerminalSection))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            Picker("", selection: $appState.terminalAppearance) {
                ForEach(TerminalAppearance.allCases, id: \.self) { value in
                    Text(L(Self.label(for: value))).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Stepper(
                L(.terminalFontSizeLabel, appState.terminalFontSize),
                value: $appState.terminalFontSize,
                in: TerminalFontSize.minimum...TerminalFontSize.maximum
            )

            Text(L(.terminalFontSizeHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .fixedSize(horizontal: false, vertical: true)

            terminalPreview

            Text(L(.terminalAppearanceHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    private static func label(for appearance: TerminalAppearance) -> LKey {
        switch appearance {
        case .followSystem: return .terminalAppearanceFollowSystem
        case .alwaysDark: return .terminalAppearanceAlwaysDark
        case .alwaysLight: return .terminalAppearanceAlwaysLight
        }
    }

    /// 配色预览：**用真实色板画**，选完立刻变 —— 不让用户凭想象选配色。
    private var terminalPreview: some View {
        let palette = appState.terminalAppearance.palette(systemIsDark: AppState.systemIsDarkAppearance)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(.terminalPreviewHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("doyah@studio ~ % ls --color")
                    .font(Theme.font(.mono))
                    .foregroundStyle(Theme.terminalColor(palette.foreground))

                swatches(palette, indices: Array(0..<8), tone: .terminalPreviewNormal)
                swatches(palette, indices: Array(8..<16), tone: .terminalPreviewBright)

                HStack(spacing: Spacing.s) {
                    Text(L(.terminalPreviewDim))
                        .font(Theme.font(.mono))
                        .foregroundStyle(Theme.terminalColor(palette.dimmed(palette.foreground)))
                    Text(L(.terminalPreviewSelection))
                        .font(Theme.font(.mono))
                        .foregroundStyle(Theme.terminalColor(palette.foreground))
                        .padding(.horizontal, Spacing.xs)
                        .background(Theme.terminalColor(palette.selectionBackground))
                    Text("▌")
                        .font(Theme.font(.mono))
                        .foregroundStyle(Theme.terminalColor(palette.cursor))
                    Spacer(minLength: 0)
                }
            }
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.terminalColor(palette.background))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Theme.hairline(scheme), lineWidth: Metrics.hairline)
            )
        }
    }

    private func swatches(
        _ palette: TerminalPalette,
        indices: [Int],
        tone: LKey
    ) -> some View {
        HStack(spacing: Spacing.s) {
            Text(L(tone))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .frame(width: 52, alignment: .leading)
            ForEach(indices, id: \.self) { index in
                Text("●")
                    .font(Theme.font(.mono))
                    .foregroundStyle(Theme.terminalColor(palette.ansi[index]))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Spacer()
            Button(L(.commonClose)) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
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
            HStack(alignment: .center, spacing: Spacing.m) {
                // 选中标记 + 色点 + 名称
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(Theme.font(.body))
                    .foregroundStyle(isSelected ? accentColor : Theme.text(.tertiary))

                Circle()
                    .fill(accentColor)
                    .frame(width: 14, height: 14)

                Text(L(theme.nameKey))
                    .font(isSelected ? Theme.font(.bodyStrong) : Theme.font(.body))
                    .frame(width: 78, alignment: .leading)

                preview
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(isSelected ? tintColor : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        isSelected ? accentColor.opacity(0.55) : Theme.hairline(scheme),
                        lineWidth: Metrics.hairline
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 三个真实场景：选中行 / 主按钮 / 焦点环。
    private var preview: some View {
        HStack(spacing: Spacing.s) {
            // 选中行：淡填充 + 左侧强调条
            HStack(spacing: Spacing.hair) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: Spacing.hair, height: 14)
                RoundedRectangle(cornerRadius: Radius.badge, style: .continuous)
                    .fill(tintColor)
                    .frame(width: 46, height: 14)
            }

            // 主按钮：实心填充 + 白字
            Text(L(theme.nameKey).prefix(2))
                .font(Theme.font(.caption))
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.hair)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(fillColor))

            // 焦点环
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(accentColor, lineWidth: 1.5)
                .frame(width: 34, height: 18)
        }
        .opacity(0.95)
    }
}
