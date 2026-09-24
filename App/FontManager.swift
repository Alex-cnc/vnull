import AppKit
import Combine
import DoyahCore
import SwiftUI

/// 等宽字体偏好的运行时状态（FR-EDIT-26）。
///
/// 与 `AccentManager` 同构：单例 `ObservableObject` + `UserDefaults` 持久化。
/// 为什么需要"运行时状态"而不是只读 `UserDefaults`：**AppKit 自绘视图**（编辑器、结果网格、
/// 终端）在 `draw` 里取字体，它们读不到 SwiftUI 的环境值；把它们统一到这一个入口，
/// 就不会出现"编辑器换了字体、结果表还是旧字体"。
///
/// 判定与回落都在 Core（`MonospaceFontPreference.resolved`），这里只负责：
/// ① 问系统有哪些等宽字体；② 存/读偏好；③ 交出 `NSFont`。
final class FontManager: ObservableObject {

    static let shared = FontManager()

    /// 当前偏好（字号总是已夹取的合法值）。
    @Published private(set) var preference: MonospaceFontPreference

    private init() {
        let defaults = UserDefaults.standard
        preference = MonospaceFontPreference.resolve(
            family: defaults.string(forKey: MonospaceFontPreference.Storage.familyKey),
            size: defaults.object(forKey: MonospaceFontPreference.Storage.sizeKey)
        )
    }

    // MARK: 可用字体

    /// 系统里可用的**等宽**字体族（按名字排序）。
    ///
    /// 只列等宽族：这个偏好只服务于编辑器 / 结果数值 / 终端 —— 列出一堆比例字体
    /// 只会让人误选（选了也会因为不是等宽而把列对齐搞坏）。
    static let availableMonospacedFamilies: [String] = {
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// 系统里**全部**字体族（判定"这个族到底存不存在"用 —— 存在但不是等宽是另一回事）。
    static let availableAllFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }

    /// 当前偏好的**完整判定**（系统等宽 / 命中 / 不存在 / 存在但非等宽）。
    var resolution: MonospaceFontResolution {
        preference.resolution(
            availableMonospacedFamilies: Self.availableMonospacedFamilies,
            allFamilies: Self.availableAllFamilies
        )
    }

    /// 实际生效的字体族（`nil` = 系统等宽）—— 与旧口径兼容的读法。
    var effectiveFamily: String? { resolution.effectiveFamily }

    /// 是否处于"选了但没生效"的状态（界面据此给一句可读提示）。
    var isFallingBack: Bool { resolution.needsWarning }

    // MARK: 修改

    func select(family: String?) {
        update(preference.withFamily(family))
    }

    func setSize(_ size: Int) {
        update(preference.withSize(size))
    }

    private func update(_ newValue: MonospaceFontPreference) {
        guard newValue != preference else { return }
        preference = newValue
        let defaults = UserDefaults.standard
        // 存**用户的选择**（`family` 原值），不存回落后的值 ——
        // 否则换一台装有该字体的机器时，偏好已经被悄悄改掉了。
        defaults.set(newValue.family ?? "", forKey: MonospaceFontPreference.Storage.familyKey)
        defaults.set(newValue.size, forKey: MonospaceFontPreference.Storage.sizeKey)
    }

    // MARK: 交付字体

    /// 等宽 `NSFont`：族 + 字号；族不可用时回落系统等宽。
    ///
    /// - Parameter size: 传 `nil` 用偏好里的字号（终端会传自己的字号：它允许单独设得小一点）。
    func monospaceNSFont(size: CGFloat? = nil) -> NSFont {
        let pointSize = size ?? CGFloat(preference.size)
        guard let family = resolution.effectiveFamily,
              let font = NSFont(name: family, size: pointSize) else {
            return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        }
        return font
    }

    /// 等宽粗体（终端画粗体字用；保持与正文字体同族）。
    func monospaceBoldNSFont(size: CGFloat) -> NSFont {
        guard let family = resolution.effectiveFamily,
              let font = NSFont(name: family, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
        // 家族里可能有独立的 Bold face；`NSFontManager` 负责转。
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        return bold
    }
}
