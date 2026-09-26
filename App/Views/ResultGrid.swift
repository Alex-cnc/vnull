import SwiftUI
import AppKit
import DoyahCore

/// 结果表在内联编辑态下要**多画**的东西（FR-DATA-04）。
///
/// 刻意只是"渲染信息"：它不持有改动本身（改动的攒法与去留由 `InlineEditDraft` 决定），
/// 也不改 `QueryResult` —— 未提交的改动在界面上必须**看得出来是未提交的**，
/// 而不是悄悄替换掉真值（那会让人以为已经写进库了）。

struct ResultGridEditing: Equatable {
    /// 是否处于编辑态（决定单元格能不能就地编辑、右键菜单给不给删行）。
    var isActive = false
    /// 改动过的单元格：显示行号 → 列号集合（渲染成强调色 + "待提交"提示）。
    var touched: [Int: Set<Int>] = [:]
    /// 显示覆盖值：显示行号 → 列号 → 文本（`nil` 表示 NULL —— 与"没有覆盖"是两回事）。
    var overlay: [Int: [Int: String?]] = [:]
    /// 被标记删除的行（画删除线）。
    var deletedRows: Set<Int> = []

    /// 这一格显示成什么（没有覆盖时返回 nil，调用方用原值）。
    func overrideValue(row: Int, column: Int) -> String?? {
        guard let cells = overlay[row], cells.keys.contains(column) else { return nil }
        return cells[column] ?? nil
    }
}

/// 结果表格：NSTableView 桥接实现。
///
/// 相比 SwiftUI `Grid`，这里能得到列宽调整、列排序、多选、⌘C 复制，
/// 以及大结果集下的单元格复用。
///
/// **外观全部走设计令牌**（FR-EDIT-33 的逐屏替换）：
///   · 行高 / 间距 / 圆角取自 `Metrics` / `Spacing`；
///   · 表头与单元格的字体取自 `Theme.font`，颜色取自 `TextTone` / `Surface`；
///   · 数值列**右对齐 + 等宽数字**（判定在 `Core/ColumnAlignment`，那一层能单测）；
///   · 斑马纹、分隔线、选中态**自己画**，不用 AppKit 的系统样式 ——
///     系统样式在深浅两种外观下都不受我们的令牌控制，混着用会出现"这块跟别处不是一个色"。

