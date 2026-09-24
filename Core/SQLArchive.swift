import Foundation

/// 一条被自动归档的查询（FR-EDIT-31）。
///
/// 与内存里的查询历史（`AppState.queryHistory`，退出即清空）是**互补**关系：
/// 那份用于当前会话回看，这份落成 `.sql` 文件长期留存。
public struct SQLArchiveEntry: Equatable, Sendable {
    /// SQL 原文（尽量原样保存，便于直接拿去执行）。
    public var sql: String
    /// 首次执行时间（同一条 SQL 只保留最早与最近两个时间点）。
    public var firstExecutedAt: Date
    public var lastExecutedAt: Date
    /// 当天累计执行次数。
    public var runCount: Int
    /// 连接展示名（用于追溯"这条是在哪个库上跑的"）。
    public var connection: String
    public var database: String
    public var durationSeconds: Double?
    public var affectedRows: Int?
    public var succeeded: Bool
    /// 失败原因或补充说明。
    public var note: String?

    public init(
        sql: String,
        firstExecutedAt: Date,
        lastExecutedAt: Date,
        runCount: Int = 1,
        connection: String,
        database: String,
        durationSeconds: Double? = nil,
        affectedRows: Int? = nil,
        succeeded: Bool = true,
        note: String? = nil
    ) {
        self.sql = sql
        self.firstExecutedAt = firstExecutedAt
        self.lastExecutedAt = lastExecutedAt
        self.runCount = runCount
        self.connection = connection
        self.database = database
        self.durationSeconds = durationSeconds
        self.affectedRows = affectedRows
        self.succeeded = succeeded
        self.note = note
    }
}

/// 按天聚合的查询归档（FR-EDIT-31）。
///
/// 设计取舍：
/// - **按天一个文件**（`2026-09-23.sql`）：可读、可放进版本库、文件数量不爆炸；
///   每次执行一个文件会一夜之间堆出上千个文件。
/// - **同一条 SQL 只占一个条目**，重复执行只更新「执行次数 / 最近执行 / 耗时 / 结果」，
///   而不是把同一个查询抄 200 遍。
/// - **文件本身就是可执行的 `.sql`**：语句原样内联，注释掉的是元信息 ——
///   所以这份归档既能读，也能直接拿去跑。
/// - 身份判定用 `(规范化 SQL, 连接, 库)`：同一条 SQL 在不同库上执行是**不同**条目
///   （对 DBA 来说"这条在哪跑的"就是关键信息，不能合并掉）。
///
/// 全部是纯函数（渲染 / 解析 / 合并），文件 IO 交给 `SQLArchiveStore`。
public enum SQLArchive {

    /// 归档文件头（渲染时写下；也是"这是不是归档文件"的判据）。
    ///
    /// 为什么需要它：删除条目后当天文件可能只剩文件头（合法状态），
    /// 而"条目数为 0"同时也是"这文件不是归档"的表现 —— 没有这个判据就分不开，
    /// 于是删完一条记忆，索引会报一句"跳过 1 个文件（空 / 非归档格式）"，像出了故障。
    public static let headerPrefix = "-- Doyah Studio 查询归档"

    /// 这份文本是不是归档文件（**空归档也算**）。
    public static func isArchiveText(_ text: String) -> Bool {
        text.contains(headerPrefix)
    }

    static let startMarker = "-- ===== 条目开始 ====="
    static let endMarker = "-- ===== 条目结束 ====="

    // MARK: 文件命名

