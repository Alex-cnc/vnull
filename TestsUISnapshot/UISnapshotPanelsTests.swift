import SwiftUI
import XCTest

import DoyahCore
@testable import DoyahStudioApp

/// **界面快照 · 第二批：侧栏与面板的空态**（队列 L-11）。
///
/// L-01 那批覆盖的是「有内容」的界面（三档活动栏 / Home 空态 / 结果表 / ER 图初始态）。
/// 本批补的是 spec §5.2 里那批**只能靠人工点开才看得到**的面板空态 ——
/// 想拿到它们，人得先点开菜单、再截图；离屏渲染不需要任何人到场：
///
///   · 连接列表空态（`FR-CONN-*`：一条连接都没有时侧栏该说什么）
///   · 对象树空态（没选连接时树该说什么）
///   · 智能体审计空态（`FR-AI-13`：没有审计记录时）
///   · 维护面板空态（`FR-DB-*`：没有维护计划时）
///
/// **分批**：L-11 条目按「一批 4 个面板 × 深浅各一」推进，每批独立提交（见队列 L-11）。
/// 第二批（数据任务 / 导入 / 例行候选 / 会话）留待下一轮 —— 会话面板需要「可注入的数据口子」，
/// 那是 L-12 的范围，不在这里硬凑（见下方 `testPanelEmptyStates` 的注释）。
///
/// 三条纪律与 L-01 同源（见 `UISnapshotKit`）：不进每轮门禁、产物落 `.build/`、每张图都带断言。
final class UISnapshotPanelsTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            UISnapshot.isEnabled,
            "界面快照要显式打开：DOYAH_UI_SNAPSHOT=1（它是取证工具，不进每轮门禁）"
        )
    }

    // MARK: - 共用装配

    /// 侧栏视图（连接列表 / 对象树）的面积：按侧栏真实宽度取，高度给足几个分组。
    private let sidebarSize = CGSize(width: 320, height: 560)

    /// 一个**空态**宿主：工作区历史指到临时文件，且**显式**把连接清空。
    ///
    /// 为什么必须显式清空：`AppState.init` 会起一个 `Task` 读**用户真实**的连接档
    /// （`ConnectionStore.shared` → `~/Library/Application Support/DoyahStudio/connections.json`）。
    /// 本批要拍的是「一条连接都没有」这一态 —— 如果只是"碰巧还没加载完"，那这张图
    /// 下一轮可能就变成另一副样子了（不是可复现的证据）。测试体里没有 `await`，
    /// 主线程上的加载任务不会插进来，所以这里的清空在整张图的渲染期间一直成立。
    ///
    /// 读的是**只读**路径：全程不写用户数据、不连任何数据库。
    @MainActor
    private func makeEmptyHost() -> (
        state: AppState, workspace: WorkspaceStore, tabs: WorkspaceTabsModel, terminal: TerminalModel
    ) {
        let scratch = UISnapshot.outputDirectory.deletingLastPathComponent()
            .appendingPathComponent("ui-snapshot-scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let historyURL = scratch.appendingPathComponent("workspace-history-\(UUID().uuidString).json")

        let state = AppState()
        let workspace = WorkspaceStore.shared
        let tabs = WorkspaceTabsModel(store: WorkspaceHistoryStore(fileURL: historyURL))
        let terminal = TerminalModel()

        state.connections = []
        state.selectedConnectionID = nil
        return (state, workspace, tabs, terminal)
    }

    // MARK: - 一批四张（深浅各一）

    @MainActor
    func testPanelEmptyStates() throws {
        let host = makeEmptyHost()

        // 前置：这一批拍的**确实是空态**。三条断言都不成立的话，图再好看也没意义。
        XCTAssertTrue(host.state.connections.isEmpty, "本批要拍空态：连接列表必须为空")
        XCTAssertNil(host.state.selectedConnectionID, "本批要拍空态：不该有选中的连接")
        XCTAssertFalse(L(.connectionListEmpty).isEmpty, "空态文案缺失（语言表里没有 connectionListEmpty）")

        try snapshotLightAndDark("connection-list-empty", size: sidebarSize, host: host) {
            ConnectionListView(onAdd: {}, onEdit: { _ in })
        }

        try snapshotLightAndDark("object-tree-empty", size: sidebarSize, host: host) {
            ObjectTreeView()
        }

        // 审计空态：读审计档是只读的（`~/Library/Application Support/DoyahStudio/agent-audit.json`）。
        // 真机上已有记录时这里会先读到内容 —— 所以显式置空，让这张图**每次都是同一个态**。
        host.state.agentAuditRecords = []
        XCTAssertTrue(host.state.agentAuditRecords.isEmpty, "审计记录必须为空才能拍空态")
        try snapshotLightAndDark(
            "agent-audit-empty",
            size: CGSize(width: 940, height: 790),
            host: host
        ) {
            AgentAuditPanel()
        }

        // 维护面板空态：没有计划文本、也没有解析结果（`maintenanceReview == nil`）。
        host.state.maintenancePlanText = ""
        host.state.maintenanceReview = nil
        try snapshotLightAndDark(
            "maintenance-panel-empty",
            size: CGSize(width: 760, height: 680),
            host: host
        ) {
            MaintenancePanel()
        }
    }

    /// 同一张图拍浅色 / 深色两遍：深色一遍看的是**对比度与动态色**（L-13 记的另一半：
    /// 语言遍地还没成对，那是 L-13 的范围，这里不做）。
    @MainActor
    private func snapshotLightAndDark<V: View>(
        _ name: String,
        size: CGSize,
        host: (
            state: AppState, workspace: WorkspaceStore, tabs: WorkspaceTabsModel, terminal: TerminalModel
        ),
        @ViewBuilder content: () -> V
    ) throws {
        for scheme in [ColorScheme.light, .dark] {
            try UISnapshot.write(
                "\(name)\(scheme == .dark ? "-dark" : "")",
                size: size,
                scheme: scheme
            ) {
                content().snapshotEnvironment(
                    state: host.state,
                    workspace: host.workspace,
                    tabs: host.tabs,
                    terminal: host.terminal
                )
            }
        }
    }

    // MARK: - 清单

    override class func tearDown() {
        UISnapshot.finishManifestIfEnabled()
        super.tearDown()
    }
}