struct ResultGrid: NSViewRepresentable {
    let result: QueryResult
    /// 要显示的行。为 nil 时显示结果集的全部行。
    ///
    /// 客户端筛选 / 排序 / 分页（FR-RES-08~10）都只改变「显示哪些行」，
    /// 不改动 `QueryResult` 本身 —— 所以这里传进来的是**视图算好的行**，
    /// 而复制（⌘C）也必须用同一份，否则复制出来的会是「看不见的那些行」。
    var displayedRows: [[String?]]?
    /// 当前排序键（用于同步 AppKit 的表头指示器）。
    var sortDescriptors: [ResultSortDescriptor] = []
    /// 表头点击回调：`(列号, 是否按住 Shift)`。
    var onToggleSort: ((Int, Bool) -> Void)?
    /// 选中行变化回调。参数是**当前显示顺序里的行号**（分页 / 筛选 / 排序之后的下标），
    /// 不是原结果集里的行号 —— 调用方要取行必须用同一份 `displayedRows[index]`。
    ///
    /// 为什么要在 `tableViewSelectionDidChange` 的早退**之前**发出：那个方法为了少重画几行
    /// 做了 `guard !changed.isEmpty` 早退，而"选择被清空 / 没有列可重画"恰恰是必须传出去的变化 ——
    /// 早退会把它吞掉，行详情侧栏就会继续显示上一行的值（欺骗性显示）。
    var onSelectionChange: ((Set<Int>) -> Void)?
    /// 右键「跳到被引用行…」回调：`(列名, 单元格值)`（FR-DATA-06）。
    ///
    /// 为什么传**列名与值**而不是行列下标：跳转只需要「这一列的值」这个事实，
    /// 而下标在分页 / 排序 / 筛选之后有「显示下标 vs 原始下标」两套语义 —— 传下标迟早错位。
    var onJumpToReferencedRow: ((String, String?) -> Void)?
    /// 内联编辑（FR-DATA-04）的**渲染信息**：只影响这一层怎么画，不改 `rows` 本身。
    var editing: ResultGridEditing = ResultGridEditing()
    /// **首次挂载**时要把哪些行选上（分页内索引，队列 L-12 的口子）。
    ///
    /// 为什么只在建视图时用一次、不在 `updateNSView` 里重放：显示的行一换，同一个行号就指向
    /// 另一行 —— 重放等于把旧行号重新点亮（那种"亮着的不是我选的那行"正是本文件反复防的
    /// 欺骗性显示）。所以它只是一份**初值**：生产路径不传（默认空集），表格的选中态照旧
    /// 完全由用户动作驱动。
    var initialSelection: Set<Int> = []
    /// 某一格编辑结束：`(显示行号, 列号, 新文本)`。是否采纳由上层决定（这里是"另一个按钮"）。
    var onCommitCellEdit: ((Int, Int, String) -> Void)?
    /// 右键「标记删除此行 / 取消删除标记」：`(显示行号, 该行当前是否已标记删除)`。
    var onToggleRowDeletion: ((Int, Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = CopyableTableView()
        tableView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = Metrics.rowHeight
        // 行间只留水平方向的呼吸：垂直方向靠我们自己画的发丝线，不用系统的磅线。
        tableView.intercellSpacing = NSSize(width: Spacing.m, height: 0)
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = Theme.nsColor(Surface.content)
        tableView.style = .plain
        tableView.headerView = NSTableHeaderView()

        let menu = NSMenu()
        let copyItem = NSMenuItem(title: L(.commonCopy), action: #selector(CopyableTableView.copy(_:)), keyEquivalent: "c")
        copyItem.target = tableView
        menu.addItem(copyItem)

        // 「复制为…」（FR-RES-12）：贴表格用 TSV、贴文档用 Markdown、贴 SQL 用 INSERT。
        let copyAsItem = NSMenuItem(title: L(.resultCopyAs), action: nil, keyEquivalent: "")
        let copyAsMenu = NSMenu()
        for format in ResultClipboard.Format.allCases {
            let item = NSMenuItem(
                title: format.displayName,
                action: #selector(CopyableTableView.copyAs(_:)),
                keyEquivalent: ""
            )
            item.target = tableView
            item.representedObject = format.rawValue
            copyAsMenu.addItem(item)
        }
        copyAsItem.submenu = copyAsMenu
        menu.addItem(copyAsItem)

        // 外键引用导航（FR-DATA-06）：跳转目标不在这里猜 —— 点下去由 AppState 判
        // 「是不是从表浏览来的 / 这一列有没有外键 / 值是不是 NULL」，逐条给人话。
        menu.addItem(NSMenuItem.separator())
        let jumpItem = NSMenuItem(
            title: L(.resultJumpToReferencedRow),
            action: #selector(CopyableTableView.jumpToReferencedRow(_:)),
            keyEquivalent: ""
        )
        jumpItem.target = tableView
        menu.addItem(jumpItem)

        // 内联编辑（FR-DATA-04）：行级动作只有"标记删除 / 取消标记"两条 —— 改值走双击单元格
        // （就地编辑），加行走结果区的工具条（那里才有"一行不止一个字段"的输入空间）。
        // 两条菜单项的可用性由 `menuNeedsUpdate` 按"是不是在编辑态、这一行删没删"决定。
        menu.addItem(NSMenuItem.separator())
        for (action, titleKey) in [
            (#selector(CopyableTableView.markRowForDeletion(_:)), LKey.inlineEditMarkDelete),
            (#selector(CopyableTableView.unmarkRowForDeletion(_:)), LKey.inlineEditUnmarkDelete)
        ] {
            let item = NSMenuItem(title: L(titleKey), action: action, keyEquivalent: "")
            item.target = tableView
            menu.addItem(item)
        }
        // 这两条的可用性全由我们控制：交给 AppKit 自动校验的话，它会按 action 的
        // 响应链去问，而我们判的是"编辑态 + 这一行删没删"——它问不出来。
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        tableView.menu = menu
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.beginCellEdit(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        context.coordinator.update(
            result: result,
            rows: displayedRows ?? result.rows,
            sortDescriptors: sortDescriptors,
            onToggleSort: onToggleSort,
            onSelectionChange: onSelectionChange,
            onJumpToReferencedRow: onJumpToReferencedRow,
            editing: editing,
            onCommitCellEdit: onCommitCellEdit,
            onToggleRowDeletion: onToggleRowDeletion,
            tableView: tableView
        )

        // 初值选中态**放在 update 之后**：`update` 在首次建视图时必然会走
        // 「显示内容变了 → 作废选中态」那一支（上一次的显示签名是空的），先选也会被它清掉。
        // 越界的行号直接丢掉：宁可不亮，也不亮错行。
        let selectable = initialSelection.filter { $0 >= 0 && $0 < tableView.numberOfRows }
        if !selectable.isEmpty {
            tableView.selectRowIndexes(IndexSet(selectable), byExtendingSelection: false)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.update(
            result: result,
            rows: displayedRows ?? result.rows,
            sortDescriptors: sortDescriptors,
            onToggleSort: onToggleSort,
            onSelectionChange: onSelectionChange,
            onJumpToReferencedRow: onJumpToReferencedRow,
            editing: editing,
            onCommitCellEdit: onCommitCellEdit,
            onToggleRowDeletion: onToggleRowDeletion,
            tableView: tableView
        )
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate, ResultGridCopying {

        private var result: QueryResult?
        /// 当前显示的行（可能是筛选 / 排序 / 分页后的子集）。
        private var rows: [[String?]] = []
        private var lastResultID: UUID?
        /// 以「结果 id + 行数 + 首行 + 末行」判断显示内容是否变了。
        ///
        /// 只看 `result.id` 不够：排序、翻页都不换结果 id，但显示的行完全不同。
        private var lastDisplaySignature: String = ""
        /// 回调由 SwiftUI 每次更新时刷新（闭包不是值类型，不能靠相等判断）。
        private var onToggleSort: ((Int, Bool) -> Void)?
        /// 选中行变化回调（同上，每次更新时刷新）。
        private var onSelectionChange: ((Set<Int>) -> Void)?
        /// 外键跳转回调（同上）。
        private var onJumpToReferencedRow: ((String, String?) -> Void)?
        /// 内联编辑的渲染信息与回调（FR-DATA-04，同上每次刷新）。
        private var editing = ResultGridEditing()
        private var onCommitCellEdit: ((Int, Int, String) -> Void)?
        private var onToggleRowDeletion: ((Int, Bool) -> Void)?
        /// 上一次的编辑态渲染签名：编辑态 / 待提交覆盖值变了要重画，但**不必**作废选中态。
        private var lastEditingSignature = ""
        /// 表格本体（右键菜单的可用性要知道用户点在哪一行）。
        private weak var boundTableView: NSTableView?
        /// 正在**程序化**作废选中态：此时的 `tableViewSelectionDidChange` 不发回调。
        ///
        /// 因为这条路径是 `updateNSView` 里触发的，同步回调等于把"改状态"插进 SwiftUI
        /// 的视图更新过程；而调用方在同一轮更新里已经把自己的选中态清掉了，不会漏信息。
        private var isResettingSelection = false
        /// 程序化同步表头指示器时要屏蔽 `sortDescriptorsDidChange`，否则会自激。
        private var isSyncingSortDescriptors = false
        private var columnSignature: [String] = []
        /// 上一次建列的来源结果集 id（换结果集必须重建列，哪怕列名一样）。
        private var lastColumnResultID: UUID?
        /// 每列是否按数值处理（右对齐 + 等宽数字）。列在重建时才变。
        private var columnIsNumeric: [Bool] = []
        /// 上一次的选中集合：用来只重画"选中态真的变了"的那几行。
        private var lastSelectedRows = IndexSet()

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func update(
            result: QueryResult,
            rows: [[String?]],
            sortDescriptors: [ResultSortDescriptor],
            onToggleSort: ((Int, Bool) -> Void)?,
            onSelectionChange: ((Set<Int>) -> Void)?,
            onJumpToReferencedRow: ((String, String?) -> Void)?,
            editing: ResultGridEditing,
            onCommitCellEdit: ((Int, Int, String) -> Void)?,
            onToggleRowDeletion: ((Int, Bool) -> Void)?,
            tableView: NSTableView
        ) {
            self.result = result
            self.rows = rows
            self.onToggleSort = onToggleSort
            self.onSelectionChange = onSelectionChange
            self.onJumpToReferencedRow = onJumpToReferencedRow
            self.editing = editing
            self.onCommitCellEdit = onCommitCellEdit
            self.onToggleRowDeletion = onToggleRowDeletion
            self.boundTableView = tableView
            syncSortDescriptors(sortDescriptors, tableView: tableView)

            // 换结果集：选中态作废（旧的行号对新数据没有意义）。
            if result.id != lastResultID {
                lastResultID = result.id
                resetSelection(tableView)
            }

            // 列定义只在「结果集换了」或「列签名变了」时重建。
            let columnSignature = result.columns.map { "\($0.name)|\($0.typeName)" }
            if result.id != lastColumnResultID || columnSignature != self.columnSignature {
                lastColumnResultID = result.id
                self.columnSignature = columnSignature
                columnIsNumeric = result.columns.map { ColumnAlignment.isNumeric(typeName: $0.typeName) }
                for column in tableView.tableColumns {
                    tableView.removeTableColumn(column)
                }
                for (index, meta) in result.columns.enumerated() {
                    tableView.addTableColumn(Self.makeColumn(index: index, meta: meta, rows: rows))
                }
            }

            // 显示内容没变就不重载：SwiftUI 每次刷新都重载会让滚动位置与选中态跳动。
            let signature = "\(result.id)|\(rows.count)|\(rows.first ?? [])|\(rows.last ?? [])"
            if signature != lastDisplaySignature {
                lastDisplaySignature = signature
                // 显示的行换了（翻页 / 改每页条数 / 改筛选 / 改排序）：同一个行号从此指向**另一行**，
                // 旧的选中态就是假的 —— 无论它是被 ⌘C 复制还是被行详情侧栏读取。
                //
                // 这里连表格自己的高亮一起撤掉，而不是只清上层状态：表格若还亮着旧行号，
                // 用户再点"同一个行号"不会产生选中变化事件，靠选中回调驱动的侧栏就永远醒不过来。
                resetSelection(tableView)
                tableView.reloadData()
                lastEditingSignature = Self.editingSignature(editing)
                return
            }

            // 编辑态的渲染变化（改了一格 / 标记删除）要重画，但**不作废选中态**：
            // 显示的行一个都没变，只是因为"这一格待提交"要换一种画法。
            let editingSignature = Self.editingSignature(editing)
            if editingSignature != lastEditingSignature {
                lastEditingSignature = editingSignature
                tableView.reloadData()
            }
        }

        /// 编辑态渲染的签名：编辑开关 + 待提交覆盖值 + 删除标记。
        private static func editingSignature(_ editing: ResultGridEditing) -> String {
            guard editing.isActive || !editing.touched.isEmpty
                || !editing.overlay.isEmpty || !editing.deletedRows.isEmpty else { return "" }
            let cells = editing.touched.keys.sorted().map { row in
                "\(row):\(editing.touched[row]!.sorted().map(String.init).joined(separator: ","))"
            }.joined(separator: ";")
            let overlays = editing.overlay.keys.sorted().map { row in
                let cells = editing.overlay[row]!
                return "\(row):" + cells.keys.sorted().map { "\($0)=\(cells[$0].map { $0 ?? "NULL" } ?? "NULL")" }
                    .joined(separator: ",")
            }.joined(separator: ";")
            return "\(editing.isActive)|\(cells)|\(overlays)|\(editing.deletedRows.sorted())"
        }

        /// 作废选中态（换结果集 / 换显示内容）。见 `isResettingSelection` 的说明。
        private func resetSelection(_ tableView: NSTableView) {
            isResettingSelection = true
            tableView.deselectAll(nil)
            isResettingSelection = false
            lastSelectedRows = tableView.selectedRowIndexes
        }

        /// 按状态里的排序键同步 AppKit 的表头指示器（→ / ↓）。
        private func syncSortDescriptors(_ descriptors: [ResultSortDescriptor], tableView: NSTableView) {
            let expected = descriptors.map { descriptor -> NSSortDescriptor in
                NSSortDescriptor(key: "\(descriptor.columnIndex)", ascending: descriptor.order.isAscending)
            }
            let current = tableView.sortDescriptors.map { NSSortDescriptor(key: $0.key, ascending: $0.ascending) }
            guard current != expected else { return }
            isSyncingSortDescriptors = true
            tableView.sortDescriptors = expected
            isSyncingSortDescriptors = false
        }

        /// 表头点击 → 交给状态层循环（升序 → 降序 → 取消）。
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncingSortDescriptors else { return }
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let columnIndex = Int(key) else { return }
            // Shift 按住时是「追加次要排序键」而不是替换。
            let additive = NSEvent.modifierFlags.contains(.shift)
            onToggleSort?(columnIndex, additive)
        }

        // MARK: 行视图（斑马纹 / 选中态 / 发丝线都自己画）

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = ResultRowView()
            rowView.rowIndex = row
            return rowView
        }

        /// 选中态变了只重画变化的那几行 —— 顺带让单元格文字颜色跟着切换。
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            // **回调先发**：下面的早退（没有列可重画）会把"选择被清空"这类有效变化吞掉，
            // 而调用方（行详情侧栏）恰恰靠它才知道该收起详情。
            if !isResettingSelection {
                onSelectionChange?(Set(tableView.selectedRowIndexes))
            }
            let changed = lastSelectedRows.symmetricDifference(tableView.selectedRowIndexes)
            lastSelectedRows = tableView.selectedRowIndexes
            guard !changed.isEmpty, tableView.numberOfColumns > 0 else { return }
            tableView.reloadData(
                forRowIndexes: changed,
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
        }

        // MARK: 单元格

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let result,
                  rows.indices.contains(row),
                  let columnIndex = columnIndex(from: tableColumn),
                  rows[row].indices.contains(columnIndex) else {
                return nil
            }

            // 待提交的改动**优先显示**（用户要看的就是自己刚写的值），但它不是真值 ——
            // 所以下面用强调色 + "待提交"提示把它和已写库的值区分开。
            let original = rows[row][columnIndex]
            let overridden = editing.overrideValue(row: row, column: columnIndex)
            let value: String? = overridden != nil ? overridden! : original
            let isTouched = editing.touched[row]?.contains(columnIndex) ?? false
            let isDeletedRow = editing.deletedRows.contains(row)
            let isNumeric = columnIsNumeric.indices.contains(columnIndex) && columnIsNumeric[columnIndex]
            let isSelected = tableView.selectedRowIndexes.contains(row)
            let identifier = NSUserInterfaceItemIdentifier("result-cell")

            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView,
               let textField = reused.textField {
                cell = reused
                // 复用会带着上一行的外观：字体、对齐、左右内边距每次都要重设。
                textField.alignment = isNumeric ? .right : .left
                textField.font = Self.font(isNumeric: isNumeric)
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let textField = ResultCellTextField(labelWithString: "")
                textField.lineBreakMode = .byTruncatingTail
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.alignment = isNumeric ? .right : .left
                textField.font = Self.font(isNumeric: isNumeric)
                textField.delegate = self
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Spacing.s),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Spacing.s),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }

            if let field = cell.textField as? ResultCellTextField {
                // 行号 / 列号与"原值"存在控件上：编辑结束时只拿得到一个 `NSTextField`，
                // 那一刻表格的 `clickedRow` 可能已经指向别处（用户点了另一格）。
                field.cellRow = row
                field.cellColumn = columnIndex
                field.originalText = value
                field.isEditable = editing.isActive
                field.isSelectable = true
                field.delegate = self
            }

            if isDeletedRow {
                // 待删除的行画删除线 + 危险色：这一行已经"不打算要了"，
                // 但**还没有**提交（提交前它必须看得出是待删除状态）。
                cell.textField?.attributedStringValue = NSAttributedString(
                    string: value ?? "NULL",
                    attributes: [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .font: Self.font(isNumeric: isNumeric),
                        .foregroundColor: Theme.nsColor(StatusTone.danger)
                    ]
                )
            } else {
                cell.textField?.stringValue = value ?? "NULL"
                cell.textField?.textColor = isTouched
                    ? Theme.accentNSColor
                    : (value == nil
                        ? Theme.nsColor(TextTone.tertiary)
                        : (isSelected ? Theme.nsColor(TextTone.primary) : Theme.nsColor(TextTone.secondary)))
            }

            if isDeletedRow {
                cell.toolTip = L(.inlineEditDeletedTag)
            } else if isTouched {
                cell.toolTip = L(.inlineEditPendingCell)
            } else {
                cell.toolTip = value
            }
            return cell
        }

        // MARK: 就地编辑（FR-DATA-04）

        /// 双击某一格 → 让它就地可编辑。
        ///
        /// 用 `clickedRow` / `clickedColumn`（用户双击的那一格），不用选中态 ——
        /// 多选时"选中的第一行"和"双击的那一行"完全可能不是同一行。
        @objc func beginCellEdit(_ sender: Any?) {
            guard editing.isActive, let tableView = sender as? NSTableView else { return }
            let row = tableView.clickedRow
            let column = tableView.clickedColumn
            guard row >= 0, column >= 0, rows.indices.contains(row) else { return }
            tableView.editColumn(column, row: row, with: nil, select: true)
        }

        /// 只有编辑态才允许就地编辑（非编辑态双击应当什么都不发生，而不是误改）。
        func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
            editing.isActive
        }

        /// 编辑结束 → 把新文本交给上层攒进草稿。
        ///
        /// 三条早退：不在编辑态（面板刚关掉）、不是我们的格子、以及**按了 Esc**（取消，不记改动）。
        /// 文本与原值一样时也不记 —— 否则"点一下再点走"就会凭空多出一处待提交改动。
        func controlTextDidEndEditing(_ notification: Notification) {
            guard editing.isActive,
                  let field = notification.object as? ResultCellTextField,
                  field.cellRow >= 0, field.cellColumn >= 0 else { return }
            if let movement = notification.userInfo?["NSTextMovement"] as? Int,
               movement == NSTextMovement.cancel.rawValue {
                return
            }
            let text = field.stringValue
            guard text != field.originalText else { return }
            onCommitCellEdit?(field.cellRow, field.cellColumn, text)
        }

        // MARK: 右键菜单的可用性（编辑态才有"标记 / 取消删除"）

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView = boundTableView else { return }
            let row = tableView.clickedRow
            let inRange = row >= 0 && rows.indices.contains(row)
            let isDeleted = inRange && editing.deletedRows.contains(row)
            for item in menu.items {
                if item.action == #selector(CopyableTableView.markRowForDeletion(_:)) {
                    item.isHidden = !editing.isActive
                    item.isEnabled = editing.isActive && inRange && !isDeleted
                } else if item.action == #selector(CopyableTableView.unmarkRowForDeletion(_:)) {
                    item.isHidden = !editing.isActive
                    item.isEnabled = editing.isActive && inRange && isDeleted
                }
            }
        }

        /// 右键「标记删除 / 取消删除」：**由这一行当前删没删决定动作**（菜单项标题已经写明了），
        /// 用 `clickedRow`（用户右键点的那一行），不用选中态。
        func toggleRowDeletion(from tableView: NSTableView) {
            guard editing.isActive else { return }
            let row = tableView.clickedRow
            guard row >= 0, rows.indices.contains(row) else { return }
            onToggleRowDeletion?(row, editing.deletedRows.contains(row))
        }

        private static func font(isNumeric: Bool) -> NSFont {
            isNumeric ? Theme.nsFont(.data) : Theme.nsFont(.body)
        }

        private static func makeColumn(index: Int, meta: ColumnMeta, rows: [[String?]]) -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col-\(index)"))
            let isNumeric = ColumnAlignment.isNumeric(typeName: meta.typeName)
            let header = ResultHeaderCell()
            header.attributedStringValue = NSAttributedString(
                string: meta.name,
                attributes: [
                    .font: Theme.nsFont(.caption),
                    .foregroundColor: Theme.nsColor(TextTone.tertiary)
                ]
            )
            // 表头与它的列同向对齐：数值列表头也右对齐，扫一眼就知道该看哪边
            header.alignment = isNumeric ? .right : .left
            column.headerCell = header
            column.headerToolTip = "\(meta.name) · \(meta.typeName)"
            column.minWidth = Metrics.minColumnWidth
            column.width = estimatedWidth(for: meta, index: index, rows: rows)
            // 有排序原型，AppKit 才会画表头指示器并派发 sortDescriptorsDidChange。
            column.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
            return column
        }

        private static func estimatedWidth(for meta: ColumnMeta, index: Int, rows: [[String?]]) -> CGFloat {
            let font = font(isNumeric: ColumnAlignment.isNumeric(typeName: meta.typeName))
            var width = measuredWidth(meta.name, font: Theme.nsFont(.caption)) + Spacing.xl
            let sampleCount = min(rows.count, Metrics.columnWidthSampleRows)
            for rowIndex in 0..<sampleCount {
                guard rows[rowIndex].indices.contains(index) else { continue }
                let value = rows[rowIndex][index] ?? "NULL"
                width = max(width, measuredWidth(value, font: font) + Spacing.l)
            }
            return min(max(width, Metrics.minColumnWidth), Metrics.maxColumnWidth)
        }

        private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        // MARK: 复制

        /// 默认复制（⌘C）：TSV。实际渲染交给 Core 的 `ResultClipboard` ——
        /// 多格式必须共用一处实现，否则"TSV 的转义与 Markdown 的转义"迟早各自演化。
        func copySelection(from tableView: NSTableView) {
            copySelection(from: tableView, as: ResultClipboard.defaultFormat)
        }

        /// 右键「跳到被引用行…」（FR-DATA-06）：取**点击位置**那一格的列名与值。
        ///
        /// 用 `clickedRow` / `clickedColumn` 而不是选中态：右键点在哪一格，用户要的就是那一格。
        /// 值拿不到（越界）时不猜、不传空串 —— 上层会按"没有值"给可读提示。
        func jumpToReferencedRow(from tableView: NSTableView) {
            guard let result else { return }
            let row = tableView.clickedRow
            let column = tableView.clickedColumn
            guard row >= 0, column >= 0,
                  rows.indices.contains(row),
                  result.columns.indices.contains(column) else { return }
            let values = rows[row]
            let value = values.indices.contains(column) ? values[column] : nil
            onJumpToReferencedRow?(result.columns[column].name, value)
        }

        /// 按指定格式复制选中的行（FR-RES-12）。
        ///
        /// **行为变化（有意，已记进变更记录）**：TSV 里的 NULL 以前写成字面量 `NULL`，
        /// 现在与导出层一致 —— TSV / CSV 留空（贴进电子表格不该多出一列"NULL"文字），
        /// Markdown / INSERT 仍写 `NULL`（文档与 SQL 里必须看得出是空值）。
        func copySelection(from tableView: NSTableView, as format: ResultClipboard.Format) {
            guard let result else { return }
            let selectedRows = tableView.selectedRowIndexes.sorted()
            guard !selectedRows.isEmpty else { return }

            // 用**当前显示的行**：分页 / 筛选之后，索引指向的是显示顺序。
            let selected = selectedRows.compactMap { index -> [String?]? in
                rows.indices.contains(index) ? rows[index] : nil
            }
            let text = ResultClipboard.text(
                rows: selected,
                columns: result.columns,
                format: format
            )
            guard !text.isEmpty else { return }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        private func columnIndex(from column: NSTableColumn) -> Int? {
            let raw = column.identifier.rawValue
            guard raw.hasPrefix("col-") else { return nil }
            return Int(raw.dropFirst("col-".count))
        }
    }
}

