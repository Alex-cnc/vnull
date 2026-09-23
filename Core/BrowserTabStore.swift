import Foundation

/// 浏览器页签的会话持久化（FR-EDIT-34 契约 ⑤）。
///
/// **恢复语义（重要）**：只恢复「地址 / 标题 / 历史」，**绝不自动发起请求**。
/// 若恢复时就去加载，用户只是打开应用、什么都没点，数据就已经出网了 ——
/// 那等于用"会话恢复"绕过了「默认不加载远程内容」这条契约。所以恢复出来的页签是
/// **已恢复但未加载**状态，由用户在界面上显式点一次才真正请求。
///
/// 同时这也是为什么它不做"自动清理"：页签是用户自己开的，数量通常个位数，
/// 悄悄丢弃比留着更让人困惑。
public actor BrowserTabStore {
    public static let shared = BrowserTabStore()

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// 恢复上限：极端情况下（手改文件）也不让界面一次性冒出几百个页签。
    public static let restoreLimit = 20

    public init(directoryURL: URL? = nil) {
        let baseURL: URL
        if let directoryURL {
            baseURL = directoryURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            baseURL = applicationSupport.appendingPathComponent(
                DoyahIdentity.applicationSupportDirectoryName,
                isDirectory: true
            )
        }

        self.fileURL = baseURL.appendingPathComponent("browser-tabs.json", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func fileLocation() -> URL { fileURL }

    public func save(_ pages: [BrowserPage]) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(Array(pages.prefix(Self.restoreLimit)))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw AppError.persistence("浏览器页签保存失败：\(error.localizedDescription)")
        }
    }

    /// 读取上次的页签。**文件不存在 = 没有页签**（不是错误）；文件损坏则如实抛出，
    /// 由调用方决定是提示还是忽略 —— 静默吞掉会让"页签怎么没了"变成无解的悬案。
    public func load() throws -> [BrowserPage] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return [] }
            let pages = try decoder.decode([BrowserPage].self, from: data)
            return Array(pages.prefix(Self.restoreLimit))
        } catch {
            throw AppError.persistence("浏览器页签读取失败：\(error.localizedDescription)")
        }
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
