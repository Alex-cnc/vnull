import Foundation

public enum AppError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case notConnected
    case notImplemented(String)
    case keychain(OSStatus)
    case persistence(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return "连接配置无效：\(reason)"
        case .notConnected:
            return "当前没有已建立的数据库连接"
        case .notImplemented(let feature):
            return "功能尚未实现：\(feature)"
        case .keychain(let status):
            return "Keychain 操作失败，OSStatus = \(status)"
        case .persistence(let reason):
            return "本地配置读写失败：\(reason)"
        case .queryFailed(let message):
            return "SQL 执行失败：\(message)"
        }
    }
}
