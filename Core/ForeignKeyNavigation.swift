import Foundation

/// 外键引用导航（FR-DATA-06）：由单元格 / 行跳到被引用表（或跳到引用我的表），并自动带入条件。
///
/// 需求点名的验收是"**存在外键元数据时才呈现入口；无可跳转目标时不显示**"——
/// 所以这一层的核心不是"能不能拼 SQL"，而是**"有没有目标"这个判定要准**：
/// 没有外键时给一个点了没反应的入口，比不给更糟。
///
/// 两个方向都要有（缺一个都会让用户困惑"为什么这边能跳、那边不能"）：
/// - **正向**：本表某列引用别人 → 跳到被引用表，按被引用列取值；
/// - **反向**：别人引用我 → 跳到引用方，按外键列取值（"这张订单被哪些明细引用"）。
public enum ForeignKeyNavigation {

    public enum Direction: String, CaseIterable, Sendable {
        case forward
        case reverse

        public var displayName: String {
            switch self {
            case .forward: return "跳到被引用表"
            case .reverse: return "跳到引用本表的行"
            }
        }
    }

    /// 一条外键边（从 `TableConstraintInfo` 的原始定义解析而来）。
    public struct Edge: Equatable, Sendable {
        public var constraintName: String?
        public var fromTable: String
        public var fromSchema: String?
        public var columns: [String]
        public var toTable: String
        public var toSchema: String?
        public var referencedColumns: [String]

        public init(
            constraintName: String? = nil,
            fromTable: String,
            fromSchema: String? = nil,
            columns: [String],
            toTable: String,
            toSchema: String? = nil,
            referencedColumns: [String]
        ) {
            self.constraintName = constraintName
            self.fromTable = fromTable
            self.fromSchema = fromSchema
            self.columns = columns
            self.toTable = toTable
            self.toSchema = toSchema
            self.referencedColumns = referencedColumns
        }
    }

    /// 一个可跳转的目标。
    public struct Option: Equatable, Sendable {
        public var direction: Direction
        public var localColumn: String
        public var targetTable: String
        public var targetSchema: String?
        public var targetColumn: String
        public var constraintName: String?

        public init(
            direction: Direction,
            localColumn: String,
            targetTable: String,
            targetSchema: String?,
            targetColumn: String,
            constraintName: String?
        ) {
            self.direction = direction
            self.localColumn = localColumn
            self.targetTable = targetTable
            self.targetSchema = targetSchema
            self.targetColumn = targetColumn
            self.constraintName = constraintName
        }

        /// 菜单项文案：`跳到被引用表：public.orders（id）`。
        public var title: String {
            let target = targetSchema.map { "\($0).\(targetTable)" } ?? targetTable
            return "\(direction.displayName)：\(target)（\(targetColumn)）"
        }
    }

    // MARK: 解析

    /// 从约束行解析外键。`rows` 的取法：`(constraintName, kind, definition)` ——
    /// 与 `dialect.tableConstraintsQuery` 的输出一致（kind 为 `f` 的才是外键）。
    ///
    /// 解析失败**返回 nil 而不是猜**：把一条 CHECK 约束当成外键会生成跳转到不存在列的语句。
    public static func parseEdge(
        constraintName: String?,
        kind: String,
        definition: String,
        table: String,
        schema: String?,
        defaultSchema: String? = nil
    ) -> Edge? {
        guard kind.lowercased().hasPrefix("f") else { return nil }
        let text = definition.replacingOccurrences(of: "\n", with: " ")
        guard let foreignRange = text.range(of: "FOREIGN KEY", options: .caseInsensitive) else { return nil }
        guard let referencesRange = text.range(of: "REFERENCES", options: .caseInsensitive) else { return nil }
        guard foreignRange.upperBound < referencesRange.lowerBound else { return nil }

        let localPart = String(text[foreignRange.upperBound..<referencesRange.lowerBound])
        let targetPart = String(text[referencesRange.upperBound...])
        guard let localColumns = parenthesized(localPart), !localColumns.isEmpty else { return nil }
        guard let target = parseTarget(targetPart) else { return nil }
        guard target.columns.count == localColumns.count else { return nil }

        return Edge(
            constraintName: constraintName,
            fromTable: table,
            fromSchema: schema,
            columns: localColumns,
            toTable: target.table,
            toSchema: target.schema ?? defaultSchema,
            referencedColumns: target.columns
        )
    }

