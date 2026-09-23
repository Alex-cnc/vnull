import SwiftUI
import AppKit
import DoyahCore

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
        tableView.menu = menu

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
            tableView: tableView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.update(
            result: result,
            rows: displayedRows ?? result.rows,
            sortDescriptors: sortDescriptors,
            onToggleSort: onToggleSort,
            tableView: tableView
        )
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, ResultGridCopying {

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
            tableView: NSTableView
        ) {
            self.result = result
            self.rows = rows
            self.onToggleSort = onToggleSort
            syncSortDescriptors(sortDescriptors, tableView: tableView)

            // 换结果集：选中态作废（旧的行号对新数据没有意义）。
            if result.id != lastResultID {
                lastResultID = result.id
                lastSelectedRows = tableView.selectedRowIndexes
                tableView.deselectAll(nil)
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
                tableView.reloadData()
            }
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

            let value = rows[row][columnIndex]
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
                let textField = NSTextField(labelWithString: "")
                textField.lineBreakMode = .byTruncatingTail
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.alignment = isNumeric ? .right : .left
                textField.font = Self.font(isNumeric: isNumeric)
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Spacing.s),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Spacing.s),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }

            cell.textField?.stringValue = value ?? "NULL"
            cell.textField?.textColor = value == nil
                ? Theme.nsColor(TextTone.tertiary)
                : (isSelected ? Theme.nsColor(TextTone.primary) : Theme.nsColor(TextTone.secondary))
            cell.toolTip = value
            return cell
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

        func copySelection(from tableView: NSTableView) {
            guard let result else { return }
            let selectedRows = tableView.selectedRowIndexes.sorted()
            guard !selectedRows.isEmpty else { return }

            var lines: [String] = [result.columns.map { $0.name }.joined(separator: "\t")]
            for rowIndex in selectedRows {
                // 用**当前显示的行**：分页 / 筛选之后，索引指向的是显示顺序。
                guard rows.indices.contains(rowIndex) else { continue }
                let row = rows[rowIndex]
                let cells = (0..<result.columns.count).map { index -> String in
                    guard row.indices.contains(index) else { return "" }
                    return row[index] ?? "NULL"
                }
                lines.append(cells.joined(separator: "\t"))
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
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

// MARK: - 复制支持

private protocol ResultGridCopying: AnyObject {
    func copySelection(from tableView: NSTableView)
}

/// 让 ⌘C 与右键菜单能复制选中的单元格（TSV 格式）。
private final class CopyableTableView: NSTableView {
    @objc func copy(_ sender: Any?) {
        (dataSource as? ResultGridCopying)?.copySelection(from: self)
    }
}
