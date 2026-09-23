import XCTest
@testable import DoyahCore

/// 归档位置判定（FR-EDIT-31 + FR-EDIT-32 衔接）的单测。
///
/// 守的是一个很容易含糊的优先级：**用户单独指定 > 工作区 > 没有**。
/// 含糊的后果是"归档怎么没写进我以为的目录"，而那种问题在界面上很难一眼看出来。
final class ArchiveLocationTests: XCTestCase {

    func testChosenDirectoryWinsOverWorkspace() {
        let resolved = ArchiveLocation.root(chosenPath: "/tmp/archive", workspacePath: "/tmp/project")
        XCTAssertEqual(resolved?.url.path, "/tmp/archive")
        XCTAssertEqual(resolved?.source, .chosen)
    }

    func testFallsBackToWorkspace() {
        let resolved = ArchiveLocation.root(chosenPath: nil, workspacePath: "/tmp/project")
        XCTAssertEqual(resolved?.url.path, "/tmp/project")
        XCTAssertEqual(resolved?.source, .workspace)
    }

    func testNoLocationWhenNeitherIsSet() {
        XCTAssertNil(ArchiveLocation.root(chosenPath: nil, workspacePath: nil))
        XCTAssertNil(ArchiveLocation.queriesDirectory(chosenPath: nil, workspacePath: nil))
    }

    /// 空白字符串必须按"没给"处理：配置文件被手改成空白时不能当成一个目录。
    func testBlankPathsAreTreatedAsMissing() {
        XCTAssertEqual(ArchiveLocation.root(chosenPath: "   ", workspacePath: "/tmp/project")?.source, .workspace)
        XCTAssertEqual(ArchiveLocation.root(chosenPath: "\n", workspacePath: "  ")?.source, nil)
    }

    /// 归档写在根目录下的 `queries/`：跟随工作区之后这条更重要 ——
    /// 工作区是用户的项目目录，直接往根上撒 `.sql` 会把人烦死。
    func testQueriesSubdirectory() {
        let resolved = ArchiveLocation.queriesDirectory(chosenPath: nil, workspacePath: "/tmp/project")
        XCTAssertEqual(resolved?.url.path, "/tmp/project/queries")
        XCTAssertEqual(resolved?.source, .workspace)

        let chosen = ArchiveLocation.queriesDirectory(chosenPath: "/tmp/archive", workspacePath: "/tmp/project")
        XCTAssertEqual(chosen?.url.path, "/tmp/archive/queries")
        XCTAssertEqual(chosen?.source, .chosen)
    }

    func testPathsAreTrimmed() {
        XCTAssertEqual(
            ArchiveLocation.root(chosenPath: "  /tmp/archive  ", workspacePath: nil)?.url.path,
            "/tmp/archive"
        )
    }
}

/// 工作区按文件名搜索的单测。
///
/// 这里守的是"有界"：忽略名单、深度上限、结果上限、不跟随符号链接。
/// 没有这些界，界面上就会变成"选了个大目录之后搜索卡死"。
final class WorkspaceSearchTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doyah-search-test-\(UUID().uuidString)")
        let fileManager = FileManager.default
        for directory in ["Core", "Core/Deep", "Core/Deep/Deeper", "Docs", "node_modules"] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true
            )
        }
        try "x".write(to: root.appendingPathComponent("AgentSQLGenerator.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("Core/agentLoop.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("Core/Deep/agentDeep.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("Core/Deep/Deeper/agentTooDeep.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("node_modules/agentInDeps.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("Docs/readme.md"), atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/etc")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFindsMatchesCaseInsensitively() {
        let result = WorkspaceSearch.findFileNames(in: root, query: "agent")
        let names = result.entries.map(\.name).sorted()
        // 默认深度上限（8）足以覆盖测试目录的全部层级
        XCTAssertEqual(names, ["AgentSQLGenerator.swift", "agentDeep.swift", "agentLoop.swift", "agentTooDeep.swift"])
        XCTAssertFalse(result.isTruncated)
    }

    func testIgnoresIgnoredDirectories() {
        let names = WorkspaceSearch.findFileNames(in: root, query: "agent").entries.map(\.name)
        XCTAssertFalse(names.contains("agentInDeps.swift"), "忽略名单里的目录不该被搜")
    }

    /// 深度上限：更深的那一层不出现（防止把工作区选到 `/` 或家目录后卡死）。
    func testRespectsDepthLimit() {
        let shallow = WorkspaceSearch.findFileNames(in: root, query: "agent", maxDepth: 2).entries.map(\.name)
        XCTAssertFalse(shallow.contains("agentTooDeep.swift"))
        let deep = WorkspaceSearch.findFileNames(in: root, query: "agent", maxDepth: 8).entries.map(\.name)
        XCTAssertTrue(deep.contains("agentTooDeep.swift"))
    }

    /// 结果上限：命中过多时**停下并如实标记**，而不是悄悄截断。
    func testResultLimitIsReported() {
        let result = WorkspaceSearch.findFileNames(in: root, query: "agent", limit: 2)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.isTruncated)
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(WorkspaceSearch.findFileNames(in: root, query: "   ").entries.isEmpty)
    }

    func testResultsCarryRelativePaths() {
        let entries = WorkspaceSearch.findFileNames(in: root, query: "agentLoop").entries
        XCTAssertEqual(entries.first?.relativePath, "Core/agentLoop.swift")
    }

    /// **回归**：相对路径必须始终相对工作区根。
    ///
    /// 曾经写错成"相对被列出的那一层"，于是深层条目拿到 `Deep` 这样的路径，
    /// 而它同时是展开状态的键与路径解析的输入 —— 展开第二层时会去 `<根>/Deep` 找目录，
    /// 找不到、列表空掉。自检探针当时只展开了一层，所以没拦住。
    func testNestedRelativePathsAreAlwaysRelativeToTheWorkspaceRoot() throws {
        let core = root.appendingPathComponent("Core")
        let entries = try WorkspaceTree.children(of: core, relativeTo: root)
        let deep = entries.first { $0.name == "Deep" }
        XCTAssertEqual(deep?.relativePath, "Core/Deep")
        // 用这个路径能解析回同一个目录（两处逻辑必须自洽）
        XCTAssertEqual(
            WorkspaceTree.resolve(relativePath: "Core/Deep", in: root)?.standardizedFileURL.path,
            core.appendingPathComponent("Deep").standardizedFileURL.path
        )
        // 不传 relativeTo 时退化为"相对被列出的那一层"（保持向后兼容）
        XCTAssertEqual(try WorkspaceTree.children(of: core).first { $0.name == "Deep" }?.relativePath, "Deep")
    }

    /// 相对路径必须能用 `WorkspaceTree.resolve` 还原回工作区内的位置（两处逻辑要对得上）。
    func testResultsResolveBackInsideTheWorkspace() {
        for entry in WorkspaceSearch.findFileNames(in: root, query: "agent").entries {
            let url = WorkspaceTree.resolve(relativePath: entry.relativePath, in: root)
            XCTAssertNotNil(url, "\(entry.relativePath) 无法解析")
            XCTAssertTrue(url!.path.hasPrefix(root.standardizedFileURL.path))
        }
    }
}
