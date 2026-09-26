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
/// 第二批（`testPanelEmptyStatesBatchTwo`）：
///   · 数据任务空态（`FR-AI-05/06/08`：一条任务都没有）
///   · 导入空态（`FR-IO-03/06/07`：没选文件）
///   · 例行候选空态（`FR-AI-14/15`：一条候选都没有）
///   · 会话空态（`FR-SESS-01/02`：空列表）
///
/// **分批**：L-11 条目按「一批 4 个面板 × 深浅各一」推进，每批独立提交（见队列 L-11）。
/// 第二批 = `testPanelEmptyStatesBatchTwo`（数据任务 / 导入 / 例行候选 / 会话）。
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
    /// **第 11 轮更正（实测推翻）**：这段原写的「测试体里没有 `await`，主线程上的加载任务
    /// 不会插进来，所以这里的清空在整张图的渲染期间一直成立」**是错的** ——
    /// 离屏宿主的布局 / 绘制会泵一次运行循环，`.task` 里的加载**会跑完**。
    /// 实证：会话面板那张图里出现了 `Could not load sessions: No database connection is established`
    /// 这行红字 —— 它只可能由 `.task → reload()` 的 `catch` 写出，别处没有写它的路径。
    /// 所以空态能站稳靠的是「显式置空 **+ 渲染后再断言一遍」，不是「异步任务跑不起来」；
    /// 各面板的渲染后断言见 `testPanelEmptyStatesBatchTwo`。
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

    // MARK: - 一批四张（深浅各一）

    /// **第二批**：数据任务 / 导入 / 例行候选（记忆治理）/ 会话。
    ///
    /// 四条途径各不相同，所以「空态怎么造」也各不相同：
    ///   · **数据任务**（`FR-AI-05/06/08`）：列表来自 `appState.dataTasks` —— 直接摆空，
    ///     并让右侧停在「没有选中项」那一支（`dataTaskNoSelection`）；
    ///   · **导入**（`FR-IO-03/06/07`）：面板自持状态（没选文件 / 没解析），只需要把
    ///     `appState` 里的导入痕迹（日志 / 消息 / 错误 / 选中对象）清掉；
    ///   · **例行候选**（`FR-AI-14/15`）：报告为 `nil`（还没算过）时给的是「一条候选都没有」的文案；
    ///   · **会话**（`FR-SESS-01/02`）：`sessions` 是**私有 `@State`**，外面注不进去 ——
    ///     离屏拿到的只能是它自己那个初值分支（空列表）。**如实说明**：这张图里**两样东西同时在**——
    ///     ① 红色 `Could not load sessions: …`（`.task → reload()` 抛 `notConnected` 的分支，
    ///     说明离屏宿主里加载**真的跑过**）② 中间的空占位 `sessionEmpty`（`sessions.isEmpty` 那一支）。
    ///     也就是说它是「**没选连接**时的首次绘制」的**真运行态**；
    ///     而「连上服务器、这次查到 0 条会话」那个**纯空列表**态仍然拍不到，
    ///     要按需造态得先有**可注入口子** —— 那是 **L-12** 的范围。
    ///
    /// **本轮更正一条工具假设 + 新增一条纪律**：`.task` / `onAppear` 在离屏宿主里**是会跑的**
    /// （实证同上：那行红字只有 `reload()` 写得出来）—— 第一批注释里「主线程的加载任务插不进来」
    /// **是错的**。于是对本批三个读 `appState` 的面板，空态站稳靠两件事：① 渲染前显式置空；
    /// ② **渲染后再断言一遍状态仍然为空** —— 一旦哪天磁盘上真有了数据任务 / 归档目录，
    /// 这里会**当场变红**，而不是悄悄拍出一张与注释不符的图
    /// （第一批的 `List` 假绿已经说明：工具自己的假设要靠实测钉住，不能靠注释）。
    @MainActor
    func testPanelEmptyStatesBatchTwo() throws {
        let host = makeEmptyHost()

        // ① 数据任务空态（FR-AI-05 / 06 / 08）
        host.state.dataTasks = []
        host.state.dataTaskRuns = []
        host.state.dataTaskMessage = nil
        host.state.dataTaskError = nil
        XCTAssertTrue(host.state.dataTasks.isEmpty, "本张要拍空态：一条数据任务都不该有")
        try snapshotLightAndDark(
            "data-task-empty",
            size: CGSize(width: 1_060, height: 860),
            host: host
        ) {
            DataTaskPanel()
        }
        XCTAssertTrue(
            host.state.dataTasks.isEmpty,
            "渲染期间数据任务被重填了（离屏宿主里面板的 .task 会跑，读的是磁盘上的 data-tasks.json）"
                + " —— 这张图不能当空态证据，要与磁盘状态解耦得先做 L-12 的可注入口子"
        )

        // ② 导入空态（FR-IO-03 / 06 / 07）：没选文件、没解析、没有日志
        host.state.importError = nil
        host.state.importMessage = nil
        host.state.selectedTreeObject = nil
        XCTAssertTrue(host.state.importLog.isEmpty, "本张要拍空态：导入日志该是空的")
        XCTAssertFalse(host.state.isImportRunning, "本张要拍空态：不该正在导入")
        XCTAssertNil(host.state.selectedTreeObject, "没选对象时目标表才该是空的")
        try snapshotLightAndDark(
            "import-empty",
            size: CGSize(width: 780, height: 760),
            host: host
        ) {
            ImportPanel()
        }
        XCTAssertTrue(host.state.importLog.isEmpty, "渲染期间导入日志被写入了 —— 空态没站稳")

        // ③ 例行候选空态（FR-AI-14 / 15）：报告还没算出来（`nil`）
        // 高度取内容实际所需（面板自己没有固定高度：它只钉了宽度 700）：给多了会看到
        // SwiftUI 把内容在宿主里**垂直居中**，那不是面板在真机上的样子（sheet 只给内容所需的高度）。
        XCTAssertNil(host.state.routineReport, "本张要拍空态：例行候选报告该还没算过")
        try snapshotLightAndDark(
            "routine-candidates-empty",
            size: CGSize(width: 700, height: 240),
            host: host
        ) {
            RoutineCandidatesPanel()
        }
        XCTAssertNil(host.state.routineReport, "渲染期间例行候选报告被算出来了 —— 空态没站稳")

        // ④ 会话空态（FR-SESS-01 / 02）：见本方法开头的「如实说明」
        XCTAssertTrue(host.state.connections.isEmpty, "会话面板要拍空列表：先确认没有连接")
        try snapshotLightAndDark(
            "session-empty",
            size: CGSize(width: 860, height: 520),
            host: host
        ) {
            SessionPanel()
        }
    }

    // MARK: - 清单

    override class func tearDown() {
        UISnapshot.finishManifestIfEnabled()
        super.tearDown()
    }
}