// MARK: - 自绘的行

/// 结果表的一行：斑马纹、选中态、底部发丝线都由自己画。
///
/// 为什么不交给 AppKit：`usesAlternatingRowBackgroundColors` 与
/// `selectionHighlightStyle` 的颜色不受设计令牌控制，深浅两种外观下都会
/// 与相邻面板"差一点点" —— 而"差一点点"正是这次外观改造要消灭的东西。
private final class ResultRowView: NSTableRowView {

    var rowIndex: Int = 0

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.nsColor(Surface.content).setFill()
        bounds.fill()

        // 斑马纹：极淡（透明度取自 `Overlay.Zebra`），只在长表里帮助横向追行
        if rowIndex % 2 == 1 {
            let alpha = Theme.isDarkAppearance ? Overlay.Zebra.darkAlpha : Overlay.Zebra.lightAlpha
            Theme.nsColor(TextTone.primary).withAlphaComponent(CGFloat(alpha)).setFill()
            bounds.fill()
        }

        // 底部发丝线：一行 1 像素，比系统的磅线轻得多
        Theme.hairlineNSColor.setFill()
        NSRect(x: 0, y: bounds.maxY - Metrics.hairline, width: bounds.width, height: Metrics.hairline).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        Theme.accentTintNSColor.setFill()
        bounds.fill()
        // 左侧 2pt 强调条：与活动栏、侧栏选中态同一套语言
        Theme.accentNSColor.setFill()
        NSRect(x: 0, y: 0, width: Spacing.hair, height: bounds.height).fill()
    }
}

