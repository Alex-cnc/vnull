import Foundation

/// 结果行收集器：把「收多少行、什么时候算截断」变成可单测的策略（R-33）。
///
/// 为什么单独抽出来：这段逻辑原来内联在驱动的取行循环里
/// （`if let maxRows = options.maxRows, rows.count >= maxRows { break }`），
/// 既没法单测，也**不记录截断事实** —— 于是界面与归档都不知道自己看到的不是全部。
///
/// 语义（有意的取舍）：
///   · 上限为 N 时最多接受 N 行；若第 N+1 行真的到达，说明**确实被截断**，
///     置 `isTruncated` 并让调用方停止拉取；
///   · 结果恰好 N 行时 `isTruncated == false` —— 宁可多拉一行来区分
///     「正好这么多」与「还有更多」，也不要给用户一个含糊的 10000 行。
public struct ResultCollector {
    public let maxRows: Int?
    public private(set) var rows: [[String?]] = []
    public private(set) var isTruncated = false

    public init(maxRows: Int?) {
        self.maxRows = maxRows
    }

    /// 收到一行。返回 `false` 表示已达上限、调用方应停止拉取。
    @discardableResult
    public mutating func append(_ row: [String?]) -> Bool {
        if let maxRows, maxRows >= 0, rows.count >= maxRows {
            isTruncated = true
            return false
        }
        rows.append(row)
        return true
    }

    public var rowCount: Int { rows.count }

    /// 按上限构造结果对象（截断事实随行一起交给上层）。
    public func makeResult(
        columns: [ColumnMeta],
        affectedRows: Int? = nil,
        executionTime: TimeInterval = 0,
        notice: String? = nil
    ) -> QueryResult {
        QueryResult(
            columns: columns,
            rows: rows,
            affectedRows: affectedRows,
            executionTime: executionTime,
            notice: notice,
            isTruncated: isTruncated,
            truncationLimit: isTruncated ? maxRows : nil
        )
    }
}
