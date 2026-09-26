import CryptoKit
import SwiftUI
import XCTest

import DoyahCore
@testable import DoyahStudioApp

/// **界面快照 · L-12：需要数据的观感项**。
///
/// L-01 / L-11 那两批拍的都是「没有数据也看得到的东西」（空态、初始态）。这一批相反：
/// 拍的是**必须有数据才成立**的三个态 —— 它们原来只能靠人先连库、执行、点筛选才看得到，
/// 于是 spec §5.2 里这三条一直挂在「待人工点验」上：
///
///   · **ER 图带真实图**（FR-DDL-05）：面板只会自己去取，离线只能拍到加载态 / 错误态；
///   · **结果表客户端视图**（FR-RES-08/09/10 + R-21）：筛选条、排序键、分页条、
///     表格里的选中态 —— 不筛不翻不选，这些控件根本不出来；
///   · **行详情侧栏**（FR-DATA-05）：侧栏讲的是「选中的那一行」，没选行就是空态。
///
/// **口子（L-12 本轮拍板）**：三处都用**面板级参数注入**（`ERDiagramPanel(initialDiagram:)` /
/// `ResultTableView(initialState:)` / `ResultGrid(initialSelection:)`），不造假连接 ——
/// 造假连接会真的去发连接请求（离屏渲染里既慢又不可靠，而且那是在测网络，不是在测界面）。
/// 注入只给**初值**：生产路径（`MainWindow` / `QueryWorkspaceView`）不传，行为逐字不变。
///
/// **三条纪律**（与 L-01 / L-11 同源）：不进每轮门禁、产物落 `.build/`、图必须逐张读。
/// 本批另加两条：
///   ① **渲染后断言**：画完再核一遍「页面 / 选中行 / 连接数」，免得哪天面板改成自己去填；
///   ② **注入必须到像素上**：同一面板给两份不同的初值，两张图的内容摘要**必须不同** ——
///      一样就说明参数被忽略、图是假的。这条**不依赖看图**（看图只能证明"我看到了什么"）。
final class UISnapshotDataTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            UISnapshot.isEnabled,
            "界面快照要显式打开：DOYAH_UI_SNAPSHOT=1（它是取证工具，不进每轮门禁）"
        )
    }

    // MARK: - 宿主与工具

    /// 一个**不碰任何真实库 / 文件**的宿主：工作区历史指到临时文件，连接显式清空。
    ///
    /// 连接清空是这批的关键前提：面板若没吃注入、照旧去取，唯一可能的结局就是
    /// 「没有连接」那句错 —— 图上看得出来（图里会是红字而不是表框 / 数据），断言里也核得到。
    @MainActor
    private func makeHost() -> (
        state: AppState, workspace: WorkspaceStore, tabs: WorkspaceTabsModel, terminal: TerminalModel
    ) {
        let scratch = UISnapshot.outputDirectory.deletingLastPathComponent()
            .appendingPathComponent("ui-snapshot-scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let historyURL = scratch.appendingPathComponent("workspace-history-\(UUID().uuidString).json")

        let state = AppState()
        state.connections = []
        state.selectedConnectionID = nil
        return (
            state,
            WorkspaceStore.shared,
            WorkspaceTabsModel(store: WorkspaceHistoryStore(fileURL: historyURL)),
            TerminalModel()
        )
    }

    /// 深浅各拍一遍（与 L-11 同一套口径：深色看的是对比度与动态色）。
    ///
    /// **第 13 轮（L-13）起每张图再各拍两种语言**：由 `writeBothLanguages` 一次给两张
    /// （`-zh` / `-en`），于是这里的四张 = 浅·中 / 浅·英 / 深·中 / 深·英。
    /// 返回顺序就是产物顺序（每个 scheme 内先中后英），取 `[0]` 拿到的一直是**浅色·中文**。
    @MainActor
    @discardableResult
    private func snapshotLightAndDark<V: View>(
        _ name: String,
        size: CGSize,
        host: (
            state: AppState, workspace: WorkspaceStore, tabs: WorkspaceTabsModel, terminal: TerminalModel
        ),
        @ViewBuilder content: () -> V
    ) throws -> [UISnapshot.Record] {
        var records: [UISnapshot.Record] = []
        for scheme in [ColorScheme.light, .dark] {
            records.append(
                contentsOf: try UISnapshot.writeBothLanguages(
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
                }.records
            )
        }
        return records
    }

    /// 落盘后取 PNG 的内容摘要：机械地证明「两张图真的不一样」。
    ///
    /// 为什么不比 `Record.bytes`（字节数）：不同内容凑巧同长度是平常事，拿它当"不同"的证据太松
    /// （本仓第 10 轮吃过一次「判据太松」的亏：占位图比真界面还密）。
    private func digest(of record: UISnapshot.Record) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: record.file))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - ① ER 图带真实图（FR-DDL-05）

    /// 6 张表 / 6 条关系，刻意把三条**最容易画错**的分支都放进去：
    ///   · 跨层的普通外键（父在上、子在下）；
    ///   · **自引用**（`staff.manager_id → staff.id`）：走线要绕开自己，虚线画出；
    ///   · **成环**（`departments ⇄ staff`）：拓扑排序排不出来，footer 必须**点名**这两张表；
    ///   · `orders` 给 14 列（> 12），顺便拍「…还有 N 列」那一行。
    @MainActor
    func testERDiagramWithRealGraph() throws {
        let host = makeHost()
        let size = CGSize(width: 900, height: 720)   // 面板自己的 frame 就是 900×720

        let diagram = Self.fakeSchemaDiagram()

        // 前置断言：这张图里**确实**有要拍的那几样东西，不然图再好看也没意义。
        XCTAssertEqual(diagram.tables.count, 6)
        XCTAssertEqual(diagram.relationships.count, 6)
        let layout = try XCTUnwrap(diagram.layout())
        XCTAssertEqual(
            layout.cyclicTables, ["public.departments", "public.staff"],
            "成环的两张表要能点出名字 —— 那是 footer 那条提示的唯一来源"
        )
        XCTAssertEqual(
            diagram.tables.first { $0.qualifiedName == "public.orders" }?.columns.count, 14,
            "超过 12 列的表才会画「还有 N 列」那一行"
        )
        XCTAssertTrue(host.state.connections.isEmpty, "本张图不该依赖任何连接")

        let populated = try snapshotLightAndDark("er-diagram-populated", size: size, host: host) {
            ERDiagramPanel(initialDiagram: diagram)
        }

        // 对照：同一面板给一份**空图** —— 它同时是「注入空图 → 走 `erDiagramEmpty` 那一支」的
        // 空态证据，也是下面那条棘轮的对照物。
        let emptyPair = try UISnapshot.writeBothLanguages("er-diagram-injected-empty", size: size) {
            ERDiagramPanel(initialDiagram: ERDiagram(tables: [], relationships: [])).snapshotEnvironment(
                state: host.state, workspace: host.workspace, tabs: host.tabs, terminal: host.terminal
            )
        }

        // 渲染后断言：连接数没变、图还在（没有谁把它取没了）。
        XCTAssertTrue(host.state.connections.isEmpty, "渲染期间有人去连库了 —— 这张图不能当离线证据")
        XCTAssertFalse(diagram.isEmpty, "注入的图在渲染后成了空的")

        // 棘轮：有图 / 空图两张必须不同。哪天 `initialDiagram` 被忽略、或 `.onAppear` 的
        // `diagram == nil` 判断被删（注入被 load() 覆盖），两张会一模一样，这条先红。
        // 两张取**同一语言**（`[0]` 都是浅色·中文）—— 跨语言比会拿"语言本来就不同"顶数。
        let populatedLight = try XCTUnwrap(populated.first)
        let emptyLight = try XCTUnwrap(emptyPair.records.first)
        XCTAssertEqual(populatedLight.language, emptyLight.language, "对照的两张必须同语言，否则这条棘轮是假的")
        XCTAssertNotEqual(
            try digest(of: populatedLight), try digest(of: emptyLight),
            "有图 / 空图两张快照一模一样 ⇒ 注入没到像素上（`initialDiagram` 被忽略了）"
        )

        // L-13 的另一半：ER 面板的文案随语言变（footer 的「Cyclic references…」等），
        // 所以**中文 / 英文两张的像素必须不同** —— 一样就说明宿主语境没传到 `L(...)`。
        let populatedChinese = try XCTUnwrap(populated.first { $0.language == "zh-Hans" })
        let populatedEnglish = try XCTUnwrap(populated.first { $0.language == "en" })
        XCTAssertNotEqual(
            populatedChinese.localizedStrings, populatedEnglish.localizedStrings,
            "ER 面板两遍取到的文案一模一样 —— 宿主语言没生效"
        )
        XCTAssertNotEqual(
            try digest(of: populatedChinese), try digest(of: populatedEnglish),
            "中英两张像素一模一样 ⇒ 语言没到像素上"
        )
    }

    /// 一份**合成的**库结构（不来自任何真实库）：形状照着「订单 + 组织」这类常见结构搭，
    /// 表名 / 列名都是通用词，不含任何真实库的痕迹。
    private static func fakeSchemaDiagram() -> ERDiagram {
        let columns: [String: [ERDiagram.Column]] = [
            "public.customers": [
                .init(name: "id", typeName: "int8", isPrimaryKey: true),
                .init(name: "name", typeName: "text"),
                .init(name: "created_at", typeName: "timestamptz"),
            ],
            "public.products": [
                .init(name: "id", typeName: "int8", isPrimaryKey: true),
                .init(name: "sku", typeName: "text"),
                .init(name: "unit_price", typeName: "numeric(12,2)"),
            ],
            "public.order_items": [
                .init(name: "id", typeName: "int8", isPrimaryKey: true),
                .init(name: "order_id", typeName: "int8", isForeignKey: true),
                .init(name: "product_id", typeName: "int8", isForeignKey: true),
                .init(name: "qty", typeName: "int4"),
            ],
            "public.departments": [
                .init(name: "id", typeName: "int8", isPrimaryKey: true),
                .init(name: "name", typeName: "text"),
                .init(name: "head_id", typeName: "int8", isForeignKey: true),
            ],
            "public.staff": [
                .init(name: "id", typeName: "int8", isPrimaryKey: true),
                .init(name: "name", typeName: "text"),
                .init(name: "department_id", typeName: "int8", isForeignKey: true),
                .init(name: "manager_id", typeName: "int8", isForeignKey: true),
            ],
            "public.orders": (0..<14).map { index in
                ERDiagram.Column(
                    name: index == 0 ? "id" : (index == 1 ? "customer_id" : "col_\(String(format: "%02d", index))"),
                    typeName: index <= 1 ? "int8" : "text",
                    isPrimaryKey: index == 0,
                    isForeignKey: index == 1
                )
            },
        ]

        let tables = ["public.customers", "public.orders", "public.order_items",
                      "public.products", "public.staff", "public.departments"].map { qualified -> ERDiagram.Table in
            let parts = qualified.split(separator: ".")
            return ERDiagram.Table(
                schema: String(parts[0]),
                name: String(parts[1]),
                columns: columns[qualified] ?? []
            )
        }

        func endpoint(_ qualified: String, _ columns: [String]) -> ERDiagram.Endpoint {
            let parts = qualified.split(separator: ".")
            return ERDiagram.Endpoint(schema: String(parts[0]), table: String(parts[1]), columns: columns)
        }
        func relationship(
            _ name: String, _ from: String, _ fromColumns: [String], _ to: String, _ toColumns: [String]
        ) -> ERDiagram.Relationship {
            ERDiagram.Relationship(
                name: name,
                from: endpoint(from, fromColumns),
                to: endpoint(to, toColumns)
            )
        }

        // `build` 而不是裸构造器：归一化 + 稳定排序是布局确定性的前提
        // （同一份结构两次导出必须给出同一张图）。
        return ERDiagram.build(
            tables: tables,
            relationships: [
                relationship("orders_customer_id_fkey", "public.orders", ["customer_id"], "public.customers", ["id"]),
                relationship("order_items_order_id_fkey", "public.order_items", ["order_id"], "public.orders", ["id"]),
                relationship("order_items_product_id_fkey", "public.order_items", ["product_id"], "public.products", ["id"]),
                relationship("staff_department_id_fkey", "public.staff", ["department_id"], "public.departments", ["id"]),
                relationship("departments_head_id_fkey", "public.departments", ["head_id"], "public.staff", ["id"]),
                relationship("staff_manager_id_fkey", "public.staff", ["manager_id"], "public.staff", ["id"]),
            ]
        )
    }

    // MARK: - ②③ 结果表客户端视图 + 行详情侧栏（FR-RES-08~10 / FR-DATA-05）

    /// 一份**合成的**结果集：7 列 × 15 行，包含 NULL、空字符串、带换行的 JSON
    /// （行详情侧栏要说的三件语义都在里面）。
    ///
    /// 只有 `payload` 是长值：`CellInspector` 的显示上限是 4000 字符，这里约 250 字符，
    /// **不会**触发截断 —— 也就是说这张图里**看不到**"截断要说出原始长度"那一支（如实登记）。
    private static func fakeOrdersResult() -> QueryResult {
        let columns: [ColumnMeta] = [
            ColumnMeta(id: 0, name: "id", typeName: "int8", isNullable: false),
            ColumnMeta(id: 1, name: "order_no", typeName: "text", isNullable: false),
            ColumnMeta(id: 2, name: "status", typeName: "text", isNullable: false),
            ColumnMeta(id: 3, name: "customer", typeName: "text", isNullable: true),
            ColumnMeta(id: 4, name: "tags", typeName: "text[]", isNullable: true),
            ColumnMeta(id: 5, name: "note", typeName: "text", isNullable: true),
            ColumnMeta(id: 6, name: "payload", typeName: "jsonb", isNullable: true),
        ]

        let rows: [[String?]] = (0..<15).map { index in
            let payload = """
            {"channel":"pos","items":[{"qty":\(index % 4 + 1),"sku":"S-\(1_000 + index)","unit_price":19.9},\
            {"qty":1,"sku":"S-\(2_200 + index)","unit_price":249.0}],"note":"split shipment requested",\
            "total":\(index % 4 + 1)00.0}
            """
            return [
                String(1_000 + index),
                "SO-2026-\(String(format: "%04d", index + 1))",
                index % 5 == 0 ? "paused" : "active",
                index % 4 == 0 ? nil : "cust-\(String(format: "%02d", index))",
                index % 4 == 0 ? "" : "tag-a,tag-b",
                index % 3 == 0 ? nil : "第 \(index + 1) 批交付确认",
                payload,
            ]
        }

        return QueryResult(columns: columns, rows: rows, executionTime: 0.031)
    }

    /// 客户端视图初值：两条筛选（AND）+ 两个排序键 + 每页 3 行且停在**第 2 页**。
    ///
    /// 这几个取值是配着上面的夹具挑的，好让第二页**非空**、且里面有一行同时有
    /// NULL 客户与空字符串标签 —— 侧栏那张图才有东西可讲。取值本身不靠手算：
    /// 下面用 `ResultGridState.page(of:)`（Core 那一份实现）算出来再断言。
    private static func fakeClientViewState(selectedRows: Set<Int>, rowDetail: Bool) -> ResultViewState {
        ResultViewState(
            grid: ResultGridState(
                filters: [
                    ResultFilter(columnIndex: 2, op: .equals, value: "active"),
                    ResultFilter(columnIndex: 5, op: .isNotEmpty),
                ],
                sortDescriptors: [
                    ResultSortDescriptor(columnIndex: 1, order: .descending),
                    ResultSortDescriptor(columnIndex: 2, order: .ascending),
                ],
                pageIndex: 1,
                pageSize: 3
            ),
            selectedRows: selectedRows,
            isRowDetailPresented: rowDetail
        )
    }

    @MainActor
    func testResultClientViewStates() throws {
        let host = makeHost()
        let size = CGSize(width: 1_180, height: 640)
        let result = Self.fakeOrdersResult()

        // 先在 Core 那份实现上算一遍：分页 / 筛选真的生效，页数与页码都如文档所说。
        let probe = Self.fakeClientViewState(selectedRows: [], rowDetail: false)
        let page = probe.grid.page(of: result.rows)
        XCTAssertEqual(probe.grid.filters.count, 2)
        XCTAssertEqual(probe.grid.sortDescriptors.count, 2, "两个排序键才会在客户端视图条上出排序 chip")
        XCTAssertTrue(probe.grid.isClientViewActive)
        XCTAssertEqual(page.totalRows, 8, "筛完剩下 8 行（夹具的性质，不是估计）")
        XCTAssertEqual(page.pageCount, 3)
        XCTAssertEqual(page.pageIndex, 1, "停在第二页：分页条上要看得到非第 1 页")
        XCTAssertEqual(page.rows.count, 3)

        // 选中的那一行：挑**同时有** NULL（`customer`）与空串（`tags`）的那一行 ——
        // 侧栏那一张要讲的正是这两者长得不一样。索引由数据推出来，不是手写死的。
        let selectedIndex = try XCTUnwrap(
            page.rows.firstIndex { $0[3] == nil && $0[4]?.isEmpty == true },
            "第二页里没有「NULL 客户 + 空串标签」的那一行 —— 夹具与筛选条件配错了"
        )
        XCTAssertEqual(page.rows[selectedIndex][1], "SO-2026-0009", "选中的是这一行（图要对得上）")

        let state = Self.fakeClientViewState(selectedRows: [selectedIndex], rowDetail: false)

        // ② 客户端视图：筛选条 + 排序 chip + 分页条 + 表格里选中态（不打开侧栏）。
        let clientView = try snapshotLightAndDark("result-client-view", size: size, host: host) {
            ResultTableView(
                result: result,
                resultCount: 1,
                selectedIndex: 0,
                onExport: { _, _ in },
                onGenerateWhere: { _ in },
                initialState: state
            )
        }

        // ③ 行详情侧栏（FR-DATA-05）：同一份结果、同一行，把侧栏打开。
        let rowDetail = try snapshotLightAndDark("result-row-detail", size: size, host: host) {
            ResultTableView(
                result: result,
                resultCount: 1,
                selectedIndex: 0,
                onExport: { _, _ in },
                onGenerateWhere: { _ in },
                initialState: Self.fakeClientViewState(selectedRows: [selectedIndex], rowDetail: true)
            )
        }

        // 渲染后断言：初值是值类型，谁也没把它改写；连接数仍是 0（这两张图不该连任何库）。
        XCTAssertEqual(state.grid.pageSize, 3)
        XCTAssertEqual(state.selectedRows, [selectedIndex])
        XCTAssertFalse(state.isRowDetailPresented)
        XCTAssertTrue(host.state.connections.isEmpty)

        // 棘轮：三块状态一起换（侧栏开 / 关），像素必须跟着变。若 `initialState` 被忽略，
        // 两张都会是默认态（无筛选、无分页、无侧栏）—— 摘要相同，这条先红。
        let clientViewLight = try XCTUnwrap(clientView.first)
        let rowDetailLight = try XCTUnwrap(rowDetail.first)
        XCTAssertEqual(
            clientViewLight.language, rowDetailLight.language,
            "对照的两张必须同语言（否则差异可能来自语言而不是侧栏），这条棘轮才成立"
        )
        XCTAssertNotEqual(
            try digest(of: clientViewLight), try digest(of: rowDetailLight),
            "侧栏开 / 关两张快照一模一样 ⇒ `initialState` 没到像素上"
        )
        XCTAssertGreaterThan(
            clientViewLight.contentRatio, 0,
            "内容占比为 0 说明整幅是空的"
        )
    }

    // MARK: - 清单

    /// 整组用例跑完再写清单（与 L-01 / L-11 同一个理由：XCTest 的执行顺序不是声明顺序，
    /// 只有类级收尾才保证写全；未启用时 `finishManifestIfEnabled` 自己会直接返回）。
    override class func tearDown() {
        UISnapshot.finishManifestIfEnabled()
        super.tearDown()
    }
}
