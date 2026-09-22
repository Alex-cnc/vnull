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
            // 标识符是否加引号由生成器决定，大小写不敏感地判重更贴近服务端行为。
            let key = columnName.lowercased()
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
