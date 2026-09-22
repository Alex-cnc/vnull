import SwiftUI
import DoyahCore

/// 「新建表」表单（FR-DDL-03）。
///
/// 设计原则与库属性 / 授权面板一致：**先把将要执行的 DDL 完整摊开**，看到什么就执行什么；
/// 本地校验不通过时禁用「创建」，并逐条列出原因（指到第几列，找起来才快）。
/// 类型是自由文本而不是下拉：各方言类型差别太大，硬塞一个列表反而会挡住人。
struct CreateTableSheet: View {
    @Environment(\.dismiss) private var dismiss

    let databaseType: DatabaseType
    /// 从对象树带过来的模式（在 database 节点上为空）。
    var initialSchema: String?
    let onCreate: (String, String?, [TableColumnDefinition]) -> Void

    @State private var tableName = ""
    @State private var schema = ""
    @State private var columns: [TableColumnDefinition] = [
        TableColumnDefinition(name: "id", typeName: "bigint", isNullable: false, isPrimaryKey: true)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(.tableDesignTitle))
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                field(L(.tableDesignName)) {
                    TextField("", text: $tableName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                field(L(.tableDesignSchema)) {
                    TextField("", text: $schema)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }

            Text(L(.tableDesignSchemaHint))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text(L(.tableDesignColumns))
                    .font(.subheadline)
                    .bold()
                Spacer()
                Button {
                    columns.append(TableColumnDefinition(typeName: "text"))
                } label: {
                    Label(L(.tableDesignAddColumn), systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            columnEditor

            if !issues.isEmpty {
                issuesList
            }

            Divider()

            Text(L(.tableDesignPreview))
                .font(.subheadline)
                .bold()

            ScrollView {
                Text(ddl)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Text(L(.tableDesignHint))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(L(.commonCancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L(.tableDesignCreate)) {
                    onCreate(tableName, schema, columns)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!issues.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 820)
        .onAppear {
            if schema.isEmpty, let initialSchema { schema = initialSchema }
        }
    }

    // MARK: 列编辑

    private var columnEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L(.tableDesignColumnName)).font(.caption2).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                Text(L(.tableDesignColumnType)).font(.caption2).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                Text(L(.tableDesignColumnNullable)).font(.caption2).foregroundStyle(.secondary).frame(width: 52)
                Text(L(.tableDesignColumnPrimaryKey)).font(.caption2).foregroundStyle(.secondary).frame(width: 44)
                Text(L(.tableDesignColumnDefault)).font(.caption2).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                Spacer(minLength: 0)
            }

            ForEach($columns) { $column in
                HStack(spacing: 8) {
                    TextField("", text: $column.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    TextField("", text: $column.typeName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Toggle("", isOn: $column.isNullable)
                        .labelsHidden()
                        .frame(width: 52)
                    Toggle("", isOn: $column.isPrimaryKey)
                        .labelsHidden()
                        .frame(width: 44)
                    TextField("", text: $column.defaultValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Button {
                        columns.removeAll { $0.id == column.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L(.tableDesignRemoveColumn))
                    .disabled(columns.count <= 1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var issuesList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(text(for: issue))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 计算

    private var issues: [TableDesign.Issue] {
        TableDesign.validate(tableName: tableName, columns: columns)
    }

    private var trimmedSchema: String? {
        let value = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 预览用的 DDL。表名为空时用占位名，好让使用者先看清结构。
    private var ddl: String {
        let name = tableName.trimmingCharacters(in: .whitespacesAndNewlines)
        return SQLGenerator.createTable(
            table: name.isEmpty ? "table_name" : name,
            columns: columns,
            schema: trimmedSchema,
            dialect: SQLDialectFactory.make(for: databaseType)
        )
    }

    private func text(for issue: TableDesign.Issue) -> String {
        if let argument = issue.argument {
            return L(issue.textKey, argument)
        }
        return L(issue.textKey)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
