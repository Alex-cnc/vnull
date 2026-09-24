import Foundation

/// 结果集内联编辑（FR-DATA-04）：把「界面上的改动」翻译成将要执行的 DML。
///
/// 这一层是**纯函数**：只算语句、不连库、不改任何东西。为什么这样切：
/// 需求要求「提交前**预览**将执行的 DML，确认后再提交」—— 预览与真正执行必须是**同一份语句**，
/// 那就只能有一个来源。若预览由界面拼、执行由另一处拼，两者迟早不一致（而这条不一致最坏的结果是
/// "我看到的是 UPDATE，跑的是 DELETE"）。
///
/// 四条设计要点（需求原文的验收口径）：
/// 1. **需主键才能定位行**：没有主键就**拒绝**生成 —— 用"整行所有列都相等"当条件看似聪明，
///    实际会一次改掉多行（`NULL` 比较、重复行、浮点精度都会咬人）；
/// 2. **区分 NULL 与空串**：`NULL` 与 `''` 是两种不同的值，写回时结果完全不同；
/// 3. **一批变更包在单个事务内**：由调用方用 `beginTransaction` / `commit` / `rollback` 包住
///    （`DatabaseService` 已提供这三个动作，这里只给"要执行哪几条"）；
/// 4. **失败整批回滚**：同上 —— 语句按序执行，任何一条抛错就回滚整批，不留半截结果。
public enum InlineEdit {

    /// 列的元信息（主键标记来自表结构，不靠猜）。
    public struct Column: Equatable, Sendable {
        public var name: String
        public var typeName: String
        public var isPrimaryKey: Bool
        public var isNullable: Bool

        public init(name: String, typeName: String, isPrimaryKey: Bool, isNullable: Bool) {
            self.name = name
            self.typeName = typeName
            self.isPrimaryKey = isPrimaryKey
            self.isNullable = isNullable
        }
    }

    /// 一个待写入的值。**`null` 与 `text("")` 是两回事**（设计要点 2）。
    public enum Value: Equatable, Sendable {
        case null
        case text(String)
        case number(String)
        case boolean(Bool)
    }

    /// 用户的改动。
    public enum Change: Equatable, Sendable {
        /// 改某行某列（`rowIndex` 是**结果集里**的行号，从 0 起）。
        case update(rowIndex: Int, column: String, value: Value)
        /// 新增一行（只给要写的列，其余交给数据库默认值）。
        case insert(values: [String: Value])
        /// 删除某行。
        case delete(rowIndex: Int)
    }

    /// 计划：要么能执行（`statements` 非空、`refusals` 为空），要么给出**可读的拒绝理由**。
    public struct Plan: Equatable, Sendable {
        public var statements: [String]
        public var refusals: [String]

        public init(statements: [String] = [], refusals: [String] = []) {
            self.statements = statements
            self.refusals = refusals
        }

        public var isApplicable: Bool { refusals.isEmpty && !statements.isEmpty }

        /// 预览文本（界面 / CLI 共用同一份）。
        public var preview: String {
            if !refusals.isEmpty {
                return refusals.map { "⚠️ " + $0 }.joined(separator: "\n")
            }
            return statements.map { $0 + ";" }.joined(separator: "\n")
        }
    }

