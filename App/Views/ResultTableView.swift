import SwiftUI
import PostgresClientCore

struct ResultTableView: View {
    let result: QueryResult?
    var resultCount: Int = 0
    var selectedIndex: Int = 0
    var onSelectResult: ((Int) -> Void)?
    var isExecuting: Bool = false
    /// 导出当前结果集（FR-RES-06）。为 nil 时不显示导出按钮。
    var onExport: ((ResultExportFormat) -> Void)?

    var body: some View {
        Group {
            if let result {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(L(.resultTitle))
                            .font(.headline)

                        if resultCount > 1 {
                            Picker("", selection: Binding(
                                get: { selectedIndex },
                                set: { onSelectResult?($0) }
                            )) {
                                ForEach(0..<resultCount, id: \.self) { index in
                                    Text(L(.resultPickerItem, index + 1)).tag(index)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 180)
                        }

                        Spacer()

                        if let onExport, ResultExporter.hasExportableContent(result) {
                            Menu {
                                Button(L(.exportCSV)) { onExport(.csv) }
                                Button(L(.exportJSON)) { onExport(.json) }
                                Divider()
                                Button(L(.exportTSV)) { onExport(.tsv) }
                                Button(L(.exportMarkdown)) { onExport(.markdown) }
                                Button(L(.exportSQLInsert)) { onExport(.sqlInsert) }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(L(.resultExport))
                        }

                        if result.columnCount > 0 {
                            Text(L(.resultSize, result.rowCount, result.columnCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if result.executionTime > 0 {
                            Text("· \(String(format: "%.3f", result.executionTime))s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    if result.columns.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.largeTitle)
                                .foregroundStyle(.green)
                            Text(L(.resultNoResultSet))
                                .foregroundStyle(.secondary)
                            if let affected = result.affectedRows {
                                Text(L(.resultAffectedRows, affected))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ResultGrid(result: result)
                    }
                }
            } else if isExecuting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L(.resultExecuting))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    L(.resultEmptyTitle),
                    systemImage: "tablecells",
                    description: Text(L(.resultEmptyDescription))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
