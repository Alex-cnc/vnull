import Foundation

/// 「最近打开」的落盘（FR-EDIT-35 的 Home 页数据）。
///
/// 与工程里其它偏好文件同一套路：**一个 JSON、按需读写、坏了不致命**。
/// 读失败时返回空历史而不是抛错 —— 一份"最近打开"记录坏掉，不该让工作区打不开；
/// 但要**说出来**（调用方可以把它显示在状态上），不静默吞掉。
public struct WorkspaceHistoryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 默认位置：应用数据目录下的 `workspace-history.json`。
    public static func standard(applicationSupport: URL? = nil) -> WorkspaceHistoryStore {
        let base = applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return WorkspaceHistoryStore(
            fileURL: base
                .appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
                .appendingPathComponent("workspace-history.json", isDirectory: false)
        )
    }

    /// 读取；文件不存在视为空历史（第一次打开应用就是这种状态）。
    public func load() throws -> WorkspaceHistory {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return WorkspaceHistory() }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return WorkspaceHistory() }
        return try JSONDecoder().decode(WorkspaceHistory.self, from: data)
    }

    /// 写入（原子替换；目录不存在时先建）。
    public func save(_ history: WorkspaceHistory) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(history).write(to: fileURL, options: .atomic)
    }
}