    /// `(a, b)` → `["a", "b"]`（去引号、去空白；没有括号返回 nil）。
    static func parenthesized(_ text: String) -> [String]? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else {
            return nil
        }
        let inner = text[text.index(after: open)..<close]
        return inner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    /// `public.orders(id)` / `orders (id)` / `"My Schema"."T"(id)` → 目标表与列。
    static func parseTarget(_ text: String) -> (schema: String?, table: String, columns: [String])? {
        guard let open = text.firstIndex(of: "(") else { return nil }
        let namePart = String(text[text.startIndex..<open])
        guard let columns = parenthesized(String(text[open...])), !columns.isEmpty else { return nil }

        let components = namePart
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        guard let table = components.last else { return nil }
        let schema = components.count >= 2 ? components[components.count - 2] : nil
        return (schema, table, columns)
    }

    // MARK: 可跳转目标

    /// 某表某列的所有可跳转目标（正向 + 反向）。**顺序确定**：正向在前，再按目标表名排序。
    public static func options(
        table: String,
        column: String,
        edges: [Edge],
        schema: String? = nil
    ) -> [Option] {
        func matches(_ name: String, _ candidate: String) -> Bool {
            name.caseInsensitiveCompare(candidate) == .orderedSame
        }
        var forward: [Option] = []
        var reverse: [Option] = []

        for edge in edges {
            if matches(edge.fromTable, table), (schema == nil || edge.fromSchema == nil || matches(edge.fromSchema!, schema!)) {
                for (position, localColumn) in edge.columns.enumerated()
                where matches(localColumn, column) && position < edge.referencedColumns.count {
                    forward.append(Option(
                        direction: .forward,
                        localColumn: localColumn,
                        targetTable: edge.toTable,
                        targetSchema: edge.toSchema,
                        targetColumn: edge.referencedColumns[position],
                        constraintName: edge.constraintName
                    ))
                }
            }
            if matches(edge.toTable, table), (schema == nil || edge.toSchema == nil || matches(edge.toSchema!, schema!)) {
                for (position, referenced) in edge.referencedColumns.enumerated()
                where matches(referenced, column) && position < edge.columns.count {
                    reverse.append(Option(
                        direction: .reverse,
                        localColumn: column,
                        targetTable: edge.fromTable,
                        targetSchema: edge.fromSchema,
                        targetColumn: edge.columns[position],
                        constraintName: edge.constraintName
                    ))
                }
            }
        }

        let sortedForward = forward.sorted { $0.title < $1.title }
        let sortedReverse = reverse.sorted { $0.title < $1.title }
        return sortedForward + sortedReverse
    }

    /// 需求原文的验收点：**没有可跳转目标时不呈现入口**。
    public static func hasOption(table: String, column: String, edges: [Edge], schema: String? = nil) -> Bool {
        !options(table: table, column: column, edges: edges, schema: schema).isEmpty
    }

    // MARK: 生成跳转查询

    /// 生成跳转用的查询：带 `LIMIT`（跳过去看的是"这一行的引用对象"，不是整表导出）。
    public static func query(
        option: Option,
        value: String,
        typeName: String = "text",
        limit: Int = 200,
        dialect: any SQLDialect
    ) -> String {
        let target = SQLGenerator.qualifiedName(
            table: option.targetTable,
            schema: option.targetSchema,
            dialect: dialect
        )
        let literal = InlineEdit.literal(value, typeName: typeName)
        return "SELECT * FROM \(target) WHERE \(dialect.quoteIdentifier(option.targetColumn)) = \(literal) LIMIT \(max(1, limit));"
    }
}
