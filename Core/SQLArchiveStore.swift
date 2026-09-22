import Foundation

/// 查询归档的落盘（FR-EDIT-32）。
///
/// 目录由调用方决定（App 层用「授权目录」，沙箱下才写得进去）；本类型只管
/// 「读当天文件 → 合并 → 原子写回」。写入用 Foundation 的 `atomically: true`
/// （先写临时文件再改名），因此磁盘上不会留半截文件。
public struct SQLArchiveStore: Sendable {

    /// 归档目录（最终目录，不再追加子目录 —— 由调用方决定放哪儿）。
    public let directory: URL
    public var timeZone: TimeZone

    public init(directory: URL, timeZone: TimeZone = .current) {
        self.directory = directory
        self.timeZone = timeZone
    }

    /// 当天归档文件路径，例如 `<目录>/2026-09-23.sql`。
    public func fileURL(on day: Date) -> URL {
        directory.appendingPathComponent(SQLArchive.fileName(for: day))
    }

    /// 读取某天的归档条目；文件不存在时返回空数组（不是错误）。
    public func entries(on day: Date) throws -> [SQLArchiveEntry] {
        let url = fileURL(on: day)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return SQLArchive.parse(text, timeZone: timeZone)
    }

    /// 追加一次执行并写回；返回当天归档后的条目总数。
    @discardableResult
    public func append(_ entry: SQLArchiveEntry, on day: Date = Date()) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let merged = SQLArchive.merged(try entries(on: day), adding: entry)
        let text = SQLArchive.render(merged, day: day, timeZone: timeZone)
        try text.write(to: fileURL(on: day), atomically: true, encoding: .utf8)
        return merged.count
    }
}


/// 把归档写入串行化。
///
/// `SQLArchiveStore.append` 是「读当天文件 → 合并 → 原子写回」，**两次执行几乎同时结束**
/// 时会互相覆盖（后写的把先写的条目丢了）。归档调用来自执行完成回调，天然可能并发，
/// 所以用一个 actor 把写入排成队；同时写盘也就从主线程挪走了，不卡界面。
public actor SQLArchiveWriter {
    public init() {}

    /// 追加一次执行；返回当天归档后的条目总数。
    @discardableResult
    public func append(
        _ entry: SQLArchiveEntry,
        in directory: URL,
        on day: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> Int {
        try SQLArchiveStore(directory: directory, timeZone: timeZone).append(entry, on: day)
    }
}
