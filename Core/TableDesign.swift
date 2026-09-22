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
