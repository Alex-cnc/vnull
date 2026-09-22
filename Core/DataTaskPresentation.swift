import Foundation

/// 数据任务面板用到的**纯逻辑**（FR-AI-05、FR-AI-06）。
///
/// 放在 Core 而不是视图里，理由与 `AgentAuditPresentation` 相同：
/// 「调度判定 → 界面状态」「执行记录 → 展示文本」这些是纯函数，
/// 抽出来才能在 `DoyahCoreTests` 里有单测；视图里只剩摆放。
public enum DataTaskPresentation {

    /// 界面上的调度状态（`ScheduleDecision` 的界面化投影）。
    public enum ScheduleStatus: String, Equatable, Sendable, CaseIterable {
        case notScheduled
        case disabled
        case waiting
        case due
        case missed
    }

    // MARK: - 调度判定 → 界面状态

    public static func status(for decision: ScheduleDecision) -> ScheduleStatus {
        switch decision {
        case .notScheduled: return .notScheduled
        case .disabled: return .disabled
        case .waiting: return .waiting
        case .due: return .due
        case .missed: return .missed
        }
    }

    /// 计划执行时刻（等待 / 到点 / 错过三态才有）。
    public static func plannedAt(_ decision: ScheduleDecision) -> Date? {
        switch decision {
        case .waiting(let until): return until
        case .due(let plannedAt): return plannedAt
        case .missed(let plannedAt, _): return plannedAt
        case .notScheduled, .disabled: return nil
        }
    }

    /// 错过窗口「晚了约 N 分钟」里的 N；不是错过态时为 `nil`。
    ///
    /// 不足 1 分钟按 1 分钟算：显示「晚了约 0 分钟」会让人以为没晚。
    public static func overdueMinutes(_ decision: ScheduleDecision) -> Int? {
        guard case .missed(_, let overdueBy) = decision else { return nil }
        return max(1, Int(overdueBy / 60))
    }

    /// 下一次计划执行时刻的展示文本；没有下一次（未排期 / 停用 / 一次性已过）时为 `nil`。
    public static func nextRunText(
        for task: DataTaskDefinition,
        lastRun: Date?,
        now: Date = Date()
    ) -> String? {
        guard let next = TaskScheduler.nextRun(for: task, after: now, lastRun: lastRun) else { return nil }
        return AgentAuditPresentation.timestampText(next)
    }

    // MARK: - 执行记录

    /// 某任务最近一次执行记录（列表按时间追加，取最后一条）。
    public static func latestRun(for taskID: UUID, in records: [TaskRunRecord]) -> TaskRunRecord? {
        records.last { $0.taskID == taskID }
    }

    /// 耗时文本；未结束 / 极短都给一个可读结果。
    public static func durationText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(minutes) min \(remainder) s"
    }

    /// 写入行数文本。
    public static func rowsText(_ rows: Int?) -> String {
        guard let rows else { return "—" }
        return "\(rows)"
    }

    // MARK: - 列表筛选

    /// 任务列表筛选：关键词（名称 / specs / 源表 / 目标表） + 只看启用。
    public static func filter(
        _ tasks: [DataTaskDefinition],
        query: String = "",
        onlyEnabled: Bool = false
    ) -> [DataTaskDefinition] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tasks.filter { task in
            if onlyEnabled, !task.isEnabled { return false }
            guard !keyword.isEmpty else { return true }
            let haystack = [
                task.name,
                task.specs,
                task.source.table,
                task.target.table
            ].joined(separator: "\n").lowercased()
            return haystack.contains(keyword)
        }
    }

    // MARK: - 写操作定性（界面提示用）

    /// 该任务的写入是否具有破坏性（覆盖会清空目标表、更新插入会改写既有行）。
    ///
    /// 界面据此在保存前就把话说明白：这两种模式不是「只是多写几行」。
    public static func isDestructiveWrite(_ task: DataTaskDefinition) -> Bool {
        switch task.target.writeMode {
        case .append: return false
        case .overwrite, .upsert: return true
        }
    }

    // MARK: - 时间字段（编辑器输入 / 展示共用）

    /// 编辑器里要求的时间格式。
    public static let dateFormat = "yyyy-MM-dd HH:mm"

    /// 人类可读的**输入格式**说明（界面提示用，不随语言变化）。
    public static func dateText(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }

    /// 解析编辑器里的时间文本。
    ///
    /// 宽容一点：带时区的 ISO8601（模型常这么给）与不带时区的本地写法都认，
    /// 「没有时区就按本地时间理解」——总比静默判成无效好。
    public static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: trimmed) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", dateFormat, "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}
