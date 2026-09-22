import Foundation

/// 下方面板里一条日志（Problem / Output 两个页签共用）。
public struct TabLogEntry: Identifiable, Equatable, Sendable {

    public enum Severity: String, Equatable, Sendable {
        case info
        case warning
        case error
    }

    public let id: UUID
    public let timestamp: Date
    public let severity: Severity
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        severity: Severity,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.message = message
    }
}

/// 日志追加规则（纯函数，便于单测）。
///
/// 为什么要单独抽出来：`QueryTab` 里有 70 多处直接给 `statusMessage` / `errorMessage` /
/// `syntaxCheckMessage` 赋值，逐个改成"顺便写日志"既啰嗦又必漏。改成在模型层用 `didSet`
/// 拦截（一处覆盖全部）之后，这里就是那段逻辑的**可测核心**：
/// 去空白、跳过空串、去重相邻重复、超上限丢最旧的。
public enum TabLog {

    /// 单个面板保留的最大条数。终端那种滚动输出不在这里，这是给人看的日志。
    public static let defaultLimit = 500

    public static func appended(
        _ entries: [TabLogEntry],
        message: String,
        severity: TabLogEntry.Severity,
        at timestamp: Date = Date(),
        limit: Int = TabLog.defaultLimit
    ) -> [TabLogEntry] {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }

        // 相邻重复不重复记：执行过程中同一条状态常被反复写入。
        if let last = entries.last, last.message == trimmed, last.severity == severity {
            return entries
        }

        var result = entries
        result.append(TabLogEntry(timestamp: timestamp, severity: severity, message: trimmed))
        if limit > 0, result.count > limit {
            result.removeFirst(result.count - limit)
        }
        return result
    }

    /// 清空规则（界面上的「清空」按钮与重新执行前用）。
    public static func cleared() -> [TabLogEntry] { [] }
}
