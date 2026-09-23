import XCTest
@testable import DoyahCore

/// 终端启动目录的三级回退规则（实测背景：`open` 拉起时应用 cwd 是 `/`）。
final class TerminalWorkingDirectoryTests: XCTestCase {

    private func resolve(
        workspace: String? = nil,
        launch: String = "/",
        home: String = "/Users/me",
        usable: Set<String> = ["/Users/me", "/Users/me/work", "/tmp"]
    ) -> String {
        TerminalWorkingDirectory.resolve(
            workspace: workspace,
            launchDirectory: launch,
            home: home,
            isUsableDirectory: { usable.contains($0) }
        )
    }

    /// 最常见的情形：Finder 双击（cwd = `/`）→ 落到家目录，而不是根目录。
    func testRootLaunchDirectoryFallsBackToHome() {
        XCTAssertEqual(resolve(launch: "/"), "/Users/me")
    }

    /// 从命令行在某个目录里启动 → 跟启动目录（需求提出者的诉求）。
    func testLaunchDirectoryWinsWhenMeaningful() {
        XCTAssertEqual(resolve(launch: "/Users/me/work"), "/Users/me/work")
    }

    /// 工作区优先级最高（左侧 Explorer 设置之后）。
    func testWorkspaceBeatsLaunchDirectory() {
        XCTAssertEqual(
            resolve(workspace: "/tmp", launch: "/Users/me/work"),
            "/tmp"
        )
    }

    func testBlankWorkspaceIsIgnored() {
        XCTAssertEqual(resolve(workspace: "   ", launch: "/Users/me/work"), "/Users/me/work")
    }

    func testUnusableWorkspaceIsIgnored() {
        XCTAssertEqual(
            resolve(workspace: "/does/not/exist", launch: "/Users/me/work"),
            "/Users/me/work"
        )
    }

    /// 启动目录不可读（例如被删掉的临时目录）→ 退回家目录。
    func testUnusableLaunchDirectoryFallsBackToHome() {
        XCTAssertEqual(resolve(launch: "/gone"), "/Users/me")
    }

    /// 家目录也不可用时不要假装成功：原样返回启动目录，让 shell 自己报错。
    func testFallsBackToLaunchDirectoryWhenNothingUsable() {
        XCTAssertEqual(resolve(launch: "/gone", usable: []), "/gone")
    }

    func testEmptyLaunchDirectoryFallsBackToHome() {
        XCTAssertEqual(resolve(launch: "", usable: ["/Users/me"]), "/Users/me")
    }
}
