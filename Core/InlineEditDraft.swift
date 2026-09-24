import Foundation

/// 结果集内联编辑的**待提交草稿**（FR-DATA-04 的界面状态那一层）。
///
/// 为什么不把这份状态直接放在视图的 `@State` 里：需求要求「提交前预览、确认后才写库」，
/// 于是"还没提交的改动"必须先攒在一个地方，而这份攒法有四条口径需要被钉住 ——
/// 放在 Core 里它们才能被单测覆盖（视图状态测不了）：
///
/// 1. **同一格改两次以最后一次为准** —— 与 `InlineEdit.plan` 的口径一致；
/// 2. **一行要么是"改了"、要么是"删了"，不会同时是两者** —— 否则会生成一条
///    注定影响 0 行的 `UPDATE`（行已经被 `DELETE` 掉了），预览里却看不出来；
/// 3. **交给 `InlineEdit.plan` 的 `changes` 顺序稳定** —— 预览与执行是同一份语句，
///    顺序每次不一样会让"我看到的"和"跑过的"在顺序上对不上；
/// 4. **行号不是行的身份**：结果集可以翻页 / 排序 / 筛选，同一个行号在不同时刻指向
///    **另一行**。所以每一处改动都记住"改动发生时那一行的**原始值**"，
///    提交时按那份快照定位（拿主键）—— 否则"第 1 页改一格、翻到第 2 页再改一格"
///    会把改动写到别的行上，而且从预览里看不出来。
public struct InlineEditDraft: Equatable, Sendable {

    /// 改动发生时那一行的原始值（结果集行号 → 整行）。见口径 4。
    private var snapshots: [Int: [String?]] = [:]
    /// 已改的单元格：结果集行号 → 列名 → 新值。
    private var updates: [Int: [String: InlineEdit.Value]] = [:]
    /// 标记删除的行（结果集行号）。
    private var deletions: Set<Int> = []
    /// 追加的新行（按用户添加顺序）。
    private var inserts: [[String: InlineEdit.Value]] = []

    public init() {}

    // MARK: - 判定

    /// 没有任何待提交的改动。
    public var isEmpty: Bool {
        updates.isEmpty && deletions.isEmpty && inserts.isEmpty
    }

    /// 用户可见的改动处数（改了几格 + 删了几行 + 加了几行）。
    public var changeCount: Int {
        updates.values.reduce(0) { $0 + $1.count } + deletions.count + inserts.count
    }

    /// 有改动的**已有行**（改值或标记删除）。
    public var touchedRows: Set<Int> {
        updates.keys.reduce(into: deletions) { $0.insert($1) }
    }

    public func isDeleted(row: Int) -> Bool { deletions.contains(row) }

    /// 这一格当前待提交的值（没有改动时为 nil —— 调用方应显示原值）。
    public func pendingValue(row: Int, column: String) -> InlineEdit.Value? {
        updates[row]?[column]
    }

    /// 这一行上待提交的改值（列名 → 值）。
    public func pendingCells(row: Int) -> [String: InlineEdit.Value] {
        updates[row] ?? [:]
    }

    public var insertedRows: [[String: InlineEdit.Value]] { inserts }

    // MARK: - 改动

    /// 记下一格的改动。`rowValues` 是**改动发生时**这一行的原始值（见口径 4）。
    ///
    /// 若这一行此前被标记删除：**撤销删除标记**（用户既然改了它就说明不是要删它）——
    /// 见类型注释里的口径 2。
    public mutating func setValue(
        _ value: InlineEdit.Value,
        row: Int,
        column: String,
        rowValues: [String?]
    ) {
        deletions.remove(row)
        snapshots[row] = rowValues
        updates[row, default: [:]][column] = value
    }

    /// 标记删除某行；该行上已有的改值一并作废（那一行已经不存在了）。
    public mutating func markDeleted(row: Int, rowValues: [String?]) {
        updates[row] = nil
        snapshots[row] = rowValues
        deletions.insert(row)
    }

    public mutating func unmarkDeleted(row: Int) {
        deletions.remove(row)
        snapshots[row] = nil
    }

