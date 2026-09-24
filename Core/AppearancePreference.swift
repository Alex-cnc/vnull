import Foundation

/// 外观偏好：跟随系统 / 总是浅色 / 总是深色（FR-EDIT-26 的主题设置）。
///
/// **一份实现，两个消费者**：整个 App 的主题（FR-EDIT-26）与内嵌终端（FR-EDIT-29）。
/// 之所以不各写一份：三态的解析规则（`resolvesToDark`）与持久化契约（`rawValue`）
/// 一旦分叉，就会出现"界面跟随系统、终端不跟随"这种没人能解释的行为。
public enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case followSystem
    case alwaysDark
    case alwaysLight

    /// 系统当前是深色时，这个偏好的最终结果是不是深色（纯函数，可单测）。
    public func resolvesToDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .followSystem: return systemIsDark
        case .alwaysDark: return true
        case .alwaysLight: return false
        }
    }

    /// 给 SwiftUI 的形态：`nil` 表示"跟随系统"（交给 `.preferredColorScheme(nil)`）。
    ///
    /// 放在 Core 而不是视图里：这样"哪一档等于跟随系统"只有一个答案，
    /// 视图不必自己再写一次 switch（写错就会变成"选跟随系统却锁成浅色"）。
    public var forcedDark: Bool? {
        switch self {
        case .followSystem: return nil
        case .alwaysDark: return true
        case .alwaysLight: return false
        }
    }

    /// 从偏好里读回来。**未知值回落到「跟随系统」**，不抛错 ——
    /// 偏好文件被手改、或版本降级后读到新值，都不该让界面起不来（与强调色、活动栏同一纪律）。
    public static func resolve(rawValue: String?) -> AppearancePreference {
        guard let rawValue, let value = AppearancePreference(rawValue: rawValue) else { return .followSystem }
        return value
    }

    /// 终端色板按它取（FR-EDIT-29）。
    public func palette(systemIsDark: Bool) -> TerminalPalette {
        TerminalPalette.standard(dark: resolvesToDark(systemIsDark: systemIsDark))
    }

    /// 持久化键：键名本身是契约（改了等于让用户偏好失效），所以和类型放在一起。
    public enum Storage {
        /// 应用主题（FR-EDIT-26）。
        public static let appKey = "appearance.mode"
        /// 终端配色（FR-EDIT-29）。与主题分开：终端允许单独覆盖。
        public static let terminalKey = "terminal.appearance"
    }
}

/// 终端用同一个类型。保留这个名字是因为调用点（终端面板、色板命令）已经有它了 ——
/// 而"终端的外观偏好"与"应用的主题偏好"本来就是同一个三态。
public typealias TerminalAppearance = AppearancePreference
