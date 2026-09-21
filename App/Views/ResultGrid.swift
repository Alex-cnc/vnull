import SwiftUI
import AppKit
import PostgresClientCore

/// 结果表格：NSTableView 桥接实现。
///
/// 相比 SwiftUI `Grid`，这里能得到列宽调整、列排序、多选、⌘C 复制，
/// 以及大结果集下的单元格复用。
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
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 12, height: 2)
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.gridColor = .separatorColor
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
        private static let cellFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        private var result: QueryResult?
        private var lastResultID: UUID?
        private var columnSignature: [String] = []

        func numberOfRows(in tableView: NSTableView) -> Int {
            result?.rows.count ?? 0
        }

        func update(result: QueryResult, tableView: NSTableView) {
            self.result = result
            guard result.id != lastResultID else { return }
            lastResultID = result.id

            let signature = result.columns.map { "\($0.name)|\($0.typeName)" }
            if signature != columnSignature {
                columnSignature = signature
                for column in tableView.tableColumns {
                    tableView.removeTableColumn(column)
                }
                for (index, meta) in result.columns.enumerated() {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col-\(index)"))
                    column.title = meta.name
                    column.headerToolTip = "\(meta.name) · \(meta.typeName)"
                    column.minWidth = 40
                    column.width = Self.estimatedWidth(for: meta, index: index, result: result)
                    tableView.addTableColumn(column)
                }
            }

            tableView.reloadData()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let result,
                  result.rows.indices.contains(row),
                  let columnIndex = columnIndex(from: tableColumn),
                  result.rows[row].indices.contains(columnIndex) else {
                return nil
            }

            let value = result.rows[row][columnIndex]
            let identifier = NSUserInterfaceItemIdentifier("result-cell")

            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let textField = NSTextField(labelWithString: "")
                textField.font = Self.cellFont
                textField.lineBreakMode = .byTruncatingTail
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }

            cell.textField?.stringValue = value ?? "NULL"
            cell.textField?.textColor = value == nil ? .tertiaryLabelColor : .labelColor
            cell.toolTip = value
            return cell
        }

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

        private static func estimatedWidth(for meta: ColumnMeta, index: Int, result: QueryResult) -> CGFloat {
            var width = measuredWidth(meta.name) + 28
            let sampleCount = min(result.rows.count, 100)
            for rowIndex in 0..<sampleCount {
                guard result.rows[rowIndex].indices.contains(index) else { continue }
                let value = result.rows[rowIndex][index] ?? "NULL"
                width = max(width, measuredWidth(value) + 20)
            }
            return min(max(width, 60), 420)
        }

        private static func measuredWidth(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: cellFont]).width
        }
    }
}

private protocol ResultGridCopying: AnyObject {
    func copySelection(from tableView: NSTableView)
}

/// 让 ⌘C 与右键菜单能复制选中的单元格（TSV 格式）。
private final class CopyableTableView: NSTableView {
    @objc func copy(_ sender: Any?) {
        (dataSource as? ResultGridCopying)?.copySelection(from: self)
    }
}
