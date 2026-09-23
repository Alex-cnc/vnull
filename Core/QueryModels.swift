import Foundation

public struct ColumnMeta: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public var name: String
    public var typeName: String
    public var isNullable: Bool

    public init(id: Int, name: String, typeName: String = "text", isNullable: Bool = true) {
        self.id = id
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
    }
}

public struct QueryResult: Identifiable, Sendable {
    public let id: UUID
    public var columns: [ColumnMeta]
    public var rows: [[String?]]
    public var affectedRows: Int?
    public var executionTime: TimeInterval
    public var notice: String?

    public init(
        id: UUID = UUID(),
        columns: [ColumnMeta] = [],
        rows: [[String?]] = [],
        affectedRows: Int? = nil,
        executionTime: TimeInterval = 0,
        notice: String? = nil
    ) {
        self.id = id
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.executionTime = executionTime
        self.notice = notice
    }

    public var rowCount: Int { rows.count }

    public var columnCount: Int { columns.count }
}

public struct QuerySummary: Sendable {
    public var statementCount: Int
    public var duration: TimeInterval
    public var affectedRows: Int?

    public init(statementCount: Int, duration: TimeInterval, affectedRows: Int? = nil) {
        self.statementCount = statementCount
        self.duration = duration
        self.affectedRows = affectedRows
    }
}

/// 执行事件流。
///
/// **影响行数只走一条通道**：`.resultSet(QueryResult.affectedRows)`。
/// 为什么写在这里（R-32，2026-09-23 评审）：原先 DML 同时发 `.resultSet(携带 affectedRows)`
/// 与 `.affectedRows` 两个事件，上层两条分支都累加 ⇒ **归档与任务历史里的行数系统性翻倍**，
/// 而归档是复盘与审计的依据 —— 数字翻倍比没有数字更糟。
/// 现在把「一条语句只报一次行数」变成**类型上的事实**：没有第二个通道可走。
public enum QueryEvent: Sendable {
    case started(statementIndex: Int)
    case resultSet(QueryResult)
    case notice(String)
    case finished(QuerySummary)
}

/// 影响行数累加器：**全工程唯一的计数入口**。
///
/// 存在的理由就是 R-32：计数若是散在调用方的 `switch` 里，多一条事件通道就会多算一次，
/// 而且没人能一眼看出"到底加了几次"。收成一个类型之后，行为可单测、可断言。
public struct AffectedRowsTally: Sendable {
    public private(set) var total = 0
    public private(set) var sawAny = false

    public init() {}

    /// 吸收一个事件。只有携带行数的事件会改变计数。
    public mutating func absorb(_ event: QueryEvent) {
        guard case .resultSet(let result) = event, let rows = result.affectedRows else { return }
        total += rows
        sawAny = true
    }

    /// 累计行数；**一条都没报过时为 `nil`**（而不是 0）——
    /// 「0 行受影响」与「这条语句不报行数」是两件事，归档里必须能区分。
    public var value: Int? { sawAny ? total : nil }
}

public struct QueryOptions: Sendable {
    public var maxRows: Int?
    public var statementTimeout: TimeInterval?
    public var fetchSize: Int

    public init(maxRows: Int? = nil, statementTimeout: TimeInterval? = nil, fetchSize: Int = 1_000) {
        self.maxRows = maxRows
        self.statementTimeout = statementTimeout
        self.fetchSize = fetchSize
    }

    public static let `default` = QueryOptions()
}

public struct DatabaseObject: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case server
        case database
        case schema
        case table
        case view
        case column
        case function
        case sequence
    }

    public let id: String
    public var name: String
    public var kind: Kind
    /// 次要信息，例如列的数据类型。
    public var detail: String?
    /// 节点所属数据库；表 / 列 / schema 节点据此决定使用哪条连接。
    public var database: String?
    /// 节点所属 schema；表 / 列节点使用。
    public var schema: String?
    public var children: [DatabaseObject]

    public init(
        id: String,
        name: String,
        kind: Kind,
        detail: String? = nil,
        database: String? = nil,
        schema: String? = nil,
        children: [DatabaseObject] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.detail = detail
        self.database = database
        self.schema = schema
        self.children = children
    }

    /// 是否应该在对象树里展示展开箭头。
    public var isExpandable: Bool {
        switch kind {
        case .server, .database, .schema, .table, .view:
            return true
        case .column, .function, .sequence:
            return false
        }
    }

    public var symbolName: String {
        switch kind {
        case .server:
            return "cylinder.split.1x2"
        case .database:
            return "cylinder"
        case .schema:
            return "square.stack.3d.up"
        case .table:
            return "tablecells"
        case .view:
            return "eye"
        case .column:
            return "text.alignleft"
        case .function:
            return "function"
        case .sequence:
            return "number"
        }
    }
}
