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
    /// 编辑模式下读取既有索引与约束；不支持 / 新建模式为 nil。
    var loadExtras: (() async throws -> (indexes: [TableIndexInfo], constraints: [TableConstraintInfo]))?
    let onSubmit: (TableDesignSubmission) -> Void

    @State private var tableName = ""
    @State private var schema = ""
    @State private var columns: [TableColumnDefinition] = [
        TableColumnDefinition(name: "id", typeName: "bigint", isNullable: false, isPrimaryKey: true)
    ]
    @State private var original: [TableColumnDefinition] = []
    @State private var isLoading = false
    @State private var loadError: String?

    // 索引 / 外键 / 约束（FR-DDL-03 扩写）
    @State private var existingIndexes: [TableIndexInfo] = []
    @State private var existingConstraints: [TableConstraintInfo] = []
    @State private var droppedIndexes: Set<String> = []
    @State private var droppedConstraints: Set<String> = []
    @State private var newIndexes: [TableDesignExtrasSection.IndexDraft] = []
    @State private var newForeignKeys: [TableDesignExtrasSection.ForeignKeyDraft] = []
    @State private var newConstraints: [TableConstraintDraft] = []

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

            TableDesignExtrasSection(
                indexes: existingIndexes,
                constraints: existingConstraints,
                isLoading: isLoading,
                droppedIndexes: $droppedIndexes,
                droppedConstraints: $droppedConstraints,
                newIndexes: $newIndexes,
                newForeignKeys: $newForeignKeys,
                newConstraints: $newConstraints,
                isEditing: isEditing
            )

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
                    onSubmit(TableDesignSubmission(
                        name: tableName,
                        schema: trimmedSchema,
                        changeSet: changeSet
                    ))
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

    /// 编辑模式要执行的语句：**列 + 索引 + 外键 + 约束一起排**，顺序由 Core 决定
    /// （删约束 → 删索引 → 列变更 → 新索引 → 新外键 → 新约束）。
    private var statements: [String] {
        TableDesignChangeSet.statements(
            for: changeSet,
            table: tableName.isEmpty ? "table_name" : tableName,
            schema: trimmedSchema,
            dialect: SQLDialectFactory.make(for: databaseType)
        )
    }

    /// 破坏性语句：删列 / 改类型 / 删索引 / 删约束 —— 都要在提交前醒目列出。
    ///
    /// 按**语句内容**判定，而不是与 `changes` 逐个 zip：变更集里现在还有索引与约束语句，
    /// 下标早就对不上了（错位的结果要么把无害语句标成破坏性，要么反过来 —— 后者会真出事）。
    private var destructiveChanges: [String] {
        guard isEditing else { return [] }
        return statements.filter { statement in
            statement.hasPrefix("DROP INDEX")
                || statement.contains("DROP CONSTRAINT")
                || statement.contains("DROP COLUMN")
                || statement.contains("ALTER COLUMN")
        }
    }

    /// 完整变更集（列 + 索引 + 外键 + 约束）：**预览与提交共用同一份**，
    /// 避免"预览看着对、提交的却是另一批语句"。
    private var changeSet: TableDesignChangeSet {
        TableDesignChangeSet(
            originalColumns: original,
            editedColumns: columns,
            newIndexes: newIndexes.compactMap { draft in
                let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsedColumns = draft.columns
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard !name.isEmpty, !parsedColumns.isEmpty else { return nil }
                let whereClause = draft.whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
                return SQLGenerator.IndexDefinition(
                    name: name,
                    table: tableName.trimmingCharacters(in: .whitespacesAndNewlines),
                    schema: trimmedSchema,
                    columns: parsedColumns,
                    isUnique: draft.isUnique,
                    whereClause: whereClause.isEmpty ? nil : whereClause
                )
            },
            droppedIndexes: Array(droppedIndexes),
            newForeignKeys: newForeignKeys.compactMap { draft in
                let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsedColumns = draft.columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let referencedTable = draft.referencedTable.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsedReferenced = draft.referencedColumns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !referencedTable.isEmpty, !parsedColumns.isEmpty, !parsedReferenced.isEmpty else { return nil }
                return SQLGenerator.ForeignKeyDefinition(
                    name: name.isEmpty ? nil : name,
                    table: tableName.trimmingCharacters(in: .whitespacesAndNewlines),
                    schema: trimmedSchema,
                    columns: parsedColumns,
                    referencedTable: referencedTable,
                    referencedColumns: parsedReferenced,
                    onDelete: draft.onDelete,
                    onUpdate: draft.onUpdate
                )
            },
            newConstraints: newConstraints.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            droppedConstraints: Array(droppedConstraints)
        )
    }

    private var previewText: String {
        guard isEditing else {
            // 新建：**预览就是执行计划本身**（`createTablePlan`），不在这里另拼一份 ——
            // 拼两份必然分叉：曾经预览是"建表 + 索引/约束"，执行却拿到完整变更集，
            // 于是每列又 ADD COLUMN 一次（MySQL：Duplicate column name 'id'，2026-09-25 实测）。
            let target = tableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "table_name"
                : tableName
            let plan = TableDesignChangeSet.createTablePlan(
                table: target,
                columns: columns,
                schema: trimmedSchema,
                extras: changeSet,
                dialect: SQLDialectFactory.make(for: databaseType)
            )
            return plan.isEmpty ? L(.tableDesignInvalid) : plan.joined(separator: "\n")
        }
        return statements.isEmpty ? L(.tableDesignNoChanges) : statements.joined(separator: "\n")
    }

    private var issues: [TableDesign.Issue] {
        guard !isLoading, loadError == nil else { return [] }
        return TableDesign.validate(tableName: tableName, columns: columns)
    }

    private var canSubmit: Bool {
        guard !isLoading, loadError == nil, issues.isEmpty else { return false }
        // 编辑模式：改了列、或动了索引 / 约束，都算"有东西可提交"。
        if isEditing { return changeSet.hasChanges }
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
            // 索引 / 约束读取失败**不该挡住改列**：分开处理，读不到就明说"暂不支持读取"。
            if let loadExtras {
                let extras = try await loadExtras()
                existingIndexes = extras.indexes
                existingConstraints = extras.constraints
            }
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
