import Foundation

import DoyahCore

/// macOS 侧的目录持久授权实现：Foundation 的 security-scoped bookmark。
///
/// **为什么在平台模块**：`bookmarkData(options: .withSecurityScope)`、
/// `URL(resolvingBookmarkData:options:)` 与 `startAccessingSecurityScopedResource()`
/// 都是 macOS 专属的 Foundation API，Core 里出现它们，Linux 就编译不过。
///
/// Linux 侧没有沙箱与安全作用域，直接记路径即可 —— 但**必须实现同一个协议**
/// （需求书 §10.9 P-03），否则「授权只能由用户选择产生」「跨启动可恢复」「失效给可读提示」
/// 这三条语义会在两个平台上各写一套、各漏一点。
public struct FoundationSecurityScopedBookmarking: SecurityScopedBookmarking {
    public init() {}

    /// 生成书签：**先试安全作用域，失败则退回普通书签**。
    ///
    /// 为什么必须有这个退回（实测，2026-09-23）：在**非沙箱**构建里
    /// `bookmarkData(options: .withSecurityScope)` 会失败并抛
    /// `bookmarkCreationFailed(reason: "未能打开该文件。")`。
    /// 而本工程日常用的正是非沙箱构建（终端要跑 dsh-tui，见 T-38）——
    /// 没有退回，工作区在那个构建里**根本选不了目录**，而且报的还是一句
    /// 与真实原因毫不相干的"未能打开该文件"。
    ///
    /// 语义上这也说得通：非沙箱进程本来就能访问用户选过的路径，
    /// 不需要（也无法）用沙箱授权去"圈住"它；普通书签足以承载"用户曾经选过这个目录"
    /// 与"目录被移动后仍能跟随"这两件事。
    public func makeBookmark(for directory: URL) throws -> Data {
        do {
            return try directory.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // 退回普通书签；两条路都失败才是真的失败。
            do {
                return try directory.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                throw DirectoryAccessError.bookmarkCreationFailed(
                    reason: "\(error.localizedDescription)（安全作用域与普通书签均失败）"
                )
            }
        }
    }

    /// 解析书签：**两种书签都要能解**。
    ///
    /// 实测（2026-09-23）：用 `.withSecurityScope` 去解析一个**普通**书签会失败并抛
    /// "The file couldn't be opened because it isn't in the correct format."；
    /// 反之亦然。所以先按安全作用域解、失败再按普通解 ——
    /// 否则会出现"沙箱构建里能用、非沙箱构建里读不回来"这种只在一种构建里发作的问题。
    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (url, isStale)
        }
        var plainStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &plainStale
        )
        return (url, plainStale)
    }

    /// 说明：非沙箱进程里对普通文件 URL 调用会返回 `false`，但这**不代表没有权限**。
    /// 因此调用方不能把 `false` 当作「被拒绝」——真正的判断依据是目录是否存在可读写。
    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
