import Foundation

/// 对象树节点上可执行的动作（FR-META-14）。
///
/// 设计原则与整个客户端一致：**菜单只生成 SQL 放进编辑器，不直接执行**。
/// 破坏性动作（清空 / 删除）同样只生成语句 —— 真正执行时还会被 Safe Mode（FR-EXEC-16）再拦一次，
/// 两道关卡各自独立，不互相替代。
public enum ObjectTreeAction: String, CaseIterable, Sendable {
    /// 浏览前 N 行（FR-DATA-01）。
    case browseRows
    /// 生成 `SELECT` 模板（按已加载的列）。
    case selectTemplate
    /// 生成 `INSERT` 模板（按已加载的列）。
    case insertTemplate
    /// 复制带 schema 的限定名（复制到剪贴板，不进编辑器）。
    case copyQualifiedName
    /// 复制列名（列节点专用）。
    case copyColumnName
    /// 查看 DDL：表按已加载的列拼装等价建表语句（FR-META-13 的表部分）。
    case viewDDL
    /// 生成 `TRUNCATE TABLE`（不执行）。
    case truncateTable
    /// 生成 `DROP TABLE IF EXISTS`（不执行）。
    case dropTable

    /// 该动作产出的内容是否要放进编辑器（`false` = 复制到剪贴板）。
    public var producesSQL: Bool {
        switch self {
        case .copyQualifiedName, .copyColumnName: return false
        default: return true
        }
    }

    /// 破坏性动作：界面需要显著提示，且执行时会再被 Safe Mode 拦一次。
    public var isDestructive: Bool {
        self == .truncateTable || self == .dropTable
    }
}

/// 动作的输入：只取节点里与生成语句相关的那几项。
///
/// 刻意不直接吃 `DatabaseObject`：这样 Core 的判定与视图解耦，
/// 单测里构造目标不必先把整棵树搭出来。
public struct ObjectTreeTarget: Equatable, Sendable {
    public var kind: DatabaseObject.Kind
    public var name: String
    public var schema: String?
    /// 已加载的列（表 / 视图）；为空表示尚未加载。
    public var columns: [ColumnMeta]

    public init(
        kind: DatabaseObject.Kind,
        name: String,
        schema: String? = nil,
        columns: [ColumnMeta] = []
    ) {
        self.kind = kind
        self.name = name
        self.schema = schema
        self.columns = columns
    }

    public init(object: DatabaseObject, columns: [ColumnMeta] = []) {
        self.init(kind: object.kind, name: object.name, schema: object.schema, columns: columns)
    }
}

/// 对象树动作 → SQL / 复制文本（FR-META-14、FR-DATA-01、FR-META-13 表部分）。
public enum ObjectTreeActions {

    /// 「浏览前 N 行」的默认行数（与需求一致）。
    public static let defaultBrowseLimit = 200

    /// 该动作对该类节点是否可用 —— 界面据此决定菜单项的呈现与禁用。
    public static func isAvailable(_ action: ObjectTreeAction, for kind: DatabaseObject.Kind) -> Bool {
        switch action {
        case .browseRows, .selectTemplate, .copyQualifiedName:
            return kind == .table || kind == .view
        case .insertTemplate, .viewDDL, .truncateTable, .dropTable:
            return kind == .table
        case .copyColumnName:
            return kind == .column
        }
    }

    /// 生成要放进编辑器的语句；`nil` = 该动作不适用于此节点，或所需信息不足。
    ///
    /// 需要列的动作（`insertTemplate` / `viewDDL`）在列未加载时返回 `nil`，
    /// 由界面先加载列再调用 —— 不猜列，宁可先禁用菜单项。
    public static func sql(
        for action: ObjectTreeAction,
        target: ObjectTreeTarget,
        dialect: any SQLDialect,
        browseLimit: Int = ObjectTreeActions.defaultBrowseLimit
    ) -> String? {
        guard isAvailable(action, for: target.kind) else { return nil }
        guard PrivilegeProbe.isValidIdentifier(target.name) else { return nil }
        if let schema = target.schema, !schema.isEmpty, !PrivilegeProbe.isValidIdentifier(schema) {
            return nil
        }

        switch action {
        case .browseRows:
            return SQLGenerator.selectRows(
                table: target.name,
                schema: target.schema,
                limit: browseLimit,
                offset: 0,
                dialect: dialect
            )

        case .selectTemplate:
            return SQLGenerator.selectTemplate(
                table: target.name,
                columns: target.columns.map(\.name),
                schema: target.schema,
                dialect: dialect
            )

        case .insertTemplate:
            guard !target.columns.isEmpty else { return nil }
            return SQLGenerator.insertTemplate(
                table: target.name,
                columns: target.columns.map(\.name),
                schema: target.schema,
                dialect: dialect
            )

        case .viewDDL:
            guard !target.columns.isEmpty else { return nil }
            return SQLGenerator.createTableDDL(
                table: target.name,
                columns: target.columns,
                schema: target.schema,
                dialect: dialect
            )

        case .truncateTable:
            return SQLGenerator.truncateTable(table: target.name, schema: target.schema, dialect: dialect)

        case .dropTable:
            return SQLGenerator.dropTable(table: target.name, schema: target.schema, dialect: dialect)

        case .copyQualifiedName, .copyColumnName:
            return nil
        }
    }

    /// 复制类动作的文本内容；非复制类返回 `nil`。
    ///
    /// 限定名走方言引用（`"schema"."table"`）—— 直接粘进 SQL 一定不会因大小写或保留字出错。
    public static func copiedText(
        for action: ObjectTreeAction,
        target: ObjectTreeTarget,
        dialect: any SQLDialect
    ) -> String? {
        switch action {
        case .copyQualifiedName:
            guard isAvailable(action, for: target.kind) else { return nil }
            guard PrivilegeProbe.isValidIdentifier(target.name) else { return nil }
            return SQLGenerator.qualifiedName(table: target.name, schema: target.schema, dialect: dialect)
        case .copyColumnName:
            guard isAvailable(action, for: target.kind) else { return nil }
            guard PrivilegeProbe.isValidIdentifier(target.name) else { return nil }
            return target.name
        default:
            return nil
        }
    }
}

/// 把 `listColumnsQuery` 的结果解析成列定义（FR-META-13 / FR-META-14）。
///
/// `information_schema.columns` 返回 `column_name` / `data_type` / `is_nullable` / `column_default`，
/// 这里只取前三项：可空性决定生成的 DDL 要不要带 `NOT NULL` —— 少了它，导出的建表语句会
/// 悄悄把 NOT NULL 约束丢掉。
public enum ColumnSpecParser {

    public static func columns(from result: QueryResult) -> [ColumnMeta] {
        let index = LockMonitor.columnIndexMap(result.columns)

        return result.rows.enumerated().compactMap { position, row -> ColumnMeta? in
            guard let name = LockMonitor.value(row, keys: ["column_name", "name", "field"], index: index)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return nil }

            let typeName = LockMonitor.value(row, keys: ["data_type", "type"], index: index)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nullableText = LockMonitor.value(row, keys: ["is_nullable", "nullable"], index: index)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()

            return ColumnMeta(
                id: position,
                name: name,
                typeName: (typeName?.isEmpty ?? true) ? "text" : typeName!,
                isNullable: nullableText != "NO"
            )
        }
    }
}
