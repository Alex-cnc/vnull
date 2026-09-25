import Foundation

public enum DatabaseType: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case postgresql
    /// MySQL（FR-DRV-09）。GBase 8a 与它同属 MySQL 协议族，驱动共用一份、方言各自成对。
    case mysql
    case gbase8a

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgresql:
            return "PostgreSQL"
        case .mysql:
            return "MySQL"
        case .gbase8a:
            return "GBase 8a"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgresql:
            return 5432
        case .mysql:
            return 3306
        case .gbase8a:
            return 5258
        }
    }

    public var defaultSSLMode: SSLMode {
        switch self {
        case .postgresql:
            return .prefer
        case .mysql:
            return .prefer
        case .gbase8a:
            return .disable
        }
    }

    /// 这个方言**实际支持**的 SSL 模式（顺序即界面上的顺序）。
    ///
    /// 为什么必须有这一条（**R-53**，2026-09-25 界面实测：「MySQL 连接上出现了 PG 专属的 Allow」）：
    /// `SSLMode` 一份枚举服务三个方言，但 **`allow` 是 PostgreSQL 独有的** ——
    /// MySQL 的 `--ssl-mode` 只有 `DISABLED / PREFERRED / REQUIRED / VERIFY_CA / VERIFY_IDENTITY`。
    /// 更糟的是我们 MySQL 驱动把 `.allow` 与 `.prefer` / `.require` 放在同一分支（"加密但不校验证书"），
    /// 于是 MySQL 连接上选 `Allow` 时**标签写的是一个不存在的模式、行为却是 Require** —— 标签撒谎。
    /// 收窄列表比在文档里解释"这个选项其实没用"要诚实得多。
    public var sslModes: [SSLMode] {
        switch self {
        case .postgresql:
            return [.disable, .allow, .prefer, .require, .verifyCA, .verifyFull]
        case .mysql:
            return [.disable, .prefer, .require, .verifyCA, .verifyFull]
        case .gbase8a:
            // 同族（MySQL 协议）故同一份清单；**GBase 的 TLS 能力未实测**（无实例，见 FR-DRV-08），
            // 如实跟着同族走，不假装验过。
            return [.disable, .prefer, .require, .verifyCA, .verifyFull]
        }
    }

    /// 这个方言认不认这个模式。
    public func supports(_ mode: SSLMode) -> Bool {
        sslModes.contains(mode)
    }

    /// **数据库节点没有子节点时**该说哪句话（FR-META 的树空态）。
    ///
    /// 判据是"这个方言有没有 schema 层"，不是"它是不是 GBase"。
    /// 2026-09-25 需求提出者实测：以前只有 GBase 被特判，于是 **MySQL** 上打开一个空库会显示
    /// 「该数据库下暂无 schema」—— 对着一个**根本没有 schema 概念**的库说"暂无 schema"，
    /// 用户只会以为是自己建错了。MySQL / GBase（同族）都该说"暂无表 / 视图"。
    ///
    /// 用 `defaultSchema == nil` 当"没有 schema 层"的判据：它与树形结构用的是同一个事实
    /// （见 `defaultSchema` 的注释），不会两处打架。
    ///
    /// 键名里的 `GBase` 是历史（它最早只给 GBase 用），语义已经是"**没有 schema 层**的方言"。
    public var databaseNodeEmptyKey: LKey {
        defaultSchema == nil ? .treeEmptyDatabaseGBase : .treeEmptyDatabase
    }

    /// 把不属于这个方言的模式收敛到方言默认值，**并如实报告"改过"**。
    ///
    /// 不静默改配置：老配置（或手改过的文件）里可能存着 `allow`，界面得说一句
    /// "这个数据库类型不支持，已改为默认值"，否则用户会发现"我明明选的 Allow，怎么变成 Prefer 了"。
    public func normalizedSSLMode(_ mode: SSLMode) -> (mode: SSLMode, didChange: Bool) {
        if supports(mode) { return (mode, false) }
        return (defaultSSLMode, true)
    }

    public var defaultSchema: String? {
        switch self {
        case .postgresql:
            return "public"
        case .mysql:
            // MySQL 里 database 与 schema 是同一个东西：树形结构没有 schema 层。
            return nil
        case .gbase8a:
            return nil
        }
    }
}

public enum SSLMode: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case disable
    case allow
    case prefer
    case require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disable:
            return "Disable"
        case .allow:
            return "Allow"
        case .prefer:
            return "Prefer"
        case .require:
            return "Require"
        case .verifyCA:
            return "Verify CA"
        case .verifyFull:
            return "Verify Full"
        }
    }

    /// 在**某个方言**下的显示名（R-53）：`verify-full` 是 PostgreSQL 的叫法，
    /// MySQL 那一档叫 `VERIFY_IDENTITY`（要校验主机名）。同一个枚举、两个名字，
    /// 界面上必须按方言显示 —— 否则用户拿着 MySQL 去查 `verify-full` 会查不到东西。
    ///
    /// 名字保持协议原文（英文）：它们是**协议关键字**，翻译反而会让人对不上官方文档。
    public func displayName(for type: DatabaseType) -> String {
        switch (self, type) {
        case (.verifyFull, .mysql), (.verifyFull, .gbase8a):
            return "Verify Identity"
        default:
            return displayName
        }
    }
}

public struct SQLFeatureSet: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let supportsSchemas = SQLFeatureSet(rawValue: 1 << 0)
    public static let supportsTransactions = SQLFeatureSet(rawValue: 1 << 1)
    public static let supportsMultipleStatements = SQLFeatureSet(rawValue: 1 << 2)
    public static let supportsCustomDelimiter = SQLFeatureSet(rawValue: 1 << 3)
    public static let supportsSSL = SQLFeatureSet(rawValue: 1 << 4)
    public static let supportsExplain = SQLFeatureSet(rawValue: 1 << 5)
}

extension DatabaseType {
    /// 引擎徽标用的**身份色**（不是状态色：橙色在这里表示"这是 GBase"，不是"有问题"）。
    public var identityTone: CategoricalTone {
        switch self {
        case .postgresql: return .blue
        case .mysql: return .teal
        case .gbase8a: return .amber
        }
    }
}
