import Foundation

/// 导入的列映射与批量语句生成（FR-IO-03）。
///
/// 分工：`DelimitedTextReader` 只负责"把文件读成表头 + 行"；这里负责
/// **每一列去哪儿**（映射）、**值怎么变成 SQL 字面量**（类型化转义），以及**分批**执行
/// （内存与文件大小无关）。
public enum TableImport {

    /// 目标列（来自表结构的精简形态）。
    public struct TargetColumn: Equatable, Sendable {
        public var name: String
        public var typeName: String
        public var isNullable: Bool

        public init(name: String, typeName: String, isNullable: Bool = true) {
            self.name = name
            self.typeName = typeName
            self.isNullable = isNullable
        }

        public init(_ column: TableColumnDefinition) {
            self.init(name: column.name, typeName: column.typeName, isNullable: column.isNullable)
        }
    }

    /// 一列的映射。`sourceIndex` 为 nil = **该目标列不导入**（用默认值 / NULL）。
    public struct ColumnMapping: Equatable, Sendable {
        public var targetName: String
        public var sourceIndex: Int?
        /// 该列在文件里的名字（报告用）。
        public var sourceName: String?

        public init(targetName: String, sourceIndex: Int?, sourceName: String? = nil) {
            self.targetName = targetName
            self.sourceIndex = sourceIndex
            self.sourceName = sourceName
        }
    }

    public struct Plan: Equatable, Sendable {
        public var table: String
        public var schema: String?
        public var mappings: [ColumnMapping]
        /// 每一列推断出的值类型（决定字面量怎么写）。
        public var valueTypes: [String: SQLParameters.ValueType]
        /// 文件里有、但目标表里没有的列 —— **要说出来**，而不是悄悄丢掉。
        public var unknownSourceColumns: [String]
        /// 目标表里必填、但文件里没有对应列的列 —— 继续导入通常一定失败，提前说。
        public var missingRequiredColumns: [String]
        /// 每批多少行（批量 INSERT 的规模）。
        public var batchSize: Int

        public var mappedColumns: [ColumnMapping] { mappings.filter { $0.sourceIndex != nil } }
        public var isEmpty: Bool { mappedColumns.isEmpty }
    }

    /// 默认批量：500 行一条 INSERT。够快，又不会把单条语句撑到难读。
    public static let defaultBatchSize = 500

    // MARK: - 映射与推断

    /// 文件的列是**怎么对上目标列**的。
    ///
    /// 为什么要两种：有表头的文件按名字对（列序变了也不怕）；**没有表头**的文件只能按位置对 ——
    /// 之前 `--no-header` 会生成一个空表头，于是"一列都映射不上"，功能等于不可用。
    /// 按位置是有风险的（列序错了数据就会串列），所以它只在用户**显式**说"这个文件没有表头"时才启用，
    /// 并且映射预览会把「文件第 N 列 → 目标第 M 列」逐条列出来给他核。
    public enum SourceLayout: String, Equatable, Sendable {
        /// 按列名匹配（默认）。
        case byName
        /// 按列序一一对应：文件第 1 列 → 目标第 1 列，以此类推。
        case byPosition
    }

    /// 生成列映射：**按名字**（大小写不敏感）或**按位置**（无表头文件）。
    public static func plan(
        table: String,
        schema: String? = nil,
        sourceHeader: [String],
        targetColumns: [TargetColumn],
        batchSize: Int = TableImport.defaultBatchSize,
        sourceLayout: SourceLayout = .byName
    ) -> Plan {
        switch sourceLayout {
        case .byName:
            return planByName(
                table: table,
                schema: schema,
                sourceHeader: sourceHeader,
                targetColumns: targetColumns,
                batchSize: batchSize
            )
        case .byPosition:
            return planByPosition(
                table: table,
                schema: schema,
                sourceHeader: sourceHeader,
                targetColumns: targetColumns,
                batchSize: batchSize
            )
        }
    }

