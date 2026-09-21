import Foundation
import Combine
import PostgresClientCore

/// 语言管理：读取 / 保存用户选择，并在切换时通知界面重建。
///
/// 视图通过全局函数 `L(...)` 取文案；语言切换时根视图会按 `.id(language)` 整体重建，
/// 因此无需每个视图单独订阅。
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private static let storageKey = "app.language"

    @Published private(set) var language: AppLanguage

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let stored = AppLanguage(rawValue: raw) {
            language = stored
        } else {
            language = .systemDefault
        }
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        UserDefaults.standard.set(newLanguage.rawValue, forKey: Self.storageKey)
    }

    func text(_ key: LKey, arguments: [CVarArg]) -> String {
        let template = LocalizedStrings.text(key, language: language)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: language.locale, arguments: arguments)
    }
}

/// 取当前语言文案；带参数时按当前语言格式化。
func L(_ key: LKey, _ arguments: CVarArg...) -> String {
    LocalizationManager.shared.text(key, arguments: arguments)
}
