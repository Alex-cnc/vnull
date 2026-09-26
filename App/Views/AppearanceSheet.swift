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
    /// 订阅字体偏好（FR-EDIT-26）：改完立即反映到预览与界面。
    @ObservedObject private var fonts = FontManager.shared
    /// 手输的字体族（FR-EDIT-26 补充）：系统列表只列**等宽**族，但用户机器上
    /// 可能装了列表认不出来的等宽字体（字体元数据里 `isFixedPitch` 没标对），手输是唯一出路。
    @State private var typedFamily: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // 四段内容加起来会比屏幕矮不少，给个上限并允许滚动 ——
            // 否则小屏上「关闭」按钮会被顶出可视区（这条是面板变长之后必须补的）。
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    themeSection
                    Divider()
                    accentSection
                    Divider()
                    fontSection
                    Divider()
                    terminalSection
                }
            }
            .frame(maxHeight: 560)
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

    // MARK: 主题（FR-EDIT-26）

    /// 主题三态。与终端配色是**两个偏好**：这里管整个界面，终端那一段允许单独覆盖。
    private var themeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.appearanceThemeSection))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            Picker("", selection: $appState.appearanceMode) {
                ForEach(AppearancePreference.allCases, id: \.self) { mode in
                    // 复用终端那三个档位的文案：三态是同一个概念，不该有两套说法。
                    Text(L(Self.label(for: mode))).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(L(.appearanceThemeHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    // MARK: 字体（FR-EDIT-26）

    /// 等宽字体族与字号。**族在编辑器与终端之间共用**（字形要一致），
    /// 字号则各有各的：编辑器用这里的，终端在本面板下一段单独设。
    private var fontSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.appearanceFontSection))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            Picker(L(.appearanceMonoFamily), selection: familyBinding) {
                Text(L(.appearanceMonoSystem)).tag(String?.none)
                ForEach(FontManager.availableMonospacedFamilies, id: \.self) { family in
                    Text(family).tag(String?.some(family))
                }
            }

            // 手输字体族：列表里没有、但你确定它是等宽的字体，可以在这里直接写族名。
            HStack(spacing: Spacing.s) {
                TextField(L(.appearanceMonoFamilyCustom), text: $typedFamily)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyTypedFamily() }
                Button(L(.appearanceMonoApply)) { applyTypedFamily() }
                    .disabled(typedFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // 当前**实际生效**的字体：选了什么、最后用了什么，必须能看出来。
            Text(L(.appearanceMonoEffective, fonts.resolution.effectiveFamily ?? L(.appearanceMonoSystem)))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            Stepper(
                L(.appearanceMonoSize, fonts.preference.size),
                value: sizeBinding,
                in: MonospaceFontSize.minimum...MonospaceFontSize.maximum
            )

            if let requested = fonts.resolution.requestedFamily {
                // 两种"没生效"要说清楚：**根本不存在** vs **存在但不是等宽**。
                // 后者更严重（列会对歪、终端格子会错），文案不能与前者混成一句。
                let key: LKey = {
                    if case .notMonospaced = fonts.resolution { return .appearanceMonoNotMonospaced }
                    return .appearanceMonoFallback
                }()
                Text(L(key, requested))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L(.appearanceMonoHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .fixedSize(horizontal: false, vertical: true)

            // 预览：用**当前字体**画一行 SQL —— 选完立刻看到字形与字号。
            Text("select id, name from orders where total > 100;")
                .font(Theme.font(.mono))
                .foregroundStyle(Theme.terminalColor(
                    AppState.systemIsDarkAppearance
                        ? TerminalPalette.deepSeaDark.foreground
                        : TerminalPalette.deepSeaLight.foreground
                ))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
                .background(Theme.surface(.content))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Theme.hairline(scheme), lineWidth: Metrics.hairline)
                )
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    /// 应用手输的字体族：原样存用户的选择（判定与回落交给 `FontManager` / Core），
    /// 这样"打错一个字"不会把偏好改坏 —— 用户改回正确名字就立刻生效。
    private func applyTypedFamily() {
        let trimmed = typedFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        fonts.select(family: trimmed)
    }

    private var cursorStyleBinding: Binding<TerminalCursorStyle> {
        Binding(
            get: { appState.terminalCursorPreference.appearance.style },
            set: { style in
                appState.terminalCursorPreference = TerminalCursorPreference(
                    appearance: TerminalCursorAppearance(
                        style: style,
                        blinks: appState.terminalCursorPreference.appearance.blinks
                    )
                )
            }
        )
    }

    private var cursorBlinkBinding: Binding<Bool> {
        Binding(
            get: { appState.terminalCursorPreference.appearance.blinks },
            set: { blinks in
                appState.terminalCursorPreference = TerminalCursorPreference(
                    appearance: TerminalCursorAppearance(
                        style: appState.terminalCursorPreference.appearance.style,
                        blinks: blinks
                    )
                )
            }
        )
    }

    /// 字体族绑定：`FontManager` 是 `private(set)`，改写走它的方法（也顺手落盘）。
    private var familyBinding: Binding<String?> {
        Binding(
            get: { fonts.preference.family },
            set: { fonts.select(family: $0) }
        )
    }

    private var sizeBinding: Binding<Int> {
        Binding(
            get: { fonts.preference.size },
            set: { fonts.setSize($0) }
        )
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

            // 光标形状（FR-EDIT-29）：前台程序用 DECSCUSR 要求过时以它为准，这里设的是默认。
            HStack(spacing: Spacing.m) {
                Text(L(.terminalCursorStyle))
                    .font(Theme.font(.body))
                Picker("", selection: cursorStyleBinding) {
                    ForEach(TerminalCursorStyle.allCases, id: \.self) { style in
                        Text(style.label(language: LocalizationManager.shared.effectiveLanguage)).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Toggle(L(.terminalCursorBlink), isOn: cursorBlinkBinding)
                    .font(Theme.font(.caption))
                Spacer()
            }
            Text(L(.terminalCursorHint))
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