    private static func planByName(
        table: String,
        schema: String?,
        sourceHeader: [String],
        targetColumns: [TargetColumn],
        batchSize: Int
    ) -> Plan {
        let normalizedHeader = sourceHeader.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        var mappings: [ColumnMapping] = []
        var usedSourceIndexes: Set<Int> = []

        for target in targetColumns {
            let key = target.name.lowercased()
            if let index = normalizedHeader.firstIndex(of: key) {
                mappings.append(ColumnMapping(targetName: target.name, sourceIndex: index, sourceName: sourceHeader[index]))
                usedSourceIndexes.insert(index)
            } else {
                // 目标列在文件里没有 → 不导入（走数据库默认值 / NULL）。
                mappings.append(ColumnMapping(targetName: target.name, sourceIndex: nil))
            }
        }

        let unknown = sourceHeader.enumerated()
            .filter { !usedSourceIndexes.contains($0.offset) }
            .map(\.element)

        let missingRequired = mappings
            .filter { $0.sourceIndex == nil }
            .compactMap { mapping -> String? in
                guard let target = targetColumns.first(where: { $0.name == mapping.targetName }) else { return nil }
                return target.isNullable ? nil : target.name
            }

        var types: [String: SQLParameters.ValueType] = [:]
        for mapping in mappings where mapping.sourceIndex != nil {
            let target = targetColumns.first { $0.name == mapping.targetName }
            types[mapping.targetName] = valueType(forTypeName: target?.typeName ?? "text")
        }

        return Plan(
            table: table,
            schema: schema,
            mappings: mappings,
            valueTypes: types,
            unknownSourceColumns: unknown,
            missingRequiredColumns: missingRequired,
            batchSize: max(1, batchSize)
        )
    }

    /// 按**列序**对：文件第 1 列 → 目标表第 1 列。
    ///
    /// 三处必须说清楚（否则用户会以为"按位置"和"按名字"一样安全）：
    /// - 文件比目标表**宽**：多出来的列进 `unknownSourceColumns`（会被忽略，但要点出来）；
    /// - 文件比目标表**窄**：目标表多出来的列不导入（走默认值 / NULL）；非空列会被列进
    ///   `missingRequiredColumns` —— 那种情况继续导入几乎一定失败，提前拦住比写坏一半好；
    /// - 逐个映射都带 `sourceName`（就是文件里的位置名，如 `column2`），映射预览里能逐条核。
    private static func planByPosition(
        table: String,
        schema: String?,
        sourceHeader: [String],
        targetColumns: [TargetColumn],
        batchSize: Int
    ) -> Plan {
        var mappings: [ColumnMapping] = []
        for (index, target) in targetColumns.enumerated() {
            if index < sourceHeader.count {
                mappings.append(
                    ColumnMapping(
                        targetName: target.name,
                        sourceIndex: index,
                        sourceName: sourceHeader[index]
                    )
                )
            } else {
                mappings.append(ColumnMapping(targetName: target.name, sourceIndex: nil))
            }
        }

        let unknown = sourceHeader.enumerated()
            .filter { $0.offset >= targetColumns.count }
            .map(\.element)

        let missingRequired = mappings
            .filter { $0.sourceIndex == nil }
            .compactMap { mapping -> String? in
                guard let target = targetColumns.first(where: { $0.name == mapping.targetName }) else { return nil }
                return target.isNullable ? nil : target.name
            }

        var types: [String: SQLParameters.ValueType] = [:]
        for mapping in mappings where mapping.sourceIndex != nil {
            let target = targetColumns.first { $0.name == mapping.targetName }
            types[mapping.targetName] = valueType(forTypeName: target?.typeName ?? "text")
        }

        return Plan(
            table: table,
            schema: schema,
            mappings: mappings,
            valueTypes: types,
            unknownSourceColumns: unknown,
            missingRequiredColumns: missingRequired,
            batchSize: max(1, batchSize)
        )
    }

