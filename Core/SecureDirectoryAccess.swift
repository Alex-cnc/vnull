import Foundation

// MARK: - 错误与状态

/// 目录授权失败的原因（FR-AI-08）。
///
/// 全部带可读说明与补救建议：验收要点明确要求「未授权目录给**可读提示**而非静默失败」，
/// 所以这里不返回裸 `false`，也不吞掉路径信息。
public enum DirectoryAccessError: Error, Equatable, LocalizedError {
    /// 选中的不是目录。
    case notADirectory(path: String)
    /// 生成书签失败（系统拒绝 / 沙箱限制）。
    case bookmarkCreationFailed(reason: String)
    /// 没有可用授权（没有书签，或书签已失效 / 目录不在）。
    case notAuthorized(message: String)
    /// 目录存在但当前进程无法访问。
    case accessDenied(path: String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path):
            return "所选路径不是目录：\(path)"
        case .bookmarkCreationFailed(let reason):
            return "无法为所选目录创建授权书签：\(reason)"
        case .notAuthorized(let message):
            return message
        case .accessDenied(let path):
            return "没有访问该目录的权限：\(path)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notADirectory:
            return "请选择一个文件夹而不是文件。"
        case .bookmarkCreationFailed:
            return "请重新选择目录；若持续失败，请确认应用有访问该位置的权限。"
        case .notAuthorized:
            return "请在「任务 → 导出目录」里重新选择一次目录，以重新授权。"
        case .accessDenied:
            return "请在系统设置里授予文件访问权限，或改选其他目录。"
        }
    }
}

/// 目录授权当前是否可用（FR-AI-08）。
///
/// 做成「状态」而不是「抛错」：界面需要把结论直接显示成一句可读提示，
/// 而不是捕获异常再翻译。
public enum DirectoryAccessStatus: Equatable, Sendable {
    /// 可用；`isStale` 表示书签过期，建议尽快重新授权（本次仍可用）。
    case granted(path: String, isStale: Bool)
    /// 从未授权（没有书签）。
    case notAuthorized
    /// 目录不存在：被删除、被移动，或所在卷未挂载。
    case missing(path: String)
    /// 目录存在但不可读写。
    case denied(path: String)
    /// 书签解析失败（换机器、系统迁移、书签损坏）。
    case resolutionFailed(reason: String)

    /// 能否用于写入导出产物。
    public var isUsable: Bool {
        if case .granted = self { return true }
        return false
    }

    /// 可读提示（界面直接显示）。
    public var message: String {
        switch self {
        case .granted(let path, let isStale):
            return isStale
                ? "导出目录：\(path)（授权书签已过期，建议重新选择一次）"
                : "导出目录：\(path)"
        case .notAuthorized:
            return "尚未授权导出目录。"
        case .missing(let path):
            return "授权目录已不存在：\(path)"
        case .denied(let path):
            return "没有访问授权目录的权限：\(path)"
        case .resolutionFailed(let reason):
            return "授权书签无法解析：\(reason)"
        }
    }

    /// 补救建议；可用时为 `nil`。
    public var recoverySuggestion: String? {
        switch self {
        case .granted:
            return nil
        case .notAuthorized:
            return "请选择一个目录并授权导出。"
        case .missing:
            return "目录可能被移动或所在磁盘未挂载，请重新选择。"
        case .denied:
            return "请在系统设置中授予文件访问权限，或改选其他目录。"
        case .resolutionFailed:
            return "请重新选择目录以生成新的授权书签。"
        }
    }

    /// 授权目录路径（可用 / 缺失 / 无权限时给出）。
    public var path: String? {
        switch self {
        case .granted(let path, _), .missing(let path), .denied(let path):
            return path
        case .notAuthorized, .resolutionFailed:
            return nil
        }
    }
}

// MARK: - 书签

/// 用户授权目录的持久化凭据（FR-AI-08）。
///
/// 只保存**书签字节**，不保存也从不硬编码路径：路径由系统在解析时给出，
/// 目录被移动 / 改名后书签仍能跟随（这是书签相对裸路径的核心价值）。
public struct DirectoryBookmark: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// 展示用名称（默认取目录名），仅用于界面。
    public var displayName: String
    /// security-scoped bookmark 字节。
    public var bookmarkData: Data
    public var createdAt: Date
    /// 最近一次成功解析出的路径（仅展示 / 排查用，**不作为访问依据**）。
    public var lastKnownPath: String?

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        createdAt: Date = Date(),
        lastKnownPath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.lastKnownPath = lastKnownPath
    }
}

