import XCTest
@testable import DoyahCore

/// 工作区页签的规则（FR-EDIT-35 / 36）。
final class WorkspaceTabTests: XCTestCase {

    func testOpeningSameFileReusesTab() {
        var tabs = [WorkspaceTab.home()]
        let first = WorkspaceTabSet.opening(path: "/tmp/a.js", in: tabs, content: "let a = 1")
        tabs = first.tabs
        XCTAssertEqual(tabs.count, 2)

        let second = WorkspaceTabSet.opening(path: "/tmp/a.js", in: tabs, content: "let a = 2")
        XCTAssertEqual(second.tabs.count, 2, "同一个文件不该开第二个页签")
        XCTAssertEqual(second.selected, first.selected)
        XCTAssertEqual(second.tabs[1].content, "let a = 1", "复用已有页签，不覆盖用户正在编辑的内容")
    }

    func testTabTitleIsFileNameAndLanguageIsDetected() {
        let tab = WorkspaceTab.file(path: "/Users/me/项目/query.sql", content: "select 1")
        XCTAssertEqual(tab.title, "query.sql")
        XCTAssertEqual(tab.language, .sql)
        XCTAssertFalse(tab.isHome)
    }

    /// Home 是工作区的落脚点：**关不掉**。
    func testHomeCannotBeClosed() {
        let home = WorkspaceTab.home()
        let file = WorkspaceTab.file(path: "/tmp/a.py", content: "")
        let remaining = WorkspaceTabSet.closing(id: home.id, in: [home, file])
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(WorkspaceTabSet.closing(id: file.id, in: [home, file]).count, 1)
    }

    /// 关闭后选中项落到右边（没有就左边）。
    func testSelectionAfterClosing() {
        let home = WorkspaceTab.home()
        let a = WorkspaceTab.file(path: "/tmp/a.js", content: "")
        let b = WorkspaceTab.file(path: "/tmp/b.js", content: "")
        let tabs = [home, a, b]
        XCTAssertEqual(WorkspaceTabSet.selection(afterClosing: a.id, in: tabs, selected: a.id), b.id)
        XCTAssertEqual(WorkspaceTabSet.selection(afterClosing: b.id, in: tabs, selected: b.id), a.id)
        // 关的不是当前选中项 → 选中项不变
        XCTAssertEqual(WorkspaceTabSet.selection(afterClosing: a.id, in: tabs, selected: b.id), b.id)
    }

    func testDirtyTracksContentNotABoolean() {
        var tab = WorkspaceTab.file(path: "/tmp/a.js", content: "let a = 1")
        XCTAssertFalse(tab.isDirty)
        tab.content = "let a = 2"
        XCTAssertTrue(tab.isDirty)
        tab.markSaved()
        XCTAssertFalse(tab.isDirty)
        tab.content = "let a = 3"
        XCTAssertTrue(tab.isDirty)
        // 手动改回**已保存的那份内容** → 自动不脏。
        // 布尔标记做不到这一条：它一旦置 true，用户把改动撤回去也还是"脏"。
        tab.content = "let a = 2"
        XCTAssertFalse(tab.isDirty)
    }
}

/// Home 的"最近打开"（FR-EDIT-35）。
final class WorkspaceHistoryTests: XCTestCase {

    func testRecordingFileMovesItToFrontAndDeduplicates() {
        var history = WorkspaceHistory()
        history = WorkspaceHistory.recording(file: "/a.js", into: history)
        history = WorkspaceHistory.recording(file: "/b.js", into: history)
        history = WorkspaceHistory.recording(file: "/a.js", into: history)
        XCTAssertEqual(history.files.map(\.path), ["/a.js", "/b.js"])
    }

    func testFileHistoryIsCapped() {
        var history = WorkspaceHistory()
        for index in 0..<(WorkspaceHistory.fileLimit + 5) {
            history = WorkspaceHistory.recording(file: "/file\(index).js", into: history)
        }
        XCTAssertEqual(history.files.count, WorkspaceHistory.fileLimit)
        XCTAssertEqual(history.files.first?.path, "/file\(WorkspaceHistory.fileLimit + 4).js")
    }

    func testWorkspaceHistoryIsSeparateFromFiles() {
        var history = WorkspaceHistory()
        history = WorkspaceHistory.recording(workspace: "/Users/me/project", into: history)
        XCTAssertEqual(history.workspaces.count, 1)
        XCTAssertTrue(history.files.isEmpty)
    }

    func testEmptyPathIsIgnored() {
        var history = WorkspaceHistory()
        history = WorkspaceHistory.recording(file: "   ", into: history)
        history = WorkspaceHistory.recording(workspace: "", into: history)
        XCTAssertTrue(history.files.isEmpty)
        XCTAssertTrue(history.workspaces.isEmpty)
    }

    func testRemovingEntries() {
        var history = WorkspaceHistory()
        history = WorkspaceHistory.recording(file: "/a.js", into: history)
        history = WorkspaceHistory.recording(file: "/b.js", into: history)
        history = WorkspaceHistory.removing(file: "/a.js", from: history)
        XCTAssertEqual(history.files.map(\.path), ["/b.js"])
    }

    /// 只记路径与时间 —— **不存文件内容**（否则这份历史会变成代码库的副本）。
    func testHistoryRoundTripsThroughJSONWithoutContent() throws {
        var history = WorkspaceHistory()
        history = WorkspaceHistory.recording(file: "/Users/me/project/index.ts", at: Date(timeIntervalSince1970: 1_700_000_000), into: history)
        let data = try JSONEncoder().encode(history)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("content"))
        let decoded = try JSONDecoder().decode(WorkspaceHistory.self, from: data)
        XCTAssertEqual(decoded, history)
        XCTAssertEqual(decoded.files.first?.displayName, "index.ts")
    }
}
