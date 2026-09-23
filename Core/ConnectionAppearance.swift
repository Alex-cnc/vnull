import Foundation

/// 连接的环境标签与自定义颜色（FR-CONN-16）。
///
/// 这一条的目的只有一个：**别连错库**。生产库上误敲一条 `DELETE` 的代价，
/// 与"多花两秒看一眼标签"完全不对称 —— 所以标签不只是装饰，它要
/// ① 在**所有**显示连接名的地方都出现（侧边栏、上下文栏、审批单），
/// ② 并且**参与安全判定**：生产标签下高危确认不能被关掉（见 `ExecutionSafetyPolicy`）。
public enum ConnectionEnvironment: String, CaseIterable, Codable, Sendable {
    case production
    case staging
    case testing
    case development

    /// 语义色角色（Core 只给角色，具体颜色由平台层的令牌表给）。
    ///
    /// 生产用**危险色**不是"好看"：整屏里唯一一个红点，扫一眼就知道自己在哪台库上。
    public var tone: StatusTone {
        switch self {
        case .production: return .danger
        case .staging: return .warning
        case .testing: return .success
        case .development: return .success
        }
    }

    public var isProduction: Bool { self == .production }

    /// 是否建议只读（生产 / 预发）。
    public var recommendsReadOnly: Bool {
        self == .production || self == .staging
    }

    /// 界面上显示的文案键（Core 给键、App 用 `L(...)` 取文案）。
    public var labelKey: LKey {
        switch self {
        case .production: return .connectionEnvProduction
        case .staging: return .connectionEnvStaging
        case .testing: return .connectionEnvTesting
        case .development: return .connectionEnvDevelopment
        }
    }

    /// 排在前面的是更需要警惕的 —— 下拉框按这个顺序，生产不会藏在最后。
    public static var orderedForPick: [ConnectionEnvironment] {
        [.production, .staging, .testing, .development]
    }
}

/// 连接的显示摘要：**一处算出"该显示什么、用什么颜色"**，各处照用。
///
/// 为什么不让每个视图自己拼：侧边栏、上下文栏、审批单三处都要显示同一个东西，
/// 各自拼一次必然出现"侧栏标了生产、上下文栏没标"—— 而这条需求的核心恰恰是**一致**。
public struct ConnectionAppearance: Equatable, Sendable {
    public var environment: ConnectionEnvironment?
    /// 用户自选的颜色（`CategoricalTone` 的名字；Core 只存名字，颜色在平台层）。
    public var colorTag: CategoricalTone?

    public init(environment: ConnectionEnvironment? = nil, colorTag: CategoricalTone? = nil) {
        self.environment = environment
        self.colorTag = colorTag
    }

    /// 环境标签优先于自选色：**安全信息不能被自定义色盖掉**。
    public var tone: StatusTone? { environment?.tone }

    /// 侧边栏 / 上下文栏左侧那条 2pt 色条该用什么颜色。
    ///
    /// 优先级：环境标签 > 自选色 > 无（不画条）。
    public var accent: ConnectionAccentRole? {
        if let tone { return .status(tone) }
        if let colorTag { return .categorical(colorTag) }
        return nil
    }

    /// 需要在界面上显示环境徽标吗。
    public var showsEnvironmentBadge: Bool { environment != nil }

    public var isProduction: Bool { environment?.isProduction ?? false }
}

/// 色条的语义角色（Core 不碰具体颜色值）。
public enum ConnectionAccentRole: Equatable, Sendable {
    case status(StatusTone)
    case categorical(CategoricalTone)
}