// MARK: - 自绘的表头

/// 表头单元格：字体 / 颜色 / 背景都走令牌。
private final class ResultHeaderCell: NSTableHeaderCell {

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.nsColor(Surface.panel).setFill()
        cellFrame.fill()
        // 标题要自己留出左右内边距：`drawInterior` 不会代劳，直接用 cellFrame 会贴着左边缘
        let interior = NSRect(
            x: cellFrame.minX + Spacing.s,
            y: cellFrame.minY,
            width: max(0, cellFrame.width - Spacing.s * 2),
            height: cellFrame.height
        )
        super.drawInterior(withFrame: interior, in: controlView)

        Theme.hairlineNSColor.setFill()
        NSRect(
            x: cellFrame.maxX - Metrics.hairline,
            y: cellFrame.minY,
            width: Metrics.hairline,
            height: cellFrame.height
        ).fill()
        NSRect(
            x: cellFrame.minX,
            y: cellFrame.maxY - Metrics.hairline,
            width: cellFrame.width,
            height: Metrics.hairline
        ).fill()
    }
}

// MARK: - 一格（带行 / 列记忆）

/// 结果表里的一格。
///
/// 为什么要把行列号存在**控件**上：就地编辑结束时（`controlTextDidEndEditing`）只拿得到一个
/// `NSTextField`，而那一刻表格的 `clickedRow` 可能已经指向别的行（用户直接点了别处）——
/// 靠"当时的表格状态"反查会把改动记到另一格上。
private final class ResultCellTextField: NSTextField {
    var cellRow = -1
    var cellColumn = -1
    /// 进入编辑时这一格显示的文本：用来判断"到底改没改"。
    var originalText: String?
}

