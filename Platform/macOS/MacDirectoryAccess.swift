import Foundation

import DoyahCore

/// macOS 侧的目录授权门面：把 Core 里**平台中立**的 `SecureDirectoryAccess`
/// 绑定到 Foundation 的安全作用域书签实现上。
///
/// 存在的意义是给平台适配层一个**单一的缝**：
///   · Core 侧不再有默认参数指向某个平台实现（原来 4 个函数都默认
///     `FoundationSecurityScopedBookmarking()`，等于把 macOS 焊死在 Core 里）；
///   · 上层（App）只认这个门面，不需要在每个调用点都知道书签是怎么实现的；
///   · Linux 侧写一个同名职责的门面（直接路径、无沙箱），上层代码形态一致。
///
/// 需求书 §10.9 P-03；概要设计 §3 平台适配层契约。
public enum MacDirectoryAccess {

    /// 平台适配器。测试可另建门面或直接调 `SecureDirectoryAccess.*` 注入假实现。
    public static let bookmarking: any SecurityScopedBookmarking = FoundationSecurityScopedBookmarking()

    public static func makeBookmark(
        for directory: URL,
        displayName: String? = nil,
        fileManager: FileManager = .default
    ) throws -> DirectoryBookmark {
        try SecureDirectoryAccess.makeBookmark(
            for: directory,
            displayName: displayName,
            bookmarking: bookmarking,
            fileManager: fileManager
        )
    }

    public static func status(
        for bookmark: DirectoryBookmark,
        fileManager: FileManager = .default
    ) -> DirectoryAccessStatus {
        SecureDirectoryAccess.status(for: bookmark, bookmarking: bookmarking, fileManager: fileManager)
    }

    public static func open(
        _ bookmark: DirectoryBookmark,
        fileManager: FileManager = .default
    ) throws -> DirectoryGrant {
        try SecureDirectoryAccess.open(bookmark, bookmarking: bookmarking, fileManager: fileManager)
    }

    public static func requestExportSettings(
        prompt: String = "选择任务产物的导出目录",
        format: DataTaskDefinition.ExportSettings.Format = .csv,
        fileNameTemplate: String? = nil,
        picker: any DirectoryPicker,
        fileManager: FileManager = .default
    ) throws -> DataTaskDefinition.ExportSettings? {
        try SecureDirectoryAccess.requestExportSettings(
            prompt: prompt,
            format: format,
            fileNameTemplate: fileNameTemplate,
            picker: picker,
            bookmarking: bookmarking,
            fileManager: fileManager
        )
    }

    /// 从任务导出设置恢复书签 —— 纯数据变换，与平台无关，直接转给 Core。
    public static func bookmark(
        from settings: DataTaskDefinition.ExportSettings,
        displayName: String = "任务导出目录"
    ) -> DirectoryBookmark? {
        SecureDirectoryAccess.bookmark(from: settings, displayName: displayName)
    }
}
