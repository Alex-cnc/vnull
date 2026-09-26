import Foundation
import DoyahCore

/// 把底层错误转成适合直接展示给用户的文本（按当前界面语言）。
/// AppError 走本地化文案；Core 的 `LocalizedError` 取它的可读说明；其他错误保留反射详情。
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
            case .credentialStore(let code):
                return L(.errorKeychain, code)
            case .persistence(let reason):
                return L(.errorPersistence, reason)
            case .queryFailed(let message):
                return L(.errorQueryFailed, message)
            }
        }

        // Core 里那些 `LocalizedError`（目录授权、任务执行、模型通道…）自带**可读说明**与
        // 补救建议；不取它而走反射，界面上就会出现 `bookmarkCreationFailed(reason: "…")`
        // 这种给不了用户任何帮助的东西。AppError 已在上面单独处理，不受影响。
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        // 连接失败（R-46 / FR-META-10）：驱动抛的是 `PSQLError(code: server, serverInfo: […])`
        // 这种给不了帮助的东西，映射成人话 + 一句排查建议再显示。
        if let failure = ConnectionFailure.describe(error) {
            if let suggestion = failure.suggestion {
                return "\(failure.summary)\n\(suggestion)"
            }
            return failure.summary
        }

        // 驱动报的错、但**不是连接类**（R-60）：中性归因（用户取消 / 主动断开 / 协议层…），
        // 逐码一句自己的实话，**不说「连接失败」那套方向**。这里**必须把原始串带上** ——
        // 没这一步，App 在「未知码」这条路上会比改动前少给信息（以前落到底部的反射详情）。
        if let neutral = ConnectionFailure.describeNonConnection(error, language: LocalizationManager.shared.language) {
            var lines = [neutral.summary]
            if let suggestion = neutral.suggestion { lines.append(suggestion) }
            lines.append("（技术细节：\(String(reflecting: error))）")
            return lines.joined(separator: "\n")
        }

        let detail = String(reflecting: error)
        if detail.count > 800 {
            return String(detail.prefix(800)) + "…"
        }
        return detail
    }
}
