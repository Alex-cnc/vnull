import SwiftUI
import DoyahCore

/// 表设计面板的**索引 / 外键 / 约束**区（FR-DDL-03 扩写）。
///
/// 与列编辑合起来才是完整的表结构编辑器。三个设计决定写在明处：
/// 1. **已存在的对象列出来，可勾选删除** —— 删不掉东西的编辑器只会让人回到命令行；
/// 2. **主键不给删**：它是表的身份，误点的代价太大（要用界面就说清"请用 SQL"）；
/// 3. 新加的东西**只是草稿**，真正的语句由 `TableDesignChangeSet` 统一排版（顺序由 Core 决定）。
struct TableDesignExtrasSection: View {

    /// 已存在的索引 / 约束（编辑模式下加载；新建模式为空）。
    let indexes: [TableIndexInfo]
    let constraints: [TableConstraintInfo]
    let isLoading: Bool

    /// 待删除的既有对象名。
    @Binding var droppedIndexes: Set<String>
    @Binding var droppedConstraints: Set<String>

    /// 新加的草稿。
    @Binding var newIndexes: [IndexDraft]
    @Binding var newForeignKeys: [ForeignKeyDraft]
    @Binding var newConstraints: [TableConstraintDraft]

    /// 新建表时还没有既有对象，也没有"删除"可言。
    let isEditing: Bool

