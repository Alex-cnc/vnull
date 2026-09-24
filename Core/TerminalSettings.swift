import Foundation

/// 终端外观偏好（FR-EDIT-29）：跟随系统 / 总是深色 / 总是浅色。
///
/// 为什么需要它：终端跟随系统外观是对的默认，但**深色终端在浅色界面里是很多人的偏好**
/// （长时间看 shell 输出，浅底更刺眼）。两套色板都已经有对比度门槛，所以"选哪一套"
/// 只是偏好问题 —— 但偏好必须能持久化、能在重启后还原，且**不给系统外观变化添乱**。
public enum TerminalAppearance: String, CaseIterable, Codable, Sendable {
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

    /// 从偏好里读回来。**未知值回落到"跟随系统"**，不抛错 ——
    /// 偏好文件被手改、或版本降级后读到新值，都不该让界面起不来（与强调色、活动栏同一纪律）。
    public static func resolve(rawValue: String?) -> TerminalAppearance {
        guard let rawValue, let value = TerminalAppearance(rawValue: rawValue) else { return .followSystem }
        return value
    }

    /// 该用哪套色板。
    public func palette(systemIsDark: Bool) -> TerminalPalette {
        TerminalPalette.standard(dark: resolvesToDark(systemIsDark: systemIsDark))
    }

    /// 命令行 / 排障用的短名（界面文案在 `LKey`，这里不掺本地化）。
    public var rawValueForDisplay: String { rawValue }
}

/// 终端字号（FR-EDIT-29 的后续）：独立于界面字号，可调但**有上下限**。
///
/// 上下限不是"限制自由"，而是防两类事故：
/// - 太小（< 9pt）：等宽字体在 Retina 上糊成一团，且格子宽度会被取整吃掉，行会错位；
/// - 太大（> 20pt）：一行放不下几个字符，PTY 会被重分成两三个字符宽，TUI 直接不可用。
///
/// 夹取逻辑放 Core 是为了**界面、偏好读取、命令行三处共用同一个口径** ——
/// 与 `KeepAlivePolicy.minimumIntervalSeconds` 同一条纪律：不在界面里再写一份字面量。
public enum TerminalFontSize {

    public static let minimum: Int = 9
    public static let maximum: Int = 20
    public static let `default`: Int = 12

    /// 把任意整数夹进 `minimum...maximum`。
    public static func clamped(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    /// 是否已经是合法值（偏好校验、单测用）。
    public static func isValid(_ value: Int) -> Bool {
        (minimum...maximum).contains(value)
    }

    /// 从偏好里读回来：越界 / 缺省 / 类型不对都回落默认值。
    public static func resolve(rawValue: Any?) -> Int {
        guard let number = rawValue as? Int else { return `default` }
        return clamped(number)
    }
}
