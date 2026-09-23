import Foundation

/// 表设计里的一列（FR-DDL-03）。
///
/// 比 `ColumnMeta` 多出 `defaultValue` 与 `isPrimaryKey` —— 后两者是「新建表」的刚需，
/// 而 `ColumnMeta` 只描述**已存在**的表（列名 + 类型 + 可空），所以另起一个输入模型，
/// 不去污染元数据那个类型。
public struct TableColumnDefinition: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var typeName: String
    public var isNullable: Bool
    /// 默认值。按**原样 SQL 表达式**处理（`0` / `now()` / `'active'` 都直接写进去），
    /// 因为不同方言的字面量写法差别大，由使用者负责；界面上有实时 DDL 预览，
    /// 看到什么就执行什么（NFR-AI-05 的同一原则）。
    public var defaultValue: String
    public var isPrimaryKey: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        typeName: String = "",
        isNullable: Bool = true,
        defaultValue: String = "",
        isPrimaryKey: Bool = false
    ) {
        self.id = id
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
    }
}

/// 表设计的本地校验（纯函数，便于单测）。
///
/// 只做**本地能判定的**：命名合法性、列非空、列名重复、类型缺失。
/// 类型/默认值是否被服务端接受一律以执行结果为准 —— 不假装能提前知道。
public enum TableDesign {

    public enum Issue: Equatable, Sendable {
        case tableNameEmpty
        case tableNameInvalid(String)
        case noColumns
        /// 第几列（1 基）还没有名字。
        case columnNameEmpty(Int)
        case columnNameInvalid(String)
        case columnNameDuplicate(String)
        /// 该列还没有类型（参数是列名）。
        case columnTypeEmpty(String)

        /// 文案键（与 `Core/Localization.swift` 对应；界面按当前语言取）。
        public var textKey: LKey {
            switch self {
            case .tableNameEmpty: return .tableIssueNameEmpty
            case .tableNameInvalid: return .tableIssueNameInvalid
            case .noColumns: return .tableIssueNoColumns
            case .columnNameEmpty: return .tableIssueColumnNameEmpty
            case .columnNameInvalid: return .tableIssueColumnNameInvalid
            case .columnNameDuplicate: return .tableIssueColumnNameDuplicate
            case .columnTypeEmpty: return .tableIssueColumnTypeEmpty
            }
        }

        /// 文案里的占位参数；不需要时为 `nil`。
        public var argument: CVarArg? {
            switch self {
            case .tableNameInvalid(let name): return name
            case .columnNameEmpty(let position): return position
            case .columnNameInvalid(let name): return name
            case .columnNameDuplicate(let name): return name
            case .columnTypeEmpty(let name): return name
            case .tableNameEmpty, .noColumns: return nil
            }
        }
    }

    /// 对已有表的一次列级变更（FR-DDL-03）。
    public enum ColumnChange: Equatable, Sendable {
        case add(TableColumnDefinition)
        case drop(name: String)
        case changeType(name: String, to: String)
        case setNotNull(name: String)
        case dropNotNull(name: String)
        case setDefault(name: String, value: String)
        case dropDefault(name: String)

        /// 这次变更会不会动到已有数据 —— 界面据此给醒目提示（删列 / 改类型都可能丢数据）。
        public var isDestructive: Bool {
            switch self {
            case .drop, .changeType: return true
            case .add, .setNotNull, .dropNotNull, .setDefault, .dropDefault: return false
            }
        }
    }

