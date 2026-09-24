import Foundation

/// 等宽面的字号（FR-EDIT-26）：编辑器、结果数值、内嵌终端**共用一套上下限**。
///
/// 上下限不是"限制自由"，而是防两类事故：
/// - 太小（< 9pt）：等宽字体在 Retina 上糊成一团，且格子宽度会被取整吃掉，行会错位；
/// - 太大（> 20pt）：一行放不下几个字符，终端会把 PTY 重分成两三个字符宽，TUI 直接不可用。
///
/// 夹取逻辑放 Core 是为了**界面、偏好读取、命令行三处共用同一个口径** ——
/// 与 `KeepAlivePolicy.minimumIntervalSeconds` 同一条纪律：不在界面里再写一份字面量。
public enum MonospaceFontSize {

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

/// 终端字号 = 同一套上下限（历史名字，保留以免调用点遍地改）。
public typealias TerminalFontSize = MonospaceFontSize

/// 等宽字体偏好（FR-EDIT-26）：**字体族可选、字号可调**。
///
/// 为什么"字体族"是 `String?` 而不是枚举：用户机器上装了什么字体只有 AppKit 知道
/// （`NSFontManager`），Core 不该去猜；这里只保存**用户的选择**，由 App 层把
/// "可用字体族列表"喂进来（`resolved(availableFamilies:)`），Core 负责判定与回落。
public struct MonospaceFontPreference: Equatable, Sendable {

    /// 用户选的字体族；`nil` = 系统等宽（`NSFont.monospacedSystemFont`）。
    public var family: String?
    /// 字号（pt），总是已夹取过的合法值。
    public var size: Int

    public init(family: String? = nil, size: Int = MonospaceFontSize.default) {
        self.family = Self.normalized(family)
        self.size = MonospaceFontSize.clamped(size)
    }

    public static let `default` = MonospaceFontPreference()

    /// 空白字符串按"没选"处理 —— `UserDefaults` 里存了 `""` 与没存过应当同义。
    public static func normalized(_ family: String?) -> String? {
        guard let family else { return nil }
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 从偏好里读回来（缺省 / 越界 / 类型不对都回落，不让界面起不来）。
    public static func resolve(family: Any?, size: Any?) -> MonospaceFontPreference {
        MonospaceFontPreference(
            family: normalized(family as? String),
            size: MonospaceFontSize.resolve(rawValue: size)
        )
    }

    /// 族解析：用户选的字体族**不在可用列表里**就回落到系统等宽，并如实报告。
    ///
    /// 为什么"如实报告"而不是静默回落：用户以为自己在用 Menlo、实际在用系统等宽，
    /// 这种差异只有说出来才查得到（换机器、字体被卸载都会触发）。
    public func resolved(availableFamilies: [String]) -> (family: String?, didFallBack: Bool) {
        guard let family else { return (nil, false) }
        // 家族名比较不区分大小写：不同来源（用户输入 / 系统列表 / 旧偏好）大小写不总一致。
        let match = availableFamilies.first { $0.caseInsensitiveCompare(family) == .orderedSame }
        guard let match else { return (nil, true) }
        return (match, false)
    }

    /// 换字号（夹取后返回新值，供界面直接写回偏好）。
    public func withSize(_ newSize: Int) -> MonospaceFontPreference {
        MonospaceFontPreference(family: family, size: MonospaceFontSize.clamped(newSize))
    }

    /// 换字体族。
    public func withFamily(_ newFamily: String?) -> MonospaceFontPreference {
        MonospaceFontPreference(family: newFamily, size: size)
    }

    /// 持久化键：键名是契约，和类型放一起。
    public enum Storage {
        public static let familyKey = "font.monoFamily"
        public static let sizeKey = "font.monoSize"
    }
}
