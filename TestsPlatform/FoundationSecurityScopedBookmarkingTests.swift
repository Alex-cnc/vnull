import XCTest
import DoyahCore
import DoyahPlatform

/// 这条测试存在的理由很具体：**非沙箱进程里 `bookmarkData(options: .withSecurityScope)`
/// 会失败**（实测抛 "未能打开该文件"），而本工程日常用的正是非沙箱构建。
/// 没有"退回普通书签"那段逻辑时，工作区在那个构建里根本选不了目录 ——
/// 用真实 API 走一遍才能在单测里就把它拦住，而不是等用户去点。
final class SecurityScopedBookmarkingTests: XCTestCase {

    func testRealBookmarkRoundTripForTemporaryDirectory() throws {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doyah-bookmark-test-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let bookmarking = FoundationSecurityScopedBookmarking()
        let data = try bookmarking.makeBookmark(for: directory)

        let bookmark = DirectoryBookmark(displayName: "测试目录", bookmarkData: data, lastKnownPath: directory.path)
        let status = SecureDirectoryAccess.status(for: bookmark, bookmarking: bookmarking, fileManager: fileManager)
        guard case .granted(let path, let isStale) = status else {
            return XCTFail("真实书签应判定为可用，实得 \(status)")
        }
        // 书签解析出来的是**真实路径**：macOS 上 /var 是指向 /private/var 的符号链接，
        // 所以不能拿 NSTemporaryDirectory() 的字符串直接比（实测差异就在 /private 前缀）。
        XCTAssertEqual(
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
            directory.resolvingSymlinksInPath().path
        )
        XCTAssertFalse(isStale)

        // 取用（非沙箱下 startAccessing 可能返回 false —— 那不是失败，见实现注释）
        let grant = try SecureDirectoryAccess.open(bookmark, bookmarking: bookmarking, fileManager: fileManager)
        XCTAssertTrue(fileManager.fileExists(atPath: grant.url.path))
        grant.stopAccessing()
    }

    /// 目录被删除后必须**给出可读的结论**，不能崩、也不能静默当成可用。
    ///
    /// 实测：目录一旦不存在，Foundation **连解析都会失败**（"The file doesn't exist."），
    /// 所以结论是 `resolutionFailed` 而不是 `missing` —— `missing` 留给"能解析但路径不在"
    /// （例如所在卷被卸载、目录被改名）。这条差异原本很容易写错，
    /// 而界面上两者的补救动作是一样的：重新选择目录。
    func testDeletedDirectoryIsReportedAsUnusable() throws {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doyah-bookmark-gone-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let bookmarking = FoundationSecurityScopedBookmarking()
        let data = try bookmarking.makeBookmark(for: directory)
        let bookmark = DirectoryBookmark(displayName: "会被删掉的目录", bookmarkData: data)
        try fileManager.removeItem(at: directory)

        let status = SecureDirectoryAccess.status(for: bookmark, bookmarking: bookmarking, fileManager: fileManager)
        XCTAssertFalse(status.isUsable, "目录已删除时不得判定为可用")
        switch status {
        case .resolutionFailed, .missing:
            break
        default:
            XCTFail("目录已删除应判定为不可用（resolutionFailed / missing），实得 \(status)")
        }
    }
}