    /// 比较两个类型写法是否等价。
    ///
    /// 服务端回给的是 `character varying(50)`，而人可能填 `varchar(50)`；不归一化就会把
    /// "没改过的列"也算成改类型，凭空生成 ALTER。
    static func normalizedType(_ typeName: String) -> String {
        typeName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// 由「原始结构」与「编辑后的结构」算出要执行的列级变更。
    ///
    /// 按列名匹配（**大小写敏感**，与加引号的生成器一致）：改名在结果里表现为
    /// 「删一列 + 加一列」，界面会把它标成破坏性变更让人看清楚 —— 不假装支持 rename。
    public static func columnChanges(
        original: [TableColumnDefinition],
        edited: [TableColumnDefinition]
    ) -> [ColumnChange] {
        var originalByName: [String: TableColumnDefinition] = [:]
        for column in original { originalByName[column.name] = column }
        let editedNames = Set(edited.map(\.name))

        var changes: [ColumnChange] = []

        // 1) 被删掉的列（原始里有、编辑后没有）
        for column in original where !editedNames.contains(column.name) {
            changes.append(.drop(name: column.name))
        }

        // 2) 新增与修改，按编辑后的顺序输出，保证预览稳定
        for column in edited {
            guard let before = originalByName[column.name] else {
                changes.append(.add(column))
                continue
            }

            let newType = normalizedType(column.typeName)
            if newType != normalizedType(before.typeName) {
                changes.append(.changeType(name: column.name, to: column.typeName.trimmingCharacters(in: .whitespaces)))
            }

            if before.isNullable != column.isNullable {
                changes.append(column.isNullable ? .dropNotNull(name: column.name) : .setNotNull(name: column.name))
            }

            let newDefault = column.defaultValue.trimmingCharacters(in: .whitespaces)
            let oldDefault = before.defaultValue.trimmingCharacters(in: .whitespaces)
            if newDefault != oldDefault {
                changes.append(
                    newDefault.isEmpty
                        ? .dropDefault(name: column.name)
                        : .setDefault(name: column.name, value: newDefault)
                )
            }
        }

        return changes
    }

    /// 校验表名与列定义。返回空数组表示本地检查通过。
    /// 两组列在**内容**上是否一致（忽略身份 id）。
    public static func sameContent(_ lhs: [TableColumnDefinition], _ rhs: [TableColumnDefinition]) -> Bool {
        lhs.map(contentKey) == rhs.map(contentKey)
    }

    /// 列的内容指纹：名称 / 类型 / 可空 / 默认值 / 主键 —— 身份 id 不在其中。
    public static func contentKey(_ column: TableColumnDefinition) -> String {
        [
            column.name,
            column.typeName,
            column.isNullable ? "null" : "notnull",
            column.defaultValue,
            column.isPrimaryKey ? "pk" : ""
        ].joined(separator: "|")
    }

    public static func validate(tableName: String, columns: [TableColumnDefinition]) -> [Issue] {
        var issues: [Issue] = []

        let name = tableName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            issues.append(.tableNameEmpty)
        } else if !PrivilegeProbe.isValidIdentifier(name) {
            issues.append(.tableNameInvalid(name))
        }

        if columns.isEmpty {
            issues.append(.noColumns)
        }

        var seen: Set<String> = []
        for (index, column) in columns.enumerated() {
            let columnName = column.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if columnName.isEmpty {
                issues.append(.columnNameEmpty(index + 1))
                continue
            }
            if !PrivilegeProbe.isValidIdentifier(columnName) {
                issues.append(.columnNameInvalid(columnName))
            }
            // 生成器**始终给标识符加引号**，所以大小写是有意义的：`Name` 与 `name` 是两列。
            // （早先按大小写不敏感判重，会把这种合法设计误判成重复。）
            let key = columnName
            if seen.contains(key) {
                issues.append(.columnNameDuplicate(columnName))
            } else {
                seen.insert(key)
            }

            if column.typeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.columnTypeEmpty(columnName))
            }
        }

        return issues
    }
}

// MARK: - 索引与约束（FR-DDL-03 扩写）

/// 已存在的索引。`definition` 是服务端给的现成 `CREATE INDEX …`，只读展示用。
public struct TableIndexInfo: Equatable, Sendable, Identifiable {
    public var name: String
    public var definition: String

    public var id: String { name }

    public init(name: String, definition: String) {
        self.name = name
        self.definition = definition
    }
}

/// 已存在的约束。
public struct TableConstraintInfo: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case primaryKey = "p"
        case unique = "u"
        case foreignKey = "f"
        case check = "c"
        case other = "?"

        /// 主键不能在这里删：它是表的身份，删除要走显式的 `DROP CONSTRAINT`，
        /// 而界面把它标出来比让用户误点更安全 —— 因此用 `isRemovable` 表达，而不是隐藏。
        public var isRemovable: Bool { self != .primaryKey }
    }

    public var name: String
    public var kind: Kind
    public var definition: String

    public var id: String { name }

    public init(name: String, kind: Kind, definition: String) {
        self.name = name
        self.kind = kind
        self.definition = definition
    }
}

/// 用户新加的一条约束（UNIQUE / CHECK 等）：`definition` 是约束定义文本。
public struct TableConstraintDraft: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var definition: String

    public init(id: UUID = UUID(), name: String = "", definition: String = "") {
        self.id = id
        self.name = name
        self.definition = definition
    }
}

/// 表设计的完整变更集：列 + 索引 + 外键 + 约束。
///
/// 为什么把四样放进一个类型：它们在**执行顺序上有依赖**（新索引可能建在新列上、
/// 删约束要给改主键让路），顺序必须由一处决定 —— 散在界面里必然出现"某个组合就是跑不过"。
public struct TableDesignChangeSet: Equatable, Sendable {
    public var originalColumns: [TableColumnDefinition]
    public var editedColumns: [TableColumnDefinition]
    public var newIndexes: [SQLGenerator.IndexDefinition]
    public var droppedIndexes: [String]
    public var newForeignKeys: [SQLGenerator.ForeignKeyDefinition]
    public var newConstraints: [TableConstraintDraft]
    public var droppedConstraints: [String]