    /// 追加一行（`values` 里没给的列交给数据库默认值）。
    public mutating func appendInsert(_ values: [String: InlineEdit.Value]) {
        inserts.append(values)
    }

    /// 撤掉某一行的新增（`index` 是**新增行内部**的下标，不是结果集行号）。
    public mutating func removeInsert(at index: Int) {
        guard inserts.indices.contains(index) else { return }
        inserts.remove(at: index)
    }

    /// 放弃全部改动（退出编辑态、或结果表的显示内容变了时调用）。
    public mutating func discard() {
        snapshots.removeAll()
        updates.removeAll()
        deletions.removeAll()
        inserts.removeAll()
    }

    // MARK: - 交给 Core

    /// 提交给 `InlineEdit.plan` 的输入：**行**与**改动**。
    ///
    /// `rows` 只含被改动 / 被删除的那几行，且用的是改动发生时的快照（不是"此刻界面上这个行号"
    /// —— 那可能已经是另一行了）；`changes` 里的 `rowIndex` 已重映射到这份数组上。
    /// 追加行不需要行号，原样带过去。
    public func planInput() -> (rows: [[String?]], changes: [InlineEdit.Change]) {
        var rows: [[String?]] = []
        var changes: [InlineEdit.Change] = []
        /// 行号 → 在 `rows` 里的下标（只登记真的会用到快照的行）。
        var positions: [Int: Int] = [:]

        func position(for row: Int) -> Int? {
            if let existing = positions[row] { return existing }
            guard let snapshot = snapshots[row] else { return nil }
            let index = rows.count
            rows.append(snapshot)
            positions[row] = index
            return index
        }

        for row in updates.keys.sorted() {
            guard let cells = updates[row], let index = position(for: row) else { continue }
            for column in cells.keys.sorted() {
                changes.append(.update(rowIndex: index, column: column, value: cells[column]!))
            }
        }
        for row in deletions.sorted() {
            guard let index = position(for: row) else { continue }
            changes.append(.delete(rowIndex: index))
        }
        for values in inserts {
            changes.append(.insert(values: values))
        }
        return (rows, changes)
    }

    /// 只取改动序列（不含行）。测试与"预览里数一数"用得上；
    /// 真正提交必须用 `planInput()` —— 它连行一起给。
    public func changes() -> [InlineEdit.Change] {
        planInput().changes
    }
}

extension InlineEdit.Value {

    /// 界面上显示这个值的文本（NULL 与空串在界面上必须是两种东西）。
    public var displayText: String {
        switch self {
        case .null: return "NULL"
        case .text(let raw), .number(let raw): return raw
        case .boolean(let flag): return flag ? "TRUE" : "FALSE"
        }
    }

    /// 把界面里的一格文本按**列类型**变成类型化的值（单元格编辑用）。
    ///
    /// 口径与命令行一致：`NULL`（不分大小写）是空值，**空文本是空串** —— 两者必须能区分。
    public static func parsed(_ raw: String, typeName: String) -> InlineEdit.Value {
        parsedForInsert(raw, typeName: typeName) ?? .text(raw)
    }

    /// 追加行时的解析：**空文本 = 不写这一列**（交给数据库默认值），其余同上。
    ///
    /// `''`（一对单引号）表示**写一个空串** —— 空文本既然表示"不写"，就需要另一种写法
    /// 表达"写空串"，否则空串在追加行里根本写不出来（而空串与 NULL 的区别正是本项的设计要点）。
    public static func parsedForInsert(_ raw: String, typeName: String) -> InlineEdit.Value? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.uppercased() == "NULL" { return .null }
        if trimmed == "''" { return .text("") }

        let lowered = typeName.lowercased()
        if lowered.contains("bool") {
            let flag = trimmed.lowercased()
            if flag == "true" || flag == "t" || flag == "1" || flag == "yes" { return .boolean(true) }
            if flag == "false" || flag == "f" || flag == "0" || flag == "no" { return .boolean(false) }
            return .text(raw)
        }
        let numeric = ["int", "numeric", "decimal", "real", "double", "float", "serial"].contains {
            lowered.contains($0)
        }
        if numeric, Double(trimmed) != nil { return .number(trimmed) }
        return .text(raw)
    }
}