/// 安全作用域书签的底层能力抽象。
///
/// 真实实现走 Foundation 的书签 API；Core 单测用假实现注入，
/// 因此「未授权 / 目录缺失 / 书签过期」这些分支都能被确定性地覆盖，
/// 不依赖运行环境是否处于沙箱内。
public protocol SecurityScopedBookmarking: Sendable {
    /// 为一个**用户已选择**的目录生成 security-scoped bookmark。
    func makeBookmark(for directory: URL) throws -> Data
    /// 解析书签；`isStale` 表示系统建议重新生成。
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
    /// 开始访问授权资源；返回是否由本次调用真正开启（需要成对 stop）。
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// Foundation 实现（macOS）。
public struct FoundationSecurityScopedBookmarking: SecurityScopedBookmarking {
    public init() {}

    public func makeBookmark(for directory: URL) throws -> Data {
        do {
            return try directory.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw DirectoryAccessError.bookmarkCreationFailed(reason: error.localizedDescription)
        }
    }

    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    /// 说明：非沙箱进程里对普通文件 URL 调用会返回 `false`，但这**不代表没有权限**。
    /// 因此调用方不能把 `false` 当作「被拒绝」——真正的判断依据是目录是否存在可读写。
    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// 目录选择抽象（FR-AI-08「系统目录选择」）。
///
/// 放在 Core 是为了让「选目录 → 生成书签 → 落到任务导出设置」这条流程可测；
/// 具体实现由 App 层用 `NSOpenPanel` 提供（Core 不依赖 AppKit）。
public protocol DirectoryPicker: Sendable {
    /// 让用户选一个目录；用户取消时返回 `nil`。
    func pickDirectory(prompt: String) throws -> URL?
}

// MARK: - 访问

/// 安全作用域目录访问（FR-AI-08）。
///
/// 三条约束写在接口形状里：
/// 1. **没有「传个路径就能用」的入口** —— 访问必须先有书签，书签只能由「用户选择」产生；
/// 2. 路径永远来自书签解析，不硬编码；
/// 3. 失败一律是可读状态 / 可读错误，不静默返回空。
public enum SecureDirectoryAccess {

    /// 用户刚选好目录 → 生成可持久化的书签。
    ///
    /// - Throws: 选中的不是目录（`.notADirectory`）、或系统拒绝生成书签。
    public static func makeBookmark(
        for directory: URL,
        displayName: String? = nil,
        bookmarking: any SecurityScopedBookmarking = FoundationSecurityScopedBookmarking(),
        fileManager: FileManager = .default
    ) throws -> DirectoryBookmark {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DirectoryAccessError.notADirectory(path: directory.path)
        }

        let data = try bookmarking.makeBookmark(for: directory)
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DirectoryBookmark(
            displayName: (name?.isEmpty == false ? name! : directory.lastPathComponent),
            bookmarkData: data,
            lastKnownPath: directory.path
        )
    }

    /// 解析书签并判断当前可用性。**不抛错**：结论就是状态本身。
    public static func status(
        for bookmark: DirectoryBookmark,
        bookmarking: any SecurityScopedBookmarking = FoundationSecurityScopedBookmarking(),
        fileManager: FileManager = .default
    ) -> DirectoryAccessStatus {
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try bookmarking.resolve(bookmark.bookmarkData)
        } catch {
            return .resolutionFailed(reason: error.localizedDescription)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .missing(path: resolved.url.path)
        }

        guard fileManager.isReadableFile(atPath: resolved.url.path) else {
            return .denied(path: resolved.url.path)
        }

        return .granted(path: resolved.url.path, isStale: resolved.isStale)
    }

    /// 取用授权目录：解析成功则开启访问并返回 `DirectoryGrant`（用完即停）。
    ///
    /// - Throws: 状态不可用时抛 `.notAuthorized`，其 `errorDescription` 就是界面要显示的那句话。
    public static func open(
        _ bookmark: DirectoryBookmark,
        bookmarking: any SecurityScopedBookmarking = FoundationSecurityScopedBookmarking(),
        fileManager: FileManager = .default
    ) throws -> DirectoryGrant {
        let status = status(for: bookmark, bookmarking: bookmarking, fileManager: fileManager)
        guard case .granted(let path, let isStale) = status else {
            throw DirectoryAccessError.notAuthorized(message: status.message)
        }
        // 路径来自书签解析结果（绝对路径），从类型上就不存在「硬编码路径」这条路径。
        let url = URL(fileURLWithPath: path, isDirectory: true)

        let started = bookmarking.startAccessing(url)
        return DirectoryGrant(
            url: url,
            bookmark: bookmark,
            isStale: isStale,
            didStartAccessing: started,
            bookmarking: bookmarking
        )
    }