    /// 当天归档文件名：`2026-09-23.sql`。
    public static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date) + ".sql"
    }

    /// 把时间截到**整秒**。
    ///
    /// 落盘只精确到秒（人读的格式），如果内存里保留毫秒，`render → parse` 的往返就不等了、
    /// 每次读取都会被判定成"内容变了"而反复写盘。归档的时间精度到秒足够。
    static func truncatedToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    // MARK: 身份

    /// SQL 的规范化形式，仅用于**判定是不是同一条**（不改动保存的原文）。
    ///
    /// 只做保守归一：去首尾空白、行尾分号、把内部连续空白压成一个空格。
    /// **不改大小写** —— 大小写敏感的标识符改了就可能是另一条语句。
    public static func normalizedSQL(_ sql: String) -> String {
        let collapsed = sql
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        var result = collapsed
        while result.hasSuffix(";") {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    // MARK: 合并

    /// 把一次新的执行并入当天条目：同一条 SQL 只累计，不重复追加。
    public static func merged(
        _ entries: [SQLArchiveEntry],
        adding entry: SQLArchiveEntry
    ) -> [SQLArchiveEntry] {
        let newEntry = SQLArchiveEntry(
            sql: entry.sql,
            firstExecutedAt: truncatedToSecond(entry.firstExecutedAt),
            lastExecutedAt: truncatedToSecond(entry.lastExecutedAt),
            runCount: max(1, entry.runCount),
            connection: entry.connection,
            database: entry.database,
            durationSeconds: entry.durationSeconds,
            affectedRows: entry.affectedRows,
            succeeded: entry.succeeded,
            note: entry.note
        )

        guard let index = entries.firstIndex(where: {
            normalizedSQL($0.sql) == normalizedSQL(newEntry.sql)
                && $0.connection == newEntry.connection
                && $0.database == newEntry.database
        }) else {
            return entries + [newEntry]
        }

        var updated = entries
        var existing = updated[index]
        existing.runCount += newEntry.runCount
        existing.lastExecutedAt = max(existing.lastExecutedAt, newEntry.lastExecutedAt)
        existing.firstExecutedAt = min(existing.firstExecutedAt, newEntry.firstExecutedAt)
        existing.durationSeconds = newEntry.durationSeconds
        existing.affectedRows = newEntry.affectedRows
        existing.succeeded = newEntry.succeeded
        existing.note = newEntry.note
        updated[index] = existing
        return updated
    }

    // MARK: 渲染

    public static func render(
        _ entries: [SQLArchiveEntry],
        day: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let dayText = fileName(for: day).replacingOccurrences(of: ".sql", with: "")
        var lines: [String] = [
            "\(Self.headerPrefix) · \(dayText)",
            "-- 本文件由应用自动追加，可读、可直接执行，也可放进版本库。",
            "-- 同一条 SQL 重复执行只累计「执行次数」，不会重复抄写。"
        ]

        for entry in entries {
            lines.append("")
            lines.append(startMarker)
            lines.append("-- 首次执行: \(stamp(entry.firstExecutedAt, timeZone: timeZone))")
            lines.append("-- 最近执行: \(stamp(entry.lastExecutedAt, timeZone: timeZone))")
            lines.append("-- 执行次数: \(entry.runCount)")
            lines.append("-- 连接: \(entry.connection)")
            lines.append("-- 数据库: \(entry.database)")
            if let duration = entry.durationSeconds {
                lines.append("-- 耗时: \(String(format: "%.3f", duration)) 秒")
            }
            if let affectedRows = entry.affectedRows {
                lines.append("-- 影响行数: \(affectedRows)")
            }
            lines.append("-- 结果: \(entry.succeeded ? "成功" : "失败")")
            if let note = entry.note, !note.isEmpty {
                // 说明里可能有换行：**转义保留**而不是压平 —— 压平会丢信息，
                // 而转义后文件仍是行结构，且 render/parse 往返精确。
                lines.append("-- 说明: " + escapeNote(note))
            }
            lines.append(entry.sql.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append(endMarker)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: 解析

    /// 解析归档文件。与 `render` 构成往返：`parse(render(x)) == x`（时间精度到秒）。
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> [SQLArchiveEntry] {
        var entries: [SQLArchiveEntry] = []
        var current: [String: String] = [:]
        var sqlLines: [String] = []
        var inEntry = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == startMarker {
                inEntry = true
                current = [:]
                sqlLines = []
                continue
            }
            if trimmed == endMarker {
                if inEntry,
                   let first = current["首次执行"].flatMap({ date(from: $0, timeZone: timeZone) }),
                   let last = current["最近执行"].flatMap({ date(from: $0, timeZone: timeZone) }) {
                    entries.append(SQLArchiveEntry(
                        sql: sqlLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                        firstExecutedAt: first,
                        lastExecutedAt: last,
                        runCount: current["执行次数"].flatMap(Int.init) ?? 1,
                        connection: current["连接"] ?? "",
                        database: current["数据库"] ?? "",
                        durationSeconds: current["耗时"].flatMap { Double($0.replacingOccurrences(of: " 秒", with: "")) },
                        affectedRows: current["影响行数"].flatMap(Int.init),
                        succeeded: (current["结果"] ?? "成功") == "成功",
                        note: current["说明"].map(unescapeNote)
                    ))
                }
                inEntry = false
                continue
            }

            guard inEntry else { continue }
            if trimmed.hasPrefix("-- ") {
                let body = String(trimmed.dropFirst(3))
                if let separator = body.firstIndex(of: ":") {
                    let key = String(body[body.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
                    let value = String(body[body.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                    current[key] = value
                    continue
                }
            }
            sqlLines.append(line)
        }

        return entries
    }

    // MARK: 说明字段的转义

    /// 把说明里的换行与反斜杠转义成单行形式（文件是行结构，不能直接嵌换行）。
    static func escapeNote(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": break
            default: result.append(character)
            }
        }
        return result
    }

    /// `escapeNote` 的逆操作；遇到未知转义原样保留，不吞字符。
    static func unescapeNote(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let next = iterator.next() else {
                result.append("\\")
                break
            }
            switch next {
            case "n": result.append("\n")
            case "\\": result.append("\\")
            default:
                result.append("\\")
                result.append(next)
            }
        }
        return result
    }

    // MARK: 时间

    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func date(from text: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }
}
