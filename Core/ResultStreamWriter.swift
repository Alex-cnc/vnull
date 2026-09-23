import Foundation

/// 流式导出的错误（FR-RES-13）。
public enum ResultStreamError: Error, Equatable, LocalizedError {
    case notStarted
    case alreadyStarted
    case alreadyFinished
    case aborted
    case invalidFlushLimit(Int)

    public var errorDescription: String? {
        switch self {
        case .notStarted: return "流式导出尚未开始（缺少 begin()）。"
        case .alreadyStarted: return "流式导出已经开始，不能重复 begin()。"
        case .alreadyFinished: return "流式导出已经结束。"
        case .aborted: return "流式导出已中止。"
        case .invalidFlushLimit(let value): return "刷新阈值必须为正数，收到 \(value)。"
        }
    }
}

/// 大结果集流式落盘（FR-RES-13）。
///
/// 解决的问题：一次性导出要把整个结果集拼成一个 `String`，行数一多就同时出现
/// 「结果集本身」+「文本副本」两份内存。这里改成**逐块写入**：
/// 调用方按页喂行（`write(_:)`），内部只保留一个受 `flushByteLimit` 约束的待写缓冲，
/// 超过阈值立即落盘，内存占用与总行数无关。
///
/// 三个保证：
/// - **逐字节一致**：CSV / TSV / Markdown / INSERT 按块写出的文件，与
///   `ResultExporter.text(for:format:)` 一次成型的文本完全一致（共用同一套行渲染），
///   所以「分块」不会改变导出结果；JSON 例外，见 `begin()` 说明；
/// - **中断清理**：先写隐藏的 `.partial-<uuid>` 临时文件，`finish()` 成功才移动
///   到目标路径。也就是说目标文件要么是完整的，要么不存在 —— 中途取消 / 抛错 /
///   对象被释放（`deinit`）都不会留下半个文件冒充成品；
/// - **不毁已有文件**（R-34）：目标已存在时**绝不先删**它，而是「原文件先挪到备份 →
///   移入新文件 → 成功才删备份；失败把原文件放回去」。导出失败最坏结果是"没导出成功"，
///   而不是"原来的文件也没了"。
///
/// 本类型不做并发保护，约定由单一调用方顺序使用（一行一条 `write`）。
public final class ResultStreamWriter {

    /// 完成后的统计。
    public struct Report: Equatable, Sendable {
        public var rowCount: Int
        public var byteCount: Int
        /// 实际落盘次数（含最后一次收尾刷新）。
        public var flushCount: Int
        public var fileURL: URL

        public init(rowCount: Int, byteCount: Int, flushCount: Int, fileURL: URL) {
            self.rowCount = rowCount
            self.byteCount = byteCount
            self.flushCount = flushCount
            self.fileURL = fileURL
        }
    }

    private enum State {
        case idle
        case writing
        case finished
        case aborted
    }

    private let targetURL: URL
    private let partialURL: URL
    private let format: ResultExportFormat
    private let columns: [ColumnMeta]
    private let tableName: String
    private let dialect: (any SQLDialect)?
    private let includeByteOrderMark: Bool
    private let flushByteLimit: Int
    /// 文件移动操作。抽成可注入，是为了能测「移动失败」这条路径 ——
    /// 那条路径正是 R-34 里会**毁掉用户已有文件**的地方，必须被测试覆盖。
    private let moveItem: @Sendable (URL, URL) throws -> Void

    /// JSON 的列名 → 唯一键（重复列名加后缀），构造时算一次。
    private let jsonKeys: [String]
    /// INSERT 的表名 / 列清单前缀，构造时算一次。
    private let insertTable: String
    private let insertColumnList: String

    private var state: State = .idle
    private var handle: FileHandle?
    private var pending: [String] = []
    private var pendingBytes = 0
    private var rowCount = 0
    private var byteCount = 0
    private var flushCount = 0
    private var wroteAnyRow = false

    /// 已经写入的行数（含尚未落盘的部分）。
    public var writtenRowCount: Int { rowCount }
    /// 已经真正落盘的字节数。
    public var writtenByteCount: Int { byteCount }