    /// 其余参数都有默认值，因此 `TableDesignChangeSet(originalColumns:editedColumns:)` 直接可用 ——
    /// **不要**再写一个同签名的便捷构造：那会与自身重载匹配，变成无限递归（本轮实测崩过一次）。
    public init(
        originalColumns: [TableColumnDefinition] = [],
        editedColumns: [TableColumnDefinition] = [],
        newIndexes: [SQLGenerator.IndexDefinition] = [],
        droppedIndexes: [String] = [],
        newForeignKeys: [SQLGenerator.ForeignKeyDefinition] = [],
        newConstraints: [TableConstraintDraft] = [],
        droppedConstraints: [String] = []
    ) {
        self.originalColumns = originalColumns
        self.editedColumns = editedColumns
        self.newIndexes = newIndexes
        self.droppedIndexes = droppedIndexes
        self.newForeignKeys = newForeignKeys
        self.newConstraints = newConstraints
        self.droppedConstraints = droppedConstraints
    }

    /// 是否**没有任何改动**。
    ///
    /// 注意这个属性此前写反了：名字叫 `isEmpty`，逻辑却是"有改动"（`!=` 起头）——
    /// 只是当时没人调用它，所以一直没暴露。本轮补的测试把它抓了出来，现在语义与名字一致。
    /// 按**内容**比较而不是 `==`：`TableColumnDefinition` 带身份 `id`，
    /// 用它比较会把"重新加载 / 重建同一份定义"误判成"改过"。
    public var isEmpty: Bool {
        TableDesign.sameContent(originalColumns, editedColumns)
            && newIndexes.isEmpty
            && droppedIndexes.isEmpty
            && newForeignKeys.isEmpty
            && newConstraints.isEmpty
            && droppedConstraints.isEmpty
    }

    /// 有改动 —— 界面用它决定提交按钮是否可用（比 `!isEmpty` 读起来清楚）。
    public var hasChanges: Bool { !isEmpty }

    /// 生成要执行的语句，**顺序固定**：
    /// ① 删约束（旧主键 / 唯一 / 外键先让路）→ ② 删索引 → ③ 列变更 → ④ 新索引 → ⑤ 新外键 → ⑥ 新约束。
    ///
    /// 顺序理由：先腾地方（删除），再改结构（列），最后建立新依赖（索引 / 外键 / 约束）；
    /// 反过来做就会出现"在还不存在的列上建索引"或"旧主键挡着新主键"。
    /// 任一条生成失败（输入非法）时**整批返回空** —— 不生成残缺的执行计划。
    public static func statements(
        for changeSet: TableDesignChangeSet,
        table: String,
        schema: String?,
        dialect: any SQLDialect
    ) -> [String] {
        var statements: [String] = []

        for name in changeSet.droppedConstraints {
            guard let sql = SQLGenerator.dropConstraint(name: name, table: table, schema: schema, dialect: dialect) else {
                return []
            }
            statements.append(sql)
        }

        for name in changeSet.droppedIndexes {
            guard let sql = SQLGenerator.dropIndex(name: name, schema: schema, dialect: dialect) else { return [] }
            statements.append(sql)
        }

        let columnChanges = TableDesign.columnChanges(
            original: changeSet.originalColumns,
            edited: changeSet.editedColumns
        )
        statements.append(contentsOf: SQLGenerator.alterTableStatements(
            table: table,
            schema: schema,
            changes: columnChanges,
            dialect: dialect
        ))

        for index in changeSet.newIndexes {
            guard let sql = SQLGenerator.createIndex(index, dialect: dialect) else { return [] }
            statements.append(sql)
        }

        for foreignKey in changeSet.newForeignKeys {
            guard let sql = SQLGenerator.addForeignKey(foreignKey, dialect: dialect) else { return [] }
            statements.append(sql)
        }

        for constraint in changeSet.newConstraints {
            guard let sql = SQLGenerator.addConstraint(
                name: constraint.name,
                table: table,
                schema: schema,
                definition: constraint.definition,
                dialect: dialect
            ) else { return [] }
            statements.append(sql)
        }

        return statements
    }

    /// 解析索引查询结果（第 1 列名、第 2 列定义）。
    public static func indexes(from result: QueryResult) -> [TableIndexInfo] {
        result.rows.compactMap { row in
            guard let name = value(row, at: 0), !name.isEmpty else { return nil }
            return TableIndexInfo(name: name, definition: value(row, at: 1) ?? "")
        }
    }

    /// 解析约束查询结果（第 1 列名、第 2 列类型代码、第 3 列定义）。
    public static func constraints(from result: QueryResult) -> [TableConstraintInfo] {
        result.rows.compactMap { row in
            guard let name = value(row, at: 0), !name.isEmpty else { return nil }
            let rawKind = (value(row, at: 1) ?? "?").lowercased()
            return TableConstraintInfo(
                name: name,
                kind: TableConstraintInfo.Kind(rawValue: rawKind) ?? .other,
                definition: value(row, at: 2) ?? ""
            )
        }
    }

    private static func value(_ row: [String?], at index: Int) -> String? {
        guard row.indices.contains(index), let value = row[index], !value.isEmpty else { return nil }
        return value
    }
}
