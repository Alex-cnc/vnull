import AppKit
import Combine
import DoyahCore
import SwiftUI

/// 强调色的运行时状态（FR-EDIT-33）。
///
/// 与 `LocalizationManager` 同构：单例 `ObservableObject` + `UserDefaults` 持久化，
/// 视图不必逐个订阅。选中的强调色通过**根视图的 `.tint(...)`** 下发 ——
/// 这样按钮、选中态、焦点环会自动跟着走，不需要在上百处视图里逐个替换 `Color.accentColor`。
///
/// 这也回答了"可配置"这件事的落点：强调色既是**设计令牌**（`Core/AccentTheme`），
/// 又是**用户偏好**（本文件），两者通过 id 关联 —— 所以换主题不需要改任何视图代码。
final class AccentManager: ObservableObject {

    static let shared = AccentManager()

    /// 当前强调色。改动只经由 `select(_:)`，避免出现"界面变了但没落盘"的状态。
    @Published private(set) var theme: AccentTheme

    private init() {
        theme = AccentTheme.resolve(id: UserDefaults.standard.string(forKey: AccentTheme.Storage.key))
    }

    /// 选择强调色（写盘 + 通知界面）。
    func select(_ theme: AccentTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        UserDefaults.standard.set(theme.id, forKey: AccentTheme.Storage.key)
    }

    /// 主色：选中条 / 图标 / 焦点环 / 淡填充底色。
    var accentColor: Color { Color(nsColor: Self.dynamic(theme.accentHex)) }

    /// 同上的 `NSColor` 形态（AppKit 自绘视图用，如结果表选中条）。
    var accentNSColor: NSColor { Self.dynamic(theme.accentHex) }

    /// 实心按钮的填充色（已压暗到白字能过 WCAG AA，见 `AccentTheme` 的注释）。
    var fillColor: Color { Color(nsColor: Self.dynamic(theme.fillHex)) }

    /// 淡填充（选中行底色）。深色下给得稍重一点，否则在深底上几乎看不见。
    func tint(_ scheme: ColorScheme, opacity: Double = 0.14) -> Color {
        accentColor.opacity(scheme == .dark ? opacity : opacity * 0.7)
    }

    /// 动态色：跟随系统外观自动解析。
    ///
    /// 三个候选目前深浅两套用同一个值（强调色本身是品牌色，不随明暗改变）；
    /// 保留这个结构是为了将来真要按外观微调时，不必再改所有调用点。
    static func dynamic(_ hex: UInt32) -> NSColor {
        let (red, green, blue) = AccentTheme.components(hex)
        let color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        return NSColor(name: nil) { _ in color }
    }
}
