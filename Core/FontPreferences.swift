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
        switch resolution(availableMonospacedFamilies: availableFamilies) {
        case .resolved(let family): return (family, false)
        case .systemDefault: return (nil, false)
        case .unknownFamily, .notMonospaced: return (nil, true)
        }
    }

    /// 完整判定：**三档而不是两档**。
    ///
    /// 手输字体族（FR-EDIT-26 的补充）让"不在列表里"分成两种完全不同的情况：
    /// - `unknownFamily`：系统里根本没有这个族（打字打错、字体被卸载）→ 回落系统等宽，提示"不可用"；
    /// - `notMonospaced`：这个族**存在但不是等宽**（例如有人手输 `Helvetica`）→ 同样回落，但提示必须更重 ——
    ///   等宽是画格子、对齐列、算终端单元格宽度的前提，用了比例字体列会歪、终端格子会错。
    ///   把它与"不可用"混成一句说，用户会一直以为自己选对了。
    public func resolution(
        availableMonospacedFamilies: [String],
        allFamilies: [String] = []
    ) -> MonospaceFontResolution {
        guard let family else { return .systemDefault }
        if let match = Self.match(family, in: availableMonospacedFamilies) {
            return .resolved(family: match)
        }
        if let existing = Self.match(family, in: allFamilies) {
            return .notMonospaced(requested: existing)
        }
        return .unknownFamily(requested: family)
    }

    /// 族名匹配：不区分大小写（用户输入 / 系统列表 / 旧偏好的大小写不总一致）。
    static func match(_ family: String, in families: [String]) -> String? {
        families.first { $0.caseInsensitiveCompare(family) == .orderedSame }
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

/// 等宽字体偏好的解析结果（FR-EDIT-26）。
///
/// 放在 Core 而不是界面里：**"这行字到底用哪个字体"是产品语义**（列对齐、终端格子都依赖它），
/// 判断要能被单测钉住；界面只负责把 `needsWarning` 对应的那句话显示出来。
public enum MonospaceFontResolution: Equatable, Sendable {
    /// 没选族 = 系统等宽（`NSFont.monospacedSystemFont`）。
    case systemDefault
    /// 选中了可用的等宽族（给出系统里那个**正确大小写**的名字）。
    case resolved(family: String)
    /// 系统里没有这个族。
    case unknownFamily(requested: String)
    /// 系统里有这个族，但它**不是等宽** —— 会破坏列对齐与终端网格。
    case notMonospaced(requested: String)

    /// 实际生效的族；`nil` = 系统等宽。
    public var effectiveFamily: String? {
        if case .resolved(let family) = self { return family }
        return nil
    }

    /// 是否要额外提示（前两档不用说话）。
    public var needsWarning: Bool {
        switch self {
        case .systemDefault, .resolved: return false
        case .unknownFamily, .notMonospaced: return true
        }
    }

    /// 用户想用的那个名字（用于文案）。
    public var requestedFamily: String? {
        switch self {
        case .unknownFamily(let requested), .notMonospaced(let requested): return requested
        default: return nil
        }
    }
}
