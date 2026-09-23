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

        context.coordinator.update(result: result, tableView: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.update(result: result, tableView: tableView)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, ResultGridCopying {

        private var result: QueryResult?
        private var lastResultID: UUID?
        private var columnSignature: [String] = []
        /// 每列是否按数值处理（右对齐 + 等宽数字）。列在重建时才变。
        private var columnIsNumeric: [Bool] = []
        /// 上一次的选中集合：用来只重画"选中态真的变了"的那几行。
        private var lastSelectedRows = IndexSet()

        func numberOfRows(in tableView: NSTableView) -> Int {
            result?.rows.count ?? 0
        }

        func update(result: QueryResult, tableView: NSTableView) {
            self.result = result
            guard result.id != lastResultID else { return }
            lastResultID = result.id
            lastSelectedRows = tableView.selectedRowIndexes

            let signature = result.columns.map { "\($0.name)|\($0.typeName)" }
            if signature != columnSignature {
                columnSignature = signature
                columnIsNumeric = result.columns.map { ColumnAlignment.isNumeric(typeName: $0.typeName) }
                for column in tableView.tableColumns {
                    tableView.removeTableColumn(column)
                }
                for (index, meta) in result.columns.enumerated() {
                    tableView.addTableColumn(Self.makeColumn(index: index, meta: meta, result: result))
                }
            }

            tableView.reloadData()
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
                  result.rows.indices.contains(row),
                  let columnIndex = columnIndex(from: tableColumn),
                  result.rows[row].indices.contains(columnIndex) else {
                return nil
            }

            let value = result.rows[row][columnIndex]
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

        private static func makeColumn(index: Int, meta: ColumnMeta, result: QueryResult) -> NSTableColumn {
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
            column.width = estimatedWidth(for: meta, index: index, result: result)
            return column
        }

        private static func estimatedWidth(for meta: ColumnMeta, index: Int, result: QueryResult) -> CGFloat {
            let font = font(isNumeric: ColumnAlignment.isNumeric(typeName: meta.typeName))
            var width = measuredWidth(meta.name, font: Theme.nsFont(.caption)) + Spacing.xl
            let sampleCount = min(result.rows.count, Metrics.columnWidthSampleRows)
            for rowIndex in 0..<sampleCount {
                guard result.rows[rowIndex].indices.contains(index) else { continue }
                let value = result.rows[rowIndex][index] ?? "NULL"
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
                guard result.rows.indices.contains(rowIndex) else { continue }
                let row = result.rows[rowIndex]
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
