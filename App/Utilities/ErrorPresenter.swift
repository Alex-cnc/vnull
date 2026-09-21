import Foundation
import PostgresClientCore

/// 把底层错误转成适合直接展示给用户的文本（按当前界面语言）。
/// AppError 走本地化文案；其他错误保留反射详情，方便排查驱动层问题。
enum ErrorPresenter {
    static func message(for error: Error) -> String {
        if let appError = error as? AppError {
            switch appError {
            case .invalidConfiguration(let reason):
                return L(.errorInvalidConfiguration, reason)
            case .notConnected:
                return L(.errorNotConnected)
            case .notImplemented(let feature):
                return L(.errorNotImplemented, feature)
            case .keychain(let status):
                return L(.errorKeychain, status)
            case .persistence(let reason):
                return L(.errorPersistence, reason)
            case .queryFailed(let message):
                return L(.errorQueryFailed, message)
            }
        }

        let detail = String(reflecting: error)
        if detail.count > 800 {
            return String(detail.prefix(800)) + "…"
        }
        return detail
    }
}