    /// 类型名 → 字面量类型。与 `SyntheticSpecBuilder` 同一口径：**按完整类型名判定**，
    /// 不用 `contains`（`interval` 里也有 `int`）。
    public static func valueType(forTypeName raw: String) -> SQLParameters.ValueType {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let paren = text.firstIndex(of: "(") {
            text = String(text[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        switch text {
        case "int2", "int4", "int8", "smallint", "integer", "bigint", "serial", "bigserial",
             "numeric", "decimal", "real", "float4", "float8", "double precision", "money":
            return .number
        case "bool", "boolean":
            return .boolean
        default:
            // 日期 / 时间 / UUID 等一律当文本：加引号后数据库自己会转，
            // 而当数字写出去反而会把 `2026-09-23` 变成算式。
            return .text
        }
    }

    // MARK: - 语句生成

    /// 生成一批 `INSERT`（多行 VALUES）。
    ///
    /// - 值按目标列类型转义：number **不加引号**（否则 `= 42` 变 `= '42'`，索引失效）、
    ///   boolean → TRUE/FALSE、空值 → NULL。
    /// - 空串与 NULL 区分：CSV 里未加引号的空字段是 NULL，加了引号（`""`）是空字符串。
    public static func insertStatement(
        rows: [[String?]],
        plan: Plan,
        dialect: any SQLDialect = PostgresDialect()
    ) -> String? {
        let columns = plan.mappedColumns
        guard !columns.isEmpty, !rows.isEmpty else { return nil }

        let target = SQLGenerator.qualifiedName(table: plan.table, schema: plan.schema, dialect: dialect)
        let columnList = columns.map { dialect.quoteIdentifier($0.targetName) }.joined(separator: ", ")

        let valueRows = rows.map { row -> String in
            let values = columns.map { mapping -> String in
                let raw = mapping.sourceIndex.flatMap { index in
                    row.indices.contains(index) ? row[index] : nil
                }
                return literal(for: raw, type: plan.valueTypes[mapping.targetName] ?? .text)
            }
            return "(" + values.joined(separator: ", ") + ")"
        }

        return "INSERT INTO \(target) (\(columnList)) VALUES\n  " + valueRows.joined(separator: ",\n  ") + ";"
    }

    /// 单个值 → SQL 字面量。
    static func literal(for raw: String?, type: SQLParameters.ValueType) -> String {
        guard let raw else { return "NULL" }
        switch type {
        case .number:
            // 数字列收到非数字：**不加引号会变成语法错误**，加引号又会被数据库拒绝 ——
            // 这里回退成 NULL 并在报告里体现（由 `invalidNumberColumns` 提前拦），
            // 保证"不会把垃圾当数字写进去"。
            return SQLParameters.isNumericLiteral(raw) ? raw.trimmingCharacters(in: .whitespaces) : "NULL"
        case .boolean:
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "t", "1", "yes", "y": return "TRUE"
            case "false", "f", "0", "no", "n": return "FALSE"
            default: return "NULL"
            }
        case .null:
            return "NULL"
        case .text:
            return "'" + raw.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }

    /// 把行按批切开（内存与文件大小无关的关键）。
    /// 为 `COPY … FROM STDIN` 准备数据（FR-IO-03 的快路径）。
    ///
    /// 与 INSERT 路径的**关键区别**：这里**原样取值、不做字面量转义** —— text 格式由服务端
    /// 按列类型解析，转义交给 `CopyTextFormat`（只处理分隔符与反斜杠）。
    /// 因此"无效值"的行为也不同：INSERT 路径会把转不过去的值写成 NULL（并在预检里列出），
    /// 而 COPY 路径会被**服务端直接拒绝** —— 在大批量导入里，"要么全对要么报错"通常更受欢迎，
    /// 但这是个需要说清楚的差异，不能默默不同。
    ///
    /// 顺序与 `mappings` 里**有来源列**的那些一致（调用方传给 `copyFromText` 的列清单也按此过滤）。
    public static func copyRows(rows: [[String?]], plan: Plan) -> [[String?]] {
        let positions = plan.mappings.compactMap(\.sourceIndex)
        return rows.map { row in
            positions.map { index in row.indices.contains(index) ? row[index] : nil }
        }
    }

    public static func batches(_ rows: [[String?]], size: Int) -> [[[String?]]] {
        guard size > 0 else { return rows.isEmpty ? [] : [rows] }
        var result: [[[String?]]] = []
        var index = 0
        while index < rows.count {
            let end = min(index + size, rows.count)
            result.append(Array(rows[index..<end]))
            index = end
        }
        return result
    }

    /// 预检：数字 / 布尔列里出现无法转换的值时**提前列出**（含行号与列名）。
    ///
    /// 为什么要有它：`literal` 对坏值会退化成 NULL（安全但静默）。导入前先扫一遍，
    /// 把"第 37 行 amount 是 abc"这种话说出来，避免用户事后发现数据缺了。
    public static func invalidValues(
        rows: [[String?]],
        plan: Plan,
        limit: Int = 20
    ) -> [String] {
        var problems: [String] = []
        for (rowIndex, row) in rows.enumerated() {
            for mapping in plan.mappedColumns {
                guard let sourceIndex = mapping.sourceIndex,
                      row.indices.contains(sourceIndex),
                      let raw = row[sourceIndex]
                else { continue }
                let type = plan.valueTypes[mapping.targetName] ?? .text
                let problem: String?
                switch type {
                case .number:
                    problem = SQLParameters.isNumericLiteral(raw) ? nil : "不是数字"
                case .boolean:
                    let lowered = raw.trimmingCharacters(in: .whitespaces).lowercased()
                    problem = ["true", "t", "1", "yes", "y", "false", "f", "0", "no", "n"].contains(lowered)
                        ? nil : "不是布尔值"
                case .text, .null:
                    problem = nil
                }
                if let problem {
                    problems.append("第 \(rowIndex + 1) 行 \(mapping.targetName)：\(problem)（值「\(raw)」）")
                    if problems.count >= limit { return problems }
                }
            }
        }
        return problems
    }
}

// MARK: - 写入通道（COPY 快路径 / 批量 INSERT 回退）

/// 导入的写入通道。
///
/// 存在两个值而不是一个 `Bool`：因为"现在走的是哪条路"是用户**必须看到**的事实 ——
/// 同一份数据，COPY 与逐批 INSERT 的耗时差一个数量级，而两者的**错误行为也不同**
/// （COPY 在单条语句内原子、坏值整批被服务端拒绝；INSERT 会把转不过去的值写成 NULL）。
public enum ImportWriteMode: String, CaseIterable, Sendable {
    /// `COPY … FROM STDIN`（快路径）。
    case copy
    /// 批量 `INSERT`（回退路径）。
    case batchInsert
}

public extension TableImport {

    /// COPY 通道在当前连接上的可用性**与不可用的理由**。
    ///
    /// 为什么理由要由 Core 给：界面里"退回批量 INSERT"如果不是一条**带原因**的明确说明，
    /// 用户看到的就是"这个勾选框点不动" —— 那与静默降级没有区别（只是把静默挪到了界面上）。
    struct CopySupport: Equatable, Sendable {
        public var isAvailable: Bool
        /// 不可用时的可读理由（可用时为 `nil`）。
        public var reason: String?

        public init(isAvailable: Bool, reason: String? = nil) {
            self.isAvailable = isAvailable
            self.reason = reason
        }

        public static let available = CopySupport(isAvailable: true)
    }

    /// 按数据库类型判断 COPY 是否可用。
    ///
    /// 判据是"驱动有没有实现 `DatabaseService.copyFromText`"：PostgreSQL 实现了；
    /// GBase 8a 目前走 `NotImplementedDatabaseService`（其默认实现**抛「不支持」而不是
    /// 静默退回 INSERT**），所以在界面里就该把这条通道标成不可用并说明理由。
    static func copySupport(databaseType: DatabaseType) -> CopySupport {
        switch databaseType {
        case .postgresql:
            return .available
        case .gbase8a:
            return CopySupport(
                isAvailable: false,
                reason: "当前连接是 GBase 8a：驱动未实现 COPY FROM STDIN，本次导入将走批量 INSERT"
            )
        }
    }

    /// 默认选中的写入通道：能用 COPY 就用 COPY，否则退回批量 INSERT（并带上理由）。
    static func preferredWriteMode(databaseType: DatabaseType) -> (mode: ImportWriteMode, reason: String?) {
        let support = copySupport(databaseType: databaseType)
        return support.isAvailable ? (.copy, nil) : (.batchInsert, support.reason)
    }

    /// 渲染即将下发的 `COPY … FROM STDIN` 语句（**用于预览与安全检查**，不用于执行）。
    ///
    /// 为什么要单独渲染一份：真正下发 COPY 的是驱动（`copyFromText` 自己拼语句），
    /// 而"将要写哪张表、哪几列"必须让用户在执行前看到，也必须能被 `ExecutionSafety`
    /// 按同一套词法规则分类（COPY 属于数据变更）—— 否则这条快路径就成了唯一
    /// 绕过写语句确认与只读保护的入口。
    static func copyStatement(
        table: String,
        schema: String? = nil,
        columns: [String],
        dialect: any SQLDialect = PostgresDialect()
    ) -> String? {
        guard !columns.isEmpty else { return nil }
        let target = SQLGenerator.qualifiedName(table: table, schema: schema, dialect: dialect)
        let columnList = columns.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")
        return "COPY \(target) (\(columnList)) FROM STDIN"
    }
}
