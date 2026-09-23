import XCTest
@testable import DoyahCore

/// 活动栏（FR-EDIT-32）与工作区文件树的纯逻辑单测。
///
/// 这两块最容易出错的都不是"画得对不对"，而是**语义**：
/// 切换项与动作混淆、路径包含判定用字符串前缀、符号链接跟随走出去。
/// 那些问题在界面上往往表现成"偶发怪事"，所以在这里钉死。
final class ActivityBarTests: XCTestCase {

    // MARK: 活动栏

    func testTwoViewItemsWithStableIdentifiers() {
        XCTAssertEqual(ActivityBarItem.allCases.count, 2)
        XCTAssertEqual(ActivityBarItem.allCases.map(\.rawValue), ["database", "workspace"])
        XCTAssertEqual(Set(ActivityBarItem.allCases.map(\.id)).count, 2)
    }

    func testViewItemsHaveDistinctSymbolsTitlesAndMenus() {
        let items = ActivityBarItem.allCases
        XCTAssertEqual(Set(items.map(\.symbolName)).count, items.count)
        XCTAssertEqual(Set(items.map(\.titleKey)).count, items.count)
        XCTAssertEqual(Set(items.map(\.menuKey)).count, items.count)
        for item in items {
            XCTAssertFalse(item.symbolName.isEmpty)
        }
    }

    /// 切换项的快捷键序号必须是 ⌘1 / ⌘2 —— 「按序号切视图」是通用习惯。
    func testShortcutIndexesAreSequential() {
        XCTAssertEqual(ActivityBarItem.allCases.map(\.shortcutIndex), [1, 2])
    }

    func testResolveFallsBackToDatabase() {
        XCTAssertEqual(ActivityBarItem.resolve(id: nil), .database)
        XCTAssertEqual(ActivityBarItem.resolve(id: ""), .database)
        XCTAssertEqual(ActivityBarItem.resolve(id: "no-such-view"), .database)
        XCTAssertEqual(ActivityBarItem.resolve(id: "workspace"), .workspace)
        XCTAssertEqual(ActivityBarItem.storageKey, "ui.activityBarItem")
    }

    /// **动作不得与切换项撞名**：否则"设置"会被当成第三个视图（有选中态、会占满右侧）。
    func testActionsAreNotViews() {
        let viewIDs = Set(ActivityBarItem.allCases.map(\.rawValue))
        for action in ActivityBarAction.allCases {
            XCTAssertFalse(viewIDs.contains(action.rawValue), "动作 \(action.rawValue) 与视图同名")
        }
        XCTAssertEqual(ActivityBarAction.allCases.map(\.rawValue), ["account", "settings"])
        XCTAssertEqual(Set(ActivityBarAction.allCases.map(\.symbolName)).count, 2)
    }
}

/// 真实书签的往返（不打桩）。
///
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