    /// 生成 DML。
    ///
    /// - Parameters:
    ///   - columnNames: 结果集的列顺序（**必须显式传入**：靠全局状态存列顺序既不纯也不线程安全 ——
    ///     我第一版就是这么写的，当场改掉）。
    ///   - rows: 当前结果集（`update` / `delete` 用它取被定位行的主键值）。
    ///   - changes: 用户的改动；同一行多次改同一列时**以最后一次为准**。
    /// - Parameter language: 生成**给人看的拒绝理由**时用的语言。
    ///   默认中文（CLI 与既有调用点都是中文）；界面按当前语言传进来 —— 这些理由会原样显示在
    ///   预览弹窗里，固定中文会让英文界面上出现一段看不懂的话（R-45 的同一类问题）。
    public static func plan(
        table: String,
        schema: String? = nil,
        columnNames: [String],
        columns: [Column],
        rows: [[String?]],
        changes: [Change],
        dialect: SQLDialect,
        language: AppLanguage = .simplifiedChinese
    ) -> Plan {
        guard !changes.isEmpty else { return Plan() }

        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name.lowercased(), $0) })
        let primaryKeys = columns.filter(\.isPrimaryKey)
        let target = SQLGenerator.qualifiedName(table: table, schema: schema, dialect: dialect)

        // 设计要点 1：需要主键定位行。INSERT 不需要，但一旦有 update/delete 就必须有。
        let needsKey = changes.contains {
            switch $0 {
            case .update, .delete: return true
            case .insert: return false
            }
        }
        if needsKey && primaryKeys.isEmpty {
            return Plan(refusals: [
                LocalizedStrings.text(.inlineEditNoPrimaryKey, language: language),
                LocalizedStrings.text(.inlineEditNoPrimaryKeyWhy, language: language)
            ])
        }

        var statements: [String] = []
        var refusals: [String] = []

        // 同一行同一列的多次修改：以最后一次为准（按输入顺序覆盖）。
        var updates: [Int: [String: Value]] = [:]
        var deletes: [Int] = []
        var inserts: [[String: Value]] = []

        for change in changes {
            switch change {
            case .update(let rowIndex, let column, let value):
                guard let columnMeta = byName[column.lowercased()] else {
                    refusals.append("没有这一列：\(column)")
                    continue
                }
                if value == .null && !columnMeta.isNullable {
                    refusals.append("列 \(columnMeta.name) 不允许为空（NOT NULL），不能写成 NULL")
                    continue
                }
                updates[rowIndex, default: [:]][columnMeta.name] = value
            case .delete(let rowIndex):
                deletes.append(rowIndex)
            case .insert(let values):
                var typed: [String: Value] = [:]
                for (column, value) in values {
                    guard let columnMeta = byName[column.lowercased()] else {
                        refusals.append("没有这一列：\(column)")
                        continue
                    }
                    if value == .null && !columnMeta.isNullable {
                        refusals.append("列 \(columnMeta.name) 不允许为空（NOT NULL），不能写成 NULL")
                        continue
                    }
                    typed[columnMeta.name] = value
                }
                inserts.append(typed)
            }
        }

        if !refusals.isEmpty { return Plan(refusals: refusals) }

        // 更新：按行号升序，稳定
        for rowIndex in updates.keys.sorted() {
            guard let assignments = updates[rowIndex],
                  let whereClause = whereClause(
                      language: language,
                      rowIndex: rowIndex,
                      rows: rows,
                      columnNames: columnNames,
                      primaryKeys: primaryKeys,
                      dialect: dialect,
                      refusals: &refusals
                  ) else {
                continue
            }
            let setList = assignments.keys.sorted().map { name in
                "\(dialect.quoteIdentifier(name)) = \(render(assignments[name]!))"
            }
            statements.append("UPDATE \(target) SET \(setList.joined(separator: ", ")) WHERE \(whereClause)")
        }

        // 删除：按行号**降序**（同一批里若同时有更新与删除，先删后面的行不会影响前面行号的含义；
        // 条件是按主键拼的，其实不依赖行号，但降序能让"看预览时"的顺序与人翻列表的方向一致）
        for rowIndex in deletes.sorted(by: >) {
            guard let whereClause = whereClause(
                language: language,
                rowIndex: rowIndex,
                rows: rows,
                columnNames: columnNames,
                primaryKeys: primaryKeys,
                dialect: dialect,
                refusals: &refusals
            ) else {
                continue
            }
            statements.append("DELETE FROM \(target) WHERE \(whereClause)")
        }

        // 新增：按输入顺序
        for values in inserts {
            let names = values.keys.sorted()
            let rendered = names.map { render(values[$0]!) }
            statements.append(
                "INSERT INTO \(target) (\(names.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")))"
                    + " VALUES (\(rendered.joined(separator: ", ")))"
            )
        }

        return refusals.isEmpty ? Plan(statements: statements) : Plan(refusals: refusals)
    }

    /// 按主键拼 WHERE。主键值为 NULL / 行不存在 / 结果集里没有该列时**拒绝这一行**（不猜、不退化）。
    private static func whereClause(
        language: AppLanguage,
        rowIndex: Int,
        rows: [[String?]],
        columnNames: [String],
        primaryKeys: [Column],
        dialect: SQLDialect,
        refusals: inout [String]
    ) -> String? {
        guard rows.indices.contains(rowIndex) else {
            refusals.append(LocalizedStrings.format(.inlineEditRowNotInResult, language: language, rowIndex + 1))
            return nil
        }
        let normalized = columnNames.map { $0.lowercased() }
        let row = rows[rowIndex]
        var parts: [String] = []
        for key in primaryKeys {
            guard let position = normalized.firstIndex(of: key.name.lowercased()) else {
                refusals.append(LocalizedStrings.format(.inlineEditMissingKeyColumn, language: language, key.name))
                return nil
            }
            guard row.indices.contains(position), let raw = row[position] else {
                refusals.append(LocalizedStrings.format(.inlineEditNullKeyValue, language: language, rowIndex + 1, key.name))
                return nil
            }
            parts.append("\(dialect.quoteIdentifier(key.name)) = \(literal(raw, typeName: key.typeName))")
        }
        return parts.joined(separator: " AND ")
    }

    /// 渲染一个字面量（**NULL 与空串不同**，设计要点 2）。
    public static func render(_ value: Value?) -> String {
        guard let value else { return "NULL" }
        switch value {
        case .null:
            return "NULL"
        case .number(let raw):
            return raw
        case .boolean(let flag):
            return flag ? "TRUE" : "FALSE"
        case .text(let raw):
            return "'" + raw.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }

    /// 从结果集里的**原始文本**与列类型渲染字面量（主键定位用）。
    public static func literal(_ raw: String, typeName: String) -> String {
        let lowered = typeName.lowercased()
        let numeric = ["int", "int2", "int4", "int8", "smallint", "integer", "bigint", "numeric", "decimal", "real", "double", "float", "serial", "bigserial"].contains { lowered.contains($0) }
        if numeric, Double(raw) != nil { return raw }
        return "'" + raw.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