    /// 完整流程：让用户选目录 → 生成书签 → 得到任务导出设置（FR-AI-08 + FR-AI-05 衔接）。
    ///
    /// 用户取消选择时返回 `nil`（这不是错误）。
    public static func requestExportSettings(
        prompt: String = "选择任务产物的导出目录",
        format: DataTaskDefinition.ExportSettings.Format = .csv,
        fileNameTemplate: String? = nil,
        picker: any DirectoryPicker,
        bookmarking: any SecurityScopedBookmarking = FoundationSecurityScopedBookmarking(),
        fileManager: FileManager = .default
    ) throws -> DataTaskDefinition.ExportSettings? {
        guard let directory = try picker.pickDirectory(prompt: prompt) else { return nil }
        let bookmark = try makeBookmark(
            for: directory,
            bookmarking: bookmarking,
            fileManager: fileManager
        )
        return DataTaskDefinition.ExportSettings(
            format: format,
            directoryBookmark: bookmark.bookmarkData,
            fileNameTemplate: fileNameTemplate
        )
    }

    /// 从任务导出设置恢复出书签（`nil` = 该任务没设导出目录）。
    public static func bookmark(
        from settings: DataTaskDefinition.ExportSettings,
        displayName: String = "任务导出目录"
    ) -> DirectoryBookmark? {
        guard let data = settings.directoryBookmark else { return nil }
        return DirectoryBookmark(displayName: displayName, bookmarkData: data)
    }
}

/// 一次授权目录的取用句柄：在生命周期内保持访问，释放时自动停止（FR-AI-08）。
public final class DirectoryGrant {
    public let url: URL
    public let bookmark: DirectoryBookmark
    /// 书签已过期：本次仍可用，但应尽快重新授权。
    public let isStale: Bool
    private let didStartAccessing: Bool
    private let bookmarking: any SecurityScopedBookmarking
    private var stopped = false

    init(
        url: URL,
        bookmark: DirectoryBookmark,
        isStale: Bool,
        didStartAccessing: Bool,
        bookmarking: any SecurityScopedBookmarking
    ) {
        self.url = url
        self.bookmark = bookmark
        self.isStale = isStale
        self.didStartAccessing = didStartAccessing
        self.bookmarking = bookmarking
    }

    /// 本次是否由我们开启了访问（对称停用用）。
    public var startedAccessing: Bool { didStartAccessing }

    /// 在授权目录下拼出产物文件 URL。
    public func fileURL(named fileName: String) -> URL {
        url.appendingPathComponent(fileName)
    }

    /// 停止访问；可重复调用。
    public func stopAccessing() {
        guard !stopped else { return }
        stopped = true
        guard didStartAccessing else { return }
        bookmarking.stopAccessing(url)
    }

    deinit {
        stopAccessing()
    }
}

// MARK: - 书签持久化

/// 已授权目录的持久化（FR-AI-08）。
///
/// 存 `directory-bookmarks.json`，只存书签字节与非敏感展示信息。
public actor DirectoryBookmarkStore {
    public static let shared = DirectoryBookmarkStore()

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL? = nil) {
        let baseURL: URL
        if let directoryURL {
            baseURL = directoryURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            baseURL = applicationSupport.appendingPathComponent("PostgresClient", isDirectory: true)
        }

        self.fileURL = baseURL.appendingPathComponent("directory-bookmarks.json", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func fileLocation() -> URL { fileURL }

    public func all() throws -> [DirectoryBookmark] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try decoder.decode([DirectoryBookmark].self, from: Data(contentsOf: fileURL))
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    /// 新增或替换（按 `id` 匹配）。
    @discardableResult
    public func save(_ bookmark: DirectoryBookmark) throws -> DirectoryBookmark {
        var all = try all()
        if let index = all.firstIndex(where: { $0.id == bookmark.id }) {
            all[index] = bookmark
        } else {
            all.append(bookmark)
        }
        try write(all)
        return bookmark
    }

    /// 记住最近一次解析出的路径（仅展示用）。
    public func rememberResolvedPath(_ path: String, for id: UUID) throws {
        var all = try all()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].lastKnownPath = path
        try write(all)
    }

    public func delete(id: UUID) throws {
        var all = try all()
        all.removeAll { $0.id == id }
        try write(all)
    }

    public func removeAll() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return }
        try? manager.removeItem(at: fileURL)
    }

    private func write(_ bookmarks: [DirectoryBookmark]) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(bookmarks).write(to: fileURL, options: [.atomic])
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }
}