// MARK: - 复制支持

private protocol ResultGridCopying: AnyObject {
    func copySelection(from tableView: NSTableView)
    func copySelection(from tableView: NSTableView, as format: ResultClipboard.Format)
    /// 右键「跳到被引用行…」（FR-DATA-06）。
    func jumpToReferencedRow(from tableView: NSTableView)
    /// 右键「标记删除此行 / 取消删除标记」（FR-DATA-04）。
    func toggleRowDeletion(from tableView: NSTableView)
}

/// 让 ⌘C 与右键菜单能复制选中的单元格（TSV 格式）。
private final class CopyableTableView: NSTableView {
    @objc func copy(_ sender: Any?) {
        (dataSource as? ResultGridCopying)?.copySelection(from: self)
    }

    /// 「复制为…」子菜单的入口：格式经 `representedObject` 传进来，**不靠标题反查**
    /// （标题会本地化，用它做分派等于把动作绑在文案上）。
    @objc func copyAs(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let format = ResultClipboard.Format(rawValue: raw)
        else { return }
        (dataSource as? ResultGridCopying)?.copySelection(from: self, as: format)
    }

    /// 右键「跳到被引用行…」：用**点击位置**（不是选中行）取值 ——
    /// 用户右键点的那一格才是他想要的那一格，选中态可能停在别处。
    @objc func jumpToReferencedRow(_ sender: Any?) {
        (dataSource as? ResultGridCopying)?.jumpToReferencedRow(from: self)
    }

    /// 标记删除 / 取消删除：两个菜单项走同一个动作，实际是哪一种由协调器按
    /// "这一行当前删没删"决定（菜单项本身只负责把点击递过来）。
    @objc func markRowForDeletion(_ sender: Any?) {
        (dataSource as? ResultGridCopying)?.toggleRowDeletion(from: self)
    }

    @objc func unmarkRowForDeletion(_ sender: Any?) {
        (dataSource as? ResultGridCopying)?.toggleRowDeletion(from: self)
    }
}
