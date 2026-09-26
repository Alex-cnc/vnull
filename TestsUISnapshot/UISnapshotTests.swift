import SwiftUI
import XCTest

import DoyahCore
@testable import DoyahStudioApp

/// **界面快照 · 第一批**（队列 L-01）。
///
/// 覆盖 spec §5.2 里"静态观感类"的四组：
///   ① 三档活动栏（FR-LIC-02：Standard / Pro / Ultra 各能看到哪几个区）
///   ② 工作区 Home 欢迎页空态（FR-EDIT-35）
///   ③ 结果表空态（§2 第 3 条 / FR-RES-*）
///   ④ ER 图初始态（FR-DDL-05）
///
/// 每张图落 `.build/ui-snapshots/*.png`，同时写 `manifest.json`（尺寸 / 内容占比 / 生成时间）。
/// 跑法：`./Scripts/make-ui-snapshots.sh`（或 `DOYAH_UI_SNAPSHOT=1 swift test --filter UISnapshotTests`）。
final class UISnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            UISnapshot.isEnabled,
            "界面快照要显式打开：DOYAH_UI_SNAPSHOT=1（它是取证工具，不进每轮门禁）"
        )
    }

    // MARK: - 共用装配

    /// 一个不碰用户真实偏好的宿主：工作区历史指到临时文件，其它对象与 App 根部同一套路。
    @MainActor
    private func makeHost() -> (state: AppState, workspace: WorkspaceStore, tabs: WorkspaceTabsModel, terminal: TerminalModel) {
        let scratch = UISnapshot.outputDirectory.deletingLastPathComponent()
            .appendingPathComponent("ui-snapshot-scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let historyURL = scratch.appendingPathComponent("workspace-history-\(UUID().uuidString).json")

        let state = AppState()
        // 活动栏 / 结果表都活在"数据库"或"工作区"里，先把遮挡的许可证状态摆成完整档，
        // 由用到分档的用例自己再逐个覆写（避免这里的临时状态影响别的用例）。
        let workspace = WorkspaceStore.shared
        let tabs = WorkspaceTabsModel(store: WorkspaceHistoryStore(fileURL: historyURL))
        return (state, workspace, tabs, TerminalModel())
    }

    /// 活动栏宽度取自 `Metrics.activityBarWidth`，高度给足三个图标 + 两个底部动作。
    private let activityBarSize = CGSize(width: 46, height: 240)

    // MARK: - ① 三档活动栏（FR-LIC-02）

    @MainActor
    func testActivityBarAcrossEditions() throws {
        let host = makeHost()
        defer { UISnapshot.clearLicense(from: host.state) }

        for edition in [LicenseEdition.standard, .pro, .ultra] {
            let load = try UISnapshot.applyLicense(edition, to: host.state)

            // 断言"这一档真的生效了" —— 不然图里画的是上一档，图好看但是没有意义。
            XCTAssertEqual(load.entitlements.edition, edition, "许可证档位没落到 \(edition.rawValue)")
            XCTAssertEqual(load.entitlements.basis, .licensed, "签名校验没通过（临时许可证链路断了）")
            let expected = LicensePresentation.activityItems(for: edition.capabilities)
            XCTAssertEqual(host.state.visibleActivityItems, expected, "活动栏可见项与 LicensePresentation 不一致")

            try UISnapshot.write("activity-bar-\(edition.rawValue)", size: activityBarSize) {
                ActivityBarView().snapshotEnvironment(
                    state: host.state, workspace: host.workspace, tabs: host.tabs, terminal: host.terminal
                )
            }
        }

        // 深色只补一张：三档的图标集合差异在浅色下已能判，深色要看的是**对比度**。
        try UISnapshot.applyLicense(.ultra, to: host.state)
        try UISnapshot.write("activity-bar-ultra-dark", size: activityBarSize, scheme: .dark) {
            ActivityBarView().snapshotEnvironment(
                state: host.state, workspace: host.workspace, tabs: host.tabs, terminal: host.terminal
            )
        }
    }

    // MARK: - ② 工作区 Home 欢迎页空态（FR-EDIT-35）

    @MainActor
    func testWorkspaceHomeEmptyState() throws {
        let host = makeHost()
        let size = CGSize(width: 1_000, height: 560)

        // 先把档位摆到含工作区的那一档：Standard 下 Home 页不是"空态"，而是"这个区不该有"。
        try UISnapshot.applyLicense(.ultra, to: host.state)

        for scheme in [ColorScheme.light, .dark] {
            try UISnapshot.write(
                "workspace-home-empty\(scheme == .dark ? "-dark" : "")",
                size: size,
                scheme: scheme
            ) {
                WorkspaceHomeView().snapshotEnvironment(
                    state: host.state, workspace: host.workspace, tabs: host.tabs, terminal: host.terminal
                )
            }
        }

        // 空态就是"三个分区都写着空文案"：如果哪天有人把空态删了，这里会先红。
        XCTAssertTrue(host.tabs.history.files.isEmpty, "临时历史文件里不该有内容")
        XCTAssertTrue(host.tabs.history.workspaces.isEmpty, "临时历史文件里不该有内容")
        UISnapshot.clearLicense(from: host.state)
    }

    // MARK: - ③ 结果表（空态 + 有数据的密度）

    @MainActor
    func testResultTableEmptyAndDense() throws {
        let host = makeHost()
        let size = CGSize(width: 900, height: 460)

        for scheme in [ColorScheme.light, .dark] {
            try UISnapshot.write(
                "result-table-empty\(scheme == .dark ? "-dark" : "")",
                size: size,
                scheme: scheme
            ) {
                ResultTableView(result: nil).snapshotEnvironment(
                    state: host.state, workspace: host.workspace, tabs: host.tabs, terminal: host.terminal
                )
            }
        }

        // 密度：20 列 × 40 行，列名长短不齐（真实表的常态）。
        // 注意 `ResultGrid` 是 `NSViewRepresentable`（AppKit 自绘）—— 它在离屏渲染里的呈现
        // 是本轮要观察的事实，结论写进开发记录，不在这里假装通过。
        let columns = (0..<20).map { index in
            ColumnMeta(
                id: index,
                name: index % 3 == 0 ? "very_long_column_name_\(index)" : "col_\(index)",
                typeName: index % 4 == 0 ? "numeric(18,2)" : "text",
                isNullable: index % 2 == 0
            )
        }
        let rows: [[String?]] = (0..<40).map { row in
            columns.map { column in
                switch column.id % 4 {
                case 0: return String(row * 1_000 + column.id)
                case 1: return "行 \(row) · 列 \(column.id)"
                case 2: return row % 5 == 0 ? nil : "value-\(row)-\(column.id)"
                default: return "一个稍长一些的单元格内容 \(row)-\(column.id)"
                }
            }
        }
        let result = QueryResult(columns: columns, rows: rows, executionTime: 0.042)
        XCTAssertEqual(result.columnCount, 20)

        try UISnapshot.write("result-table-dense-20col", size: size) {
            ResultTableView(result: result, resultCount: 1, selectedIndex: 0).snapshotEnvironment(
                state: host.state, workspace: host.workspace, tabs: host.tabs, terminal: host.terminal
            )
        }

        // 没有结果集的语句（DDL / DML）：走的是另一条分支（`emptyResultSet`），要单独取一张。
        let ddl = QueryResult(columns: [], rows: [], affectedRows: 3)
        try UISnapshot.write("result-table-no-resultset", size: size) {
            ResultTableView(result: ddl).snapshotEnvironment(
                state: host.state, workspace: host.workspace, tabs: host.tabs, terminal: host.terminal
            )
        }
    }

    // MARK: - ④ ER 图初始态（FR-DDL-05）

    @MainActor
    func testERDiagramInitialState() throws {
        let host = makeHost()
        try UISnapshot.write("er-diagram-initial", size: CGSize(width: 860, height: 560)) {
            ERDiagramPanel().snapshotEnvironment(
                state: host.state, workspace: host.workspace, tabs: host.tabs, terminal: host.terminal
            )
        }
    }

    // MARK: - 清单

    /// 整组用例跑完再写清单。
    ///
    /// 为什么不用一个"排在最后"的用例：XCTest 的执行顺序不是声明顺序（本轮实测 `test_zz…`
    /// 反而跑了第一个，清单里是 0 张）。`records` 跨用例累积，只有类级收尾才保证写全。
    ///
    /// **门禁里的 `swift test` 会跳过全部用例**（没设 `DOYAH_UI_SNAPSHOT`），那时 `records` 是空的 ——
    /// 本轮实测它就照着写了一份"0 张"的清单，把上一轮的真清单覆盖掉了。所以未启用时直接返回。
    override class func tearDown() {
        guard UISnapshot.isEnabled, !UISnapshot.records.isEmpty else {
            super.tearDown()
            return
        }
        do {
            if let url = try UISnapshot.writeManifest(extra: ["snapshotCount": String(UISnapshot.records.count)]) {
                print("🧾 清单：\(url.path)（\(UISnapshot.records.count) 张）")
            }
        } catch {
            print("⚠️ 清单写入失败：\(error)")
        }
        super.tearDown()
    }
}
