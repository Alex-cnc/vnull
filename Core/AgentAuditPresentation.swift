import Foundation

// MARK: - 导出格式（NFR-AI-03）

/// 审计记录的导出格式。
///
/// 只有两种，且都**必须**走 `AgentAuditLog` 已有的导出路径 ——
/// 那两条路径在返回前都过了 `AgentAudit.redacted`，另写一份导出就等于绕开脱敏。
public enum AgentAuditExportFormat: String, CaseIterable, Sendable {
    case json
    case csv

    public var fileExtension: String { rawValue }

    /// 默认文件名（不含扩展名）。
    public var defaultBaseName: String { "agent-audit" }
}

public extension AgentAuditLog {

    /// 按格式导出（**复用**已有的 JSON / CSV 两条脱敏路径，不另写导出逻辑）。
    ///
    /// CSV 带 UTF-8 BOM：审计里的连接名 / 语句常含中文，带 BOM 才能被 Excel 直接识别；
    /// JSON 是给程序与人工复核读的，不加 BOM。
    func export(_ format: AgentAuditExportFormat) throws -> Data {
        switch format {
        case .json:
            return try exportJSON()
        case .csv:
            return Data(("\u{FEFF}" + (try exportCSV())).utf8)
        }
    }
}

// MARK: - 过滤（面板用）

/// 审计记录的面板过滤条件（FR-AI-09）。
///
/// 纯值类型 + 纯函数：过滤是**本地行为**，不碰文件也不碰网络，因此可以直接单测。
public struct AgentAuditFilter: Equatable, Sendable {
    /// 只看某个结果状态；`nil` = 全部。
    public var outcome: AgentActionRecord.Outcome?
    /// 只看某个连接；`nil` / 空串 = 全部。
    public var connectionName: String?
    /// 关键词：大小写不敏感，匹配语句 / 附注 / 连接 / 库 / 模型。
    public var searchText: String

    public init(
        outcome: AgentActionRecord.Outcome? = nil,
        connectionName: String? = nil,
        searchText: String = ""
    ) {
        self.outcome = outcome
        self.connectionName = connectionName
        self.searchText = searchText
    }

    /// 不加任何条件。
    public static let all = AgentAuditFilter()

    /// 是否加过条件（界面用它决定要不要显示「已过滤」）。
    public var isActive: Bool {
        if outcome != nil { return true }
        if let connectionName, !connectionName.isEmpty { return true }
        return !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 归一化后的连接条件：空白视为「不限」。
    private var normalizedConnection: String? {
        guard let connectionName else { return nil }
        let trimmed = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func matches(_ record: AgentActionRecord) -> Bool {
        if let outcome, record.outcome != outcome { return false }

        if let connection = normalizedConnection, record.connectionName != connection { return false }

        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !keyword.isEmpty {
            let haystack = [
                record.sql,
                record.detail ?? "",
                record.connectionName ?? "",
                record.database ?? "",
                record.model ?? ""
            ].joined(separator: "\n").lowercased()
            if !haystack.contains(keyword) { return false }
        }
        return true
    }

    public func apply(to records: [AgentActionRecord]) -> [AgentActionRecord] {
        records.filter(matches)
    }

    /// 出现过的连接名（去重、升序），供筛选菜单用。
    public static func connectionNames(in records: [AgentActionRecord]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for name in records.compactMap(\.connectionName) where !name.isEmpty {
            if seen.insert(name).inserted { names.append(name) }
        }
        return names.sorted()
    }
}

// MARK: - 展示格式（面板用）

/// 审计面板的展示格式（FR-AI-09：时间 / 连接 / 语句（或动作摘要）/ 模型 / 结果状态）。
///
/// 放在 Core 而不是视图里：这些是**纯字符串变换**，抽出来才有单测可写
/// （视图里的格式化逻辑没法在 `PostgresClientCoreTests` 里覆盖）。
public enum AgentAuditPresentation {

    /// 空值占位符（不是文案，故不走文案表）。
    public static let placeholder = "—"

    /// 语句摘要：把换行与连续空白压成单个空格，超长截断。
    ///
    /// 列表里一行一条记录，原样的多行 SQL 会把行高撑坏；截断后仍保留
    /// 够分辨「这是哪条语句」的信息量（新页签 / 详情里可看全文）。
    public static func statementSummary(_ sql: String, limit: Int = 80) -> String {
        let flattened = sql
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard limit > 0, flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// 时间文本（固定格式，不随语言变化；用 `en_US_POSIX` 避免地区差异）。
    public static func timestampText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    public static func connectionText(_ record: AgentActionRecord) -> String {
        guard let name = record.connectionName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return placeholder }
        // 库名与连接名一起显示：同名连接的不同库在审计里必须能分开。
        guard let database = record.database?.trimmingCharacters(in: .whitespacesAndNewlines),
              !database.isEmpty
        else { return name }
        return "\(name) · \(database)"
    }

    public static func modelText(_ record: AgentActionRecord) -> String {
        guard let model = record.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return placeholder }
        return model
    }

    /// 风险点说明（NFR-AI-12 联动：让「为什么被拦」在界面上看得见）。
    public static func findingsText(_ record: AgentActionRecord) -> String {
        guard !record.findings.isEmpty else { return "" }
        return record.findings.map(\.message).joined(separator: "；")
    }

    /// 是否高危（破坏性）：面板据此把行标红。
    public static func isHighRisk(_ record: AgentActionRecord) -> Bool {
        record.risk >= .destructive
    }
}
