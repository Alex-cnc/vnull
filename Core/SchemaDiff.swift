import Foundation

/// Schema 对比与同步（FR-DDL-04）：对比两个库 / 两个连接的结构差异，并生成同步脚本。
///
/// 三条纪律：
/// 1. **复用既有生成器，不另写 DDL**：单表的列级变更用 `TableDesignChangeSet.columnChanges`
///    （它已按列名匹配、把改名表达成"删 + 加"），建表用 `SQLGenerator.createTable`。
///    再造一套 DDL 生成器，两处迟早写出不同的引号 / 主键写法。
/// 2. **破坏性变更默认不生成**：删列 / 删表在同步里是"我确定目标库那份数据不要了"才做的事，
///    必须显式开 `allowDrop`。默认脚本只做加法与修改，并把被跳过的破坏性变更**如实列出来**。
/// 3. **方向明确**：`left` 是**期望**的结构，`right` 是**要改**的目标库；脚本把 right 改成 left 的形状。
public enum SchemaDiff {}

// MARK: - 快照

/// 一张表的结构快照（可序列化 —— 两个库常常不在同一次调用里，快照要能落到文件再比）。
public struct TableSnapshot: Codable, Equatable, Sendable {
    public var schema: String?
    public var name: String
    public var columns: [TableColumnDefinition]

    public init(schema: String?, name: String, columns: [TableColumnDefinition]) {
        self.schema = schema
        self.name = name
        self.columns = columns
    }

    /// 限定名（比较用的键）：`schema.name`，schema 为空时就是表名。
    public var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }
}

/// 一个库 / 连接的结构快照。
public struct SchemaSnapshot: Codable, Equatable, Sendable {
    public var label: String
    public var tables: [TableSnapshot]

    public init(label: String, tables: [TableSnapshot]) {
        self.label = label
        self.tables = tables
    }

    public func table(named qualifiedName: String) -> TableSnapshot? {
        tables.first { $0.qualifiedName.caseInsensitiveCompare(qualifiedName) == .orderedSame }
    }
}

// MARK: - 差异

/// 一处表级差异。
public struct TableDiff: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 只在期望结构里有 → 目标库缺这张表（同步脚本会 `CREATE TABLE`）。
        case missingInTarget
        /// 只在目标库里有 → 期望结构里没有（同步脚本默认**不动它**，要删得开 `allowDrop`）。
        case extraInTarget
        /// 两边都有，但结构不同。
        case changed
    }

    public var table: TableSnapshot
    public var kind: Kind
    /// `changed` 时的列级变更（复用 FR-DDL-03 的判定）。
    public var columnChanges: [TableDesign.ColumnChange]

    public init(
        table: TableSnapshot,
        kind: Kind,
        columnChanges: [TableDesign.ColumnChange] = []
    ) {
        self.table = table
        self.kind = kind
        self.columnChanges = columnChanges
    }

    public var summary: String {
        switch kind {
        case .missingInTarget: return "目标库缺少这张表"
        case .extraInTarget: return "目标库多出这张表"
        case .changed: return "\(columnChanges.count) 处列级差异"
        }
    }
}

/// 同步计划。
public struct SchemaSyncPlan: Equatable, Sendable {
    /// 两个方向都会列出差异（便于人工核对）。
    public var diffs: [TableDiff]
    /// 要发到目标库的语句（按安全顺序：建表 → 改列；破坏性变更默认不含）。
    public var statements: [String]
    /// 因破坏性被跳过的变更（如实列出来，别让人以为"没有差异"）。
    public var skippedDestructive: [String]
    public var allowsDrop: Bool

    public init(
        diffs: [TableDiff] = [],
        statements: [String] = [],
        skippedDestructive: [String] = [],
        allowsDrop: Bool = false
    ) {
        self.diffs = diffs
        self.statements = statements
        self.skippedDestructive = skippedDestructive
        self.allowsDrop = allowsDrop
    }

    public var isIdentical: Bool { diffs.isEmpty }
}

public enum SchemaDiffer {

