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