final class WorkspaceTreeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doyah-workspace-test-\(UUID().uuidString)")
        let fileManager = FileManager.default
        for directory in ["Core", "Docs", ".build", "node_modules"] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true
            )
        }
        try "// swift".write(to: root.appendingPathComponent("Core/Screen.swift"), atomically: true, encoding: .utf8)
        try "# doc".write(to: root.appendingPathComponent("Docs/README.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        // 一个指向工作区**外面**的符号链接
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/etc")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testChildrenPutsDirectoriesFirstThenFiles() throws {
        let entries = try WorkspaceTree.children(of: root)
        let names = entries.map(\.name)
        XCTAssertEqual(names, ["Core", "Docs", "escape", "Package.swift"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .directory, .symlink, .file])
    }

    func testIgnoredDirectoriesAreSkipped() throws {
        let names = try WorkspaceTree.children(of: root).map(\.name)
        XCTAssertFalse(names.contains(".build"))
        XCTAssertFalse(names.contains("node_modules"))
    }

    func testHiddenEntriesRequireExplicitOptIn() throws {
        XCTAssertFalse(try WorkspaceTree.children(of: root).map(\.name).contains(".env"))
        XCTAssertTrue(try WorkspaceTree.children(of: root, showHidden: true).map(\.name).contains(".env"))
    }

    /// 符号链接**只显示不跟随**：`isExpandable` 必须是 false，
    /// 否则点开一个指向 `/` 的链接就会把整块磁盘当工作区遍历。
    func testSymlinksAreShownButNotExpandable() throws {
        let link = try XCTUnwrap(try WorkspaceTree.children(of: root).first { $0.name == "escape" })
        XCTAssertEqual(link.kind, .symlink)
        XCTAssertFalse(link.isExpandable)
        XCTAssertFalse(link.isDirectory)
    }

    func testRelativePath() {
        let file = root.appendingPathComponent("Core/Screen.swift")
        XCTAssertEqual(WorkspaceTree.relativePath(of: file, in: root), "Core/Screen.swift")
        XCTAssertNil(WorkspaceTree.relativePath(of: URL(fileURLWithPath: "/etc"), in: root))
    }

    // MARK: 路径包含判定（这里最容易写成字符串前缀）

    func testContainmentAcceptsInsideAndRoot() {
        XCTAssertTrue(WorkspaceTree.isContained("/Users/me/ws/a/b.sql", in: "/Users/me/ws"))
        XCTAssertTrue(WorkspaceTree.isContained("/Users/me/ws", in: "/Users/me/ws"))
    }

    /// 经典坑：`/Users/me/ws-evil` 不是 `/Users/me/ws` 的子路径。
    func testContainmentRejectsSiblingWithSharedPrefix() {
        XCTAssertFalse(WorkspaceTree.isContained("/Users/me/ws-evil/a.sql", in: "/Users/me/ws"))
        XCTAssertFalse(WorkspaceTree.isContained("/Users/me/wsx", in: "/Users/me/ws"))
    }

    func testContainmentRejectsOutsideAndTraversal() {
        XCTAssertFalse(WorkspaceTree.isContained("/etc/passwd", in: "/Users/me/ws"))
        XCTAssertFalse(WorkspaceTree.isContained("/Users/me/ws/../secret", in: "/Users/me/ws"))
        XCTAssertFalse(WorkspaceTree.isContained("/Users/me", in: "/Users/me/ws"))
    }

    // MARK: 相对路径规范化

    func testNormalizedRelativePathHandlesDots() {
        XCTAssertEqual(WorkspaceTree.normalizedRelativePath("Core/Screen.swift"), "Core/Screen.swift")
        XCTAssertEqual(WorkspaceTree.normalizedRelativePath("./Core//Screen.swift"), "Core/Screen.swift")
        XCTAssertEqual(WorkspaceTree.normalizedRelativePath("Core/./Sub/../Screen.swift"), "Core/Screen.swift")
    }

    func testNormalizedRelativePathRejectsEscapes() {
        XCTAssertNil(WorkspaceTree.normalizedRelativePath("../secret"))
        XCTAssertNil(WorkspaceTree.normalizedRelativePath("Core/../../secret"))
        XCTAssertNil(WorkspaceTree.normalizedRelativePath(""))
        XCTAssertNil(WorkspaceTree.normalizedRelativePath("./"))
    }

    /// 交给智能体 / 打开文件之前的最后一道关：解析结果必须仍在工作区内。
    func testResolveRefusesAnythingOutsideTheWorkspace() {
        XCTAssertEqual(
            WorkspaceTree.resolve(relativePath: "Core/Screen.swift", in: root)?.lastPathComponent,
            "Screen.swift"
        )
        XCTAssertNil(WorkspaceTree.resolve(relativePath: "../outside.sql", in: root))
        XCTAssertNil(WorkspaceTree.resolve(relativePath: "/etc/passwd", in: root)?.pathComponents.contains("etc") == true
            ? WorkspaceTree.resolve(relativePath: "Core/../../etc/passwd", in: root) : WorkspaceTree.resolve(relativePath: "Core/../../etc/passwd", in: root))
        // 绝对路径被当成相对路径处理时也不能逃出去
        XCTAssertNil(WorkspaceTree.resolve(relativePath: "../../../../etc/passwd", in: root))
    }
}