    /// 比较两个快照。表按限定名匹配（**大小写不敏感**：同一个库在不同平台上大小写写法可能不同）。
    /// 顺序确定：先按限定名升序。
    public static func compare(left: SchemaSnapshot, right: SchemaSnapshot) -> [TableDiff] {
        var diffs: [TableDiff] = []
        let rightByName = Dictionary(
            right.tables.map { ($0.qualifiedName.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let leftByName = Dictionary(
            left.tables.map { ($0.qualifiedName.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for table in left.tables.sorted(by: { $0.qualifiedName < $1.qualifiedName }) {
            guard let counterpart = rightByName[table.qualifiedName.lowercased()] else {
                diffs.append(TableDiff(table: table, kind: .missingInTarget))
                continue
            }
            guard !TableDesign.sameContent(table.columns, counterpart.columns) else { continue }
            // 把**目标库**当原始、**期望**当编辑后 —— 于是变更方向就是"目标 → 期望"。
            let changes = TableDesign.columnChanges(
                original: counterpart.columns,
                edited: table.columns
            )
            diffs.append(TableDiff(table: table, kind: .changed, columnChanges: changes))
        }

        for table in right.tables.sorted(by: { $0.qualifiedName < $1.qualifiedName })
        where leftByName[table.qualifiedName.lowercased()] == nil {
            diffs.append(TableDiff(table: table, kind: .extraInTarget))
        }

        return diffs
    }

    /// 生成把 `right`（目标库）改成 `left`（期望结构）形状的语句。
    ///
    /// - Parameter allowDrop: 是否允许破坏性变更（删列 / 删表）。为 `false` 时**不生成**这些语句，
    ///   但把它们记进 `skippedDestructive`。
    public static func plan(
        left: SchemaSnapshot,
        right: SchemaSnapshot,
        allowDrop: Bool = false,
        dialect: any SQLDialect
    ) -> SchemaSyncPlan {
        let diffs = compare(left: left, right: right)
        var statements: [String] = []
        var skipped: [String] = []

        // 先把缺的表建出来（后面的改列语句可能依赖它）
        for diff in diffs where diff.kind == .missingInTarget {
            statements.append(
                SQLGenerator.createTable(
                    table: diff.table.name,
                    columns: diff.table.columns,
                    schema: diff.table.schema,
                    dialect: dialect
                )
            )
        }

        for diff in diffs {
            switch diff.kind {
            case .extraInTarget:
                let target = qualifiedName(diff.table, dialect: dialect)
                if allowDrop {
                    statements.append("DROP TABLE \(target);")
                } else {
                    skipped.append("目标库多出的表 \(diff.table.qualifiedName) 不会被删除（未开 allowDrop）")
                }
            case .changed:
                guard let counterpart = right.table(named: diff.table.qualifiedName) else { continue }

                // 不开 allowDrop 时，把"目标库多出的列"**补回编辑集**：
                // 生成器于是不会产出 drop 语句（而不是我自己去过滤它生成的语句 ——
                // 那样就会与生成器口径分叉，早晚出现"预览说不删、执行却删了"）。
                // 不开 allowDrop 时，两件事都要做（否则"破坏性"只是嘴上说说）：
                //  · **目标库多出的列**补回编辑集 → 生成器自然不产出 DROP COLUMN；
                //  · **改类型**把编辑集里的类型换回目标库的原始类型 → 生成器自然不产出 ALTER TYPE。
                //    改类型同样可能丢数据（`TableDesign.ColumnChange.isDestructive` 就是这么定义的），
                //    所以它必须和删列一样受 allowDrop 约束。
                let expected: [TableColumnDefinition]
                if allowDrop {
                    expected = diff.table.columns
                } else {
                    expected = diff.table.columns.map { column in
                        guard let original = counterpart.columns.first(where: { $0.name == column.name }) else {
                            return column
                        }
                        var kept = column
                        kept.typeName = original.typeName
                        return kept
                    }
                }
                let keptExtra = allowDrop
                    ? []
                    : counterpart.columns.filter { column in
                        !expected.contains { $0.name == column.name }
                    }
                let edited = expected + keptExtra

                for change in diff.columnChanges where change.isDestructive && !allowDrop {
                    skipped.append("\(diff.table.qualifiedName)：\(describe(change))（破坏性，未开 allowDrop）")
                }

                let changeSet = TableDesignChangeSet(
                    originalColumns: counterpart.columns,
                    editedColumns: edited
                )
                statements.append(
                    contentsOf: TableDesignChangeSet.statements(
                        for: changeSet,
                        table: diff.table.name,
                        schema: diff.table.schema,
                        dialect: dialect
                    )
                )
            case .missingInTarget:
                continue
            }
        }

        return SchemaSyncPlan(
            diffs: diffs,
            statements: statements,
            skippedDestructive: skipped,
            allowsDrop: allowDrop
        )
    }

    /// 把列级变更写成一句人话（`TableDesign.ColumnChange` 只给语义，没有文案属性；
    /// 这里给 CLI / 日志用的中文说明，与界面文案各司其职）。
    public static func describe(_ change: TableDesign.ColumnChange) -> String {
        switch change {
        case .add(let column): return "新增列 \(column.name) \(column.typeName)"
        case .drop(let name): return "删除列 \(name)"
        case .changeType(let name, let type): return "列 \(name) 改类型为 \(type)"
        case .setNotNull(let name): return "列 \(name) 设为 NOT NULL"
        case .dropNotNull(let name): return "列 \(name) 改为可空"
        case .setDefault(let name, let value): return "列 \(name) 设默认值 \(value)"
        case .dropDefault(let name): return "列 \(name) 去掉默认值"
        }
    }

    private static func qualifiedName(_ table: TableSnapshot, dialect: any SQLDialect) -> String {
        SQLGenerator.qualifiedName(table: table.name, schema: table.schema, dialect: dialect)
    }
}