    public init(
        targetURL: URL,
        format: ResultExportFormat,
        columns: [ColumnMeta],
        tableName: String = "table_name",
        dialect: (any SQLDialect)? = nil,
        includeByteOrderMark: Bool = true,
        flushByteLimit: Int = 1 << 20,
        moveItem: @escaping @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) {
        self.targetURL = targetURL
        self.format = format
        self.columns = columns
        self.tableName = tableName
        self.dialect = dialect
        self.includeByteOrderMark = includeByteOrderMark
        self.flushByteLimit = flushByteLimit
        self.moveItem = moveItem
        self.jsonKeys = ResultExporter.uniqueKeys(for: columns)
        let prefix = ResultExporter.insertPrefix(tableName: tableName, columns: columns, dialect: dialect)
        self.insertTable = prefix.table
        self.insertColumnList = prefix.columnList
        self.partialURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).partial-\(UUID().uuidString)")
    }

    deinit {
        // 对象被释放而导出没走完（含抛错后忘记 abort）：清理半成品。
        if state == .writing {
            cleanUpPartialFile()
        }
    }

    // MARK: - 生命周期

    /// 建立临时文件并写入格式头。
    ///
    /// JSON 说明：一次性导出把 `rowCount` 写在最前，而流式导出开始时还不知道总行数，
    /// 因此流式 JSON 的形状是 `{ "columns": [...], "rows": [...], "rowCount": N }`
    /// —— 键顺序不同，语义相同（JSON 对象无序），用 `JSONSerialization` 解析结果一致。
    public func begin() throws {
        guard flushByteLimit > 0 else { throw ResultStreamError.invalidFlushLimit(flushByteLimit) }
        switch state {
        case .idle:
            break
        case .writing, .finished:
            throw ResultStreamError.alreadyStarted
        case .aborted:
            throw ResultStreamError.aborted
        }

        // 目标目录必须存在：导出路径由保存面板给出，父目录不存在属于调用方错误。
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: partialURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = handle
        state = .writing

        switch format {
        case .csv:
            if includeByteOrderMark {
                try append("\u{FEFF}")
            }
            if !columns.isEmpty {
                try append(ResultExporter.csvHeader(for: columns) + "\r\n")
            }
        case .tsv:
            if !columns.isEmpty {
                try append(ResultExporter.tsvHeader(for: columns) + "\n")
            }
        case .markdown:
            if !columns.isEmpty {
                try append(ResultExporter.markdownHeader(for: columns) + "\n")
                try append(ResultExporter.markdownSeparator(for: columns) + "\n")
            }
        case .json:
            try append("{\n  \"columns\": [\n")
            try append(ResultExporter.jsonColumnObjects(for: columns, keys: jsonKeys).joined(separator: ",\n"))
            try append("\n  ],\n  \"rows\": [")
        case .sqlInsert:
            // INSERT 没有独立的文件头，逐行成句。
            break
        }
    }

    /// 写入一批行（一页）。
    public func write(_ rows: [[String?]]) throws {
        guard state == .writing else { throw stateError() }
        guard !rows.isEmpty else { return }

        // Markdown / INSERT 没有列就没有可写内容（与一次性导出保持一致）。
        if columns.isEmpty, format == .markdown || format == .sqlInsert {
            return
        }

        for row in rows {
            try append(line(for: row))
            rowCount += 1
        }
    }

    /// 把待写缓冲刷到磁盘。
    public func flush() throws {
        guard state == .writing else { throw stateError() }
        try flushPending()
    }

    /// 写入格式尾、落盘、并把临时文件原子移动到目标路径。
    @discardableResult
    public func finish() throws -> Report {
        guard state == .writing, let handle else { throw stateError() }

        try writeFooter()
        try flushPending()
        try handle.close()
        self.handle = nil

        let manager = FileManager.default

        // 目标不存在：直接移动（移动成功之前不改状态，失败时 `abort()` / `deinit` 仍会清临时文件）。
        guard manager.fileExists(atPath: targetURL.path) else {
            try moveItem(partialURL, targetURL)
            state = .finished
            return makeReport()
        }

        // 目标已存在（用户选了已有文件）——**绝不能先删它**（R-34）：
        // 原来是 `removeItem(target)` 再 `moveItem`，移动一旦失败（跨卷、权限、磁盘满），
        // 用户原来的文件就没了，而新文件也没生成。
        // 改为「原文件先挪到备份 → 移动 → 成功才删备份；失败则把原文件放回去」。
        let backupURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).backup-\(UUID().uuidString)")
        try moveItem(targetURL, backupURL)

        do {
            try moveItem(partialURL, targetURL)
        } catch {
            // 把用户原来的文件**放回去**，再抛出真实错误。
            try? moveItem(backupURL, targetURL)
            throw error
        }

        try? manager.removeItem(at: backupURL)
        state = .finished

        return makeReport()
    }

    private func makeReport() -> Report {
        Report(
            rowCount: rowCount,
            byteCount: byteCount,
            flushCount: flushCount,
            fileURL: targetURL
        )
    }

    /// 中止导出并删除半成品（目标路径不受影响）。
    ///
    /// 幂等：重复调用、或在 `begin()` 之前调用都不会抛错。
    public func abort() {
        guard state == .writing else {
            if state == .idle { state = .aborted }
            return
        }
        state = .aborted
        try? handle?.close()
        handle = nil
        cleanUpPartialFile()
    }

    // MARK: - 便捷入口

    /// 「取一页 → 写一页」驱动整个导出；`fetchPage` 返回值少于 `pageSize` 即视为最后一页。
    ///
    /// 内存占用 = 一页行数 + 一个刷新缓冲，与总行数无关。中途抛错会自动 `abort()`，
    /// 不会留下半成品文件。
    @discardableResult
    public static func write(
        to url: URL,
        format: ResultExportFormat,
        columns: [ColumnMeta],
        tableName: String = "table_name",
        dialect: (any SQLDialect)? = nil,
        includeByteOrderMark: Bool = true,
        flushByteLimit: Int = 1 << 20,
        pageSize: Int = 1_000,
        fetchPage: (_ offset: Int, _ limit: Int) throws -> [[String?]]
    ) throws -> Report {
        let writer = ResultStreamWriter(
            targetURL: url,
            format: format,
            columns: columns,
            tableName: tableName,
            dialect: dialect,
            includeByteOrderMark: includeByteOrderMark,
            flushByteLimit: flushByteLimit
        )
        try writer.begin()
        do {
            var offset = 0
            while true {
                let page = try fetchPage(offset, pageSize)
                guard !page.isEmpty else { break }
                try writer.write(page)
                offset += page.count
                if page.count < pageSize { break }
            }
            return try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
    }

    // MARK: - 内部

    private func line(for row: [String?]) -> String {
        switch format {
        case .csv:
            return ResultExporter.csvLine(row, columns: columns) + "\r\n"
        case .tsv:
            return ResultExporter.tsvLine(row, columns: columns) + "\n"
        case .markdown:
            return ResultExporter.markdownLine(row, columns: columns) + "\n"
        case .sqlInsert:
            return ResultExporter.insertStatement(
                row,
                columns: columns,
                table: insertTable,
                columnList: insertColumnList
            ) + "\n"
        case .json:
            let prefix = wroteAnyRow ? ",\n    " : "\n    "
            wroteAnyRow = true
            return prefix + ResultExporter.jsonRowObject(row, keys: jsonKeys)
        }
    }

    private func writeFooter() throws {
        guard format == .json else { return }
        // 行块为空时 `"rows": [` 后面直接换行收尾，仍是合法 JSON。
        try append("\n  ],\n")
        try append("  \"rowCount\": \(rowCount),\n")
        try append("  \"affectedRows\": null\n}\n")
    }

    private func append(_ text: String) throws {
        pending.append(text)
        pendingBytes += text.utf8.count
        if pendingBytes >= flushByteLimit {
            try flushPending()
        }
    }

    private func flushPending() throws {
        guard !pending.isEmpty else { return }
        let text = pending.joined()
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0

        guard let handle else { throw stateError() }
        let data = Data(text.utf8)
        try handle.write(contentsOf: data)
        byteCount += data.count
        flushCount += 1
    }

    private func cleanUpPartialFile() {
        try? FileManager.default.removeItem(at: partialURL)
    }

    private func stateError() -> ResultStreamError {
        switch state {
        case .idle: return .notStarted
        case .aborted: return .aborted
        case .finished, .writing: return .alreadyFinished
        }
    }
}