    struct IndexDraft: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var columns = ""
        var isUnique = false
        /// 部分索引条件（可空）。
        var whereClause = ""
    }

    struct ForeignKeyDraft: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var columns = ""
        var referencedTable = ""
        var referencedColumns = ""
        var onDelete: SQLGenerator.ReferentialAction?
        var onUpdate: SQLGenerator.ReferentialAction?

        /// 引用动作的中文/英文标签（Core 只给 `rawValue`，文案在界面层）。
        static func labelKey(_ action: SQLGenerator.ReferentialAction?) -> String {
            guard let action else { return L(.referentialActionNone) }
            switch action {
            case .noAction: return L(.referentialActionNoAction)
            case .restrict: return L(.referentialActionRestrict)
            case .cascade: return L(.referentialActionCascade)
            case .setNull: return L(.referentialActionSetNull)
            case .setDefault: return L(.referentialActionSetDefault)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Divider()

            // ── 索引
            header(L(.tableDesignIndexes)) {
                newIndexes.append(IndexDraft())
            }
            if isEditing {
                existingList(
                    items: indexes.map { ($0.name, $0.definition) },
                    emptyText: L(.tableDesignNoIndexes),
                    dropped: $droppedIndexes,
                    isRemovable: { _ in true }
                )
            }
            ForEach($newIndexes) { $draft in
                indexRow($draft)
            }

            // ── 外键与约束
            HStack {
                Text(L(.tableDesignConstraints)).font(Theme.font(.bodyStrong))
                Spacer()
                Button {
                    newConstraints.append(TableConstraintDraft())
                } label: {
                    Label(L(.tableDesignAddConstraint), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Button {
                    newForeignKeys.append(ForeignKeyDraft())
                } label: {
                    Label(L(.tableDesignAddForeignKey), systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            if isEditing {
                existingList(
                    items: constraints.map { ($0.name, "\(kindLabel($0.kind)) · \($0.definition)") },
                    emptyText: L(.tableDesignNoConstraints),
                    dropped: $droppedConstraints,
                    // 主键不给删：误点的代价太大，界面明确写"请用 SQL"。
                    isRemovable: { name in
                        constraints.first { $0.name == name }?.kind.isRemovable ?? true
                    }
                )
            }
            ForEach($newForeignKeys) { $draft in
                foreignKeyRow($draft)
            }
            ForEach($newConstraints) { $draft in
                constraintRow($draft)
            }

            Text(L(.tableDesignExtrasHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 公用零件

    /// 区块标题 + 「加一条」按钮。
    ///
    /// 不要给它泛型 `Content` 或 `@ViewBuilder`：这里只是调用一个动作，
    /// 两者都会让编译器推不出类型（本轮实测报的就是这个）。
    private func header(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(Theme.font(.bodyStrong))
            Spacer()
            Button(action: add) {
                Label(L(.tableDesignAddIndex), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func existingList(
        items: [(String, String)],
        emptyText: String,
        dropped: Binding<Set<String>>,
        isRemovable: @escaping (String) -> Bool
    ) -> some View {
        if items.isEmpty {
            Text(emptyText)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
        } else {
            ForEach(items, id: \.0) { name, definition in
                HStack(spacing: Spacing.s) {
                    Toggle("", isOn: Binding(
                        get: { !dropped.wrappedValue.contains(name) },
                        set: { keep in
                            if keep {
                                dropped.wrappedValue.remove(name)
                            } else {
                                dropped.wrappedValue.insert(name)
                            }
                        }
                    ))
                    .labelsHidden()
                    .disabled(!isRemovable(name))

                    Text(name)
                        .font(Theme.font(.monoSmall))
                        .foregroundStyle(isRemovable(name) ? Theme.text(.primary) : Theme.text(.tertiary))

                    Text(definition)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.tertiary))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if !isRemovable(name) {
                        Text(L(.tableDesignPrimaryKeyKept))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.tertiary))
                    } else if dropped.wrappedValue.contains(name) {
                        Text(L(.tableDesignWillDrop))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.status(.danger))
                    }
                }
            }
        }
    }

    private func indexRow(_ draft: Binding<IndexDraft>) -> some View {
        HStack(spacing: Spacing.xs) {
            TextField(L(.tableDesignIndexName), text: draft.name)
                .textFieldStyle(.roundedBorder).font(Theme.font(.monoSmall)).frame(width: 150)
            TextField(L(.tableDesignIndexColumns), text: draft.columns)
                .textFieldStyle(.roundedBorder).font(Theme.font(.monoSmall)).frame(width: 170)
            Toggle(L(.tableDesignIndexUnique), isOn: draft.isUnique)
                .font(Theme.font(.caption))
            TextField(L(.tableDesignIndexWhere), text: draft.whereClause)
                .textFieldStyle(.roundedBorder).font(Theme.font(.monoSmall))
            Button {
                newIndexes.removeAll { $0.id == draft.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func foreignKeyRow(_ draft: Binding<ForeignKeyDraft>) -> some View {
        HStack(spacing: Spacing.xs) {
            TextField(L(.tableDesignConstraintName), text: draft.name)
                .textFieldStyle(.roundedBorder).font(Theme.font(.monoSmall)).frame(width: 130)
            TextField(L(.tableDesignForeignKeyColumns), text: draft.columns)
                .textFieldStyle(.roundedBorder).font(Theme.font(.monoSmall)).frame(width: 120)
            Image(systemName: "arrow.right").font(Theme.font(.caption)).foregroundStyle(Theme.text(.tertiary))
            TextField(L(.tableDesignForeignKeyTable), text: draft.referencedTable)
                .textFieldStyle(.roundedBorder).font(Theme.font(.monoSmall)).frame(width: 130)
            TextField(L(.tableDesignForeignKeyColumns), text: draft.referencedColumns)
                .textFieldStyle(.roundedBorder).font(Theme.font(.monoSmall)).frame(width: 120)

            referentialActionMenu(title: L(.tableDesignOnDelete), selection: draft.onDelete)
            referentialActionMenu(title: L(.tableDesignOnUpdate), selection: draft.onUpdate)

            Button {
                newForeignKeys.removeAll { $0.id == draft.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func referentialActionMenu(
        title: String,
        selection: Binding<SQLGenerator.ReferentialAction?>
    ) -> some View {
        Menu(ForeignKeyDraft.labelKey(selection.wrappedValue)) {
            Button(L(.referentialActionNone)) { selection.wrappedValue = nil }
            ForEach(SQLGenerator.ReferentialAction.allCases, id: \.self) { action in
                Button(ForeignKeyDraft.labelKey(action)) { selection.wrappedValue = action }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(Theme.font(.caption))
        .help(title)
    }

    private func constraintRow(_ draft: Binding<TableConstraintDraft>) -> some View {
        HStack(spacing: Spacing.xs) {
            TextField(L(.tableDesignConstraintName), text: draft.name)
                .textFieldStyle(.roundedBorder).font(Theme.font(.monoSmall)).frame(width: 160)
            TextField(L(.tableDesignConstraintDefinition), text: draft.definition)
                .textFieldStyle(.roundedBorder).font(Theme.font(.monoSmall))
            Button {
                newConstraints.removeAll { $0.id == draft.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func kindLabel(_ kind: TableConstraintInfo.Kind) -> String {
        switch kind {
        case .primaryKey: return L(.constraintKindPrimaryKey)
        case .unique: return L(.constraintKindUnique)
        case .foreignKey: return L(.constraintKindForeignKey)
        case .check: return L(.constraintKindCheck)
        case .other: return L(.constraintKindOther)
        }
    }
}

/// 表设计提交的内容。
///
/// 用一个结构体而不是继续加闭包参数：列 + 索引 + 外键 + 约束四样一起提交，
/// 参数列表会一路膨胀到调用处看不懂。
struct TableDesignSubmission {
    var name: String
    var schema: String?
    var changeSet: TableDesignChangeSet
}
