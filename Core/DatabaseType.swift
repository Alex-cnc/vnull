import Foundation

public enum DatabaseType: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case postgresql
    case gbase8a

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgresql:
            return "PostgreSQL"
        case .gbase8a:
            return "GBase 8a"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgresql:
            return 5432
        case .gbase8a:
            return 5258
        }
    }

    public var defaultSSLMode: SSLMode {
        switch self {
        case .postgresql:
            return .prefer
        case .gbase8a:
            return .disable
        }
    }

    public var defaultSchema: String? {
        switch self {
        case .postgresql:
            return "public"
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
