import SwiftUI
import DoyahCore

/// 表设计面板：**新建表** 与 **编辑已有表结构**（FR-DDL-03）。
///
/// 两种模式共用同一套列编辑器，差异只在"预览什么"和"提交什么"：
/// 新建预览 `CREATE TABLE`；编辑则把原结构与编辑后的结构做差异，预览要执行的 `ALTER TABLE` 列表。
///
/// 设计原则沿用库属性 / 授权面板：**先把将要执行的语句摊开**，看到什么就执行什么；
/// 本地校验不过就禁用提交并逐条说明；破坏性变更（删列 / 改类型）单独醒目提示。
struct TableDesignSheet: View {
    enum Mode: Equatable {
        case create
        case alter(tableName: String)
    }

    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let databaseType: DatabaseType
    var initialSchema: String?
    /// 编辑模式下读取原始结构；新建模式为 nil。
    var loadStructure: (() async throws -> [TableColumnDefinition])?
    /// (表名, schema, 原始结构, 编辑后的结构)。新建模式下原始结构为空数组。
    let onSubmit: (String, String?, [TableColumnDefinition], [TableColumnDefinition]) -> Void

    @State private var tableName = ""
    @State private var schema = ""
    @State private var columns: [TableColumnDefinition] = [
        TableColumnDefinition(name: "id", typeName: "bigint", isNullable: false, isPrimaryKey: true)
    ]
    @State private var original: [TableColumnDefinition] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var isEditing: Bool {
        if case .alter = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? L(.tableDesignAlterTitle) : L(.tableDesignTitle))
                .font(.headline)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L(.tableDesignLoading)).foregroundStyle(.secondary)
                }
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 16) {
                field(L(.tableDesignName)) {
                    TextField("", text: $tableName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .disabled(isEditing)
                }
                field(L(.tableDesignSchema)) {
                    TextField("", text: $schema)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .disabled(isEditing)
                }
            }

            Text(L(.tableDesignSchemaHint))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text(L(.tableDesignColumns)).font(.subheadline).bold()
                Spacer()
                Button {
                    columns.append(TableColumnDefinition(typeName: "text"))
                } label: {
                    Label(L(.tableDesignAddColumn), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
            }

            columnEditor

            if isEditing {
                Text(L(.tableDesignPrimaryKeyLocked))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !issues.isEmpty {
                issuesList
            }

            if !destructiveChanges.isEmpty {
                destructiveWarning
            }

            Divider()

            Text(L(.tableDesignPreview)).font(.subheadline).bold()

            ScrollView {
                Text(previewText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 120)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Text(L(.tableDesignHint))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(L(.commonCancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? L(.tableDesignApply) : L(.tableDesignCreate)) {
                    onSubmit(tableName, schema, original, columns)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 860)
        .task { await loadIfNeeded() }
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
                    // 编辑已有表时主键只读：改主键要删约束再重建，容易误伤数据，留给后续版本。
                    Toggle("", isOn: $column.isPrimaryKey)
                        .labelsHidden()
                        .frame(width: 44)
                        .disabled(isEditing)
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
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(text(for: issue)).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var destructiveWarning: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(L(.tableDesignDestructive), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            ForEach(Array(destructiveChanges.enumerated()), id: \.offset) { _, statement in
                Text(statement)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 计算

    private var changes: [TableDesign.ColumnChange] {
        TableDesign.columnChanges(original: original, edited: columns)
    }

    private var statements: [String] {
        SQLGenerator.alterTableStatements(
            table: tableName.isEmpty ? "table_name" : tableName,
            schema: trimmedSchema,
            changes: changes,
            dialect: SQLDialectFactory.make(for: databaseType)
        )
    }

    private var destructiveChanges: [String] {
        guard isEditing else { return [] }
        let changes = changes
        let statements = statements
        return zip(changes, statements).filter { $0.0.isDestructive }.map(\.1)
    }

    private var previewText: String {
        guard isEditing else {
            return SQLGenerator.createTable(
                table: tableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "table_name"
                    : tableName,
                columns: columns,
                schema: trimmedSchema,
                dialect: SQLDialectFactory.make(for: databaseType)
            )
        }
        return statements.isEmpty ? L(.tableDesignNoChanges) : statements.joined(separator: "\n")
    }

    private var issues: [TableDesign.Issue] {
        guard !isLoading, loadError == nil else { return [] }
        return TableDesign.validate(tableName: tableName, columns: columns)
    }

    private var canSubmit: Bool {
        guard !isLoading, loadError == nil, issues.isEmpty else { return false }
        if isEditing { return !changes.isEmpty }
        return true
    }

    private var trimmedSchema: String? {
        let value = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func text(for issue: TableDesign.Issue) -> String {
        if let argument = issue.argument {
            return L(issue.textKey, argument)
        }
        return L(issue.textKey)
    }

    private func loadIfNeeded() async {
        if case .alter(let name) = mode {
            tableName = name
        }
        if schema.isEmpty, let initialSchema {
            schema = initialSchema
        }
        guard isEditing, let loadStructure else { return }

        isLoading = true
        loadError = nil
        do {
            let loaded = try await loadStructure()
            original = loaded
            columns = loaded
        } catch {
            loadError = L(.tableDesignLoadFailed, ErrorPresenter.message(for: error))
        }
        isLoading = false
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
