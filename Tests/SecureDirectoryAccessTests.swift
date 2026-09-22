import XCTest
@testable import DoyahCore

/// 假书签实现：把「书签」当成它记录的路径，不碰真实钥匙串 / 沙箱。
private final class FakeBookmarking: SecurityScopedBookmarking, @unchecked Sendable {
    enum Behaviour {
        case normal
        case creationFails(String)
        case resolutionFails(String)
        case stale
    }

    private let lock = NSLock()
    private var behaviour: Behaviour
    private var paths: [Data: String] = [:]
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(behaviour: Behaviour = .normal) {
        self.behaviour = behaviour
    }

    func setBehaviour(_ behaviour: Behaviour) {
        lock.lock()
        self.behaviour = behaviour
        lock.unlock()
    }

    func makeBookmark(for directory: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if case .creationFails(let reason) = behaviour {
            throw DirectoryAccessError.bookmarkCreationFailed(reason: reason)
        }
        let data = Data(directory.path.utf8)
        paths[data] = directory.path
        return data
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if case .resolutionFails(let reason) = behaviour {
            throw DirectoryAccessError.bookmarkCreationFailed(reason: reason)
        }
        guard let path = paths[data] ?? String(data: data, encoding: .utf8) else {
            throw DirectoryAccessError.bookmarkCreationFailed(reason: "未知书签")
        }
        let isStale: Bool
        if case .stale = behaviour { isStale = true } else { isStale = false }
        return (URL(fileURLWithPath: path, isDirectory: true), isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.lock()
        startCount += 1
        lock.unlock()
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }
}

/// 假目录选择器。
private struct FakeDirectoryPicker: DirectoryPicker {
    var directory: URL?
    var error: Error?

    func pickDirectory(prompt: String) throws -> URL? {
        if let error { throw error }
        return directory
    }
}

/// FR-AI-08：安全作用域目录授权（未授权给可读提示而非静默失败）。
final class SecureDirectoryAccessTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureDirectoryAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    // MARK: - 授权

    func testMakeBookmarkForChosenDirectory() throws {
        let directory = try makeDirectory()
        let bookmarking = FakeBookmarking()

        let bookmark = try SecureDirectoryAccess.makeBookmark(for: directory, bookmarking: bookmarking)

        XCTAssertEqual(bookmark.displayName, directory.lastPathComponent)
        XCTAssertEqual(bookmark.lastKnownPath, directory.path)
        XCTAssertFalse(bookmark.bookmarkData.isEmpty)
    }

    func testMakeBookmarkRejectsPlainFile() throws {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("out.csv")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try SecureDirectoryAccess.makeBookmark(for: file, bookmarking: FakeBookmarking())
        ) { error in
            guard case .notADirectory? = error as? DirectoryAccessError else {
                return XCTFail("应当报「不是目录」，实际：\(error)")
            }
            XCTAssertNotNil((error as? DirectoryAccessError)?.recoverySuggestion)
        }
    }

    func testBookmarkCreationFailureIsReportedReadably() throws {
        let directory = try makeDirectory()
        let bookmarking = FakeBookmarking(behaviour: .creationFails("sandbox denied"))

        XCTAssertThrowsError(
            try SecureDirectoryAccess.makeBookmark(for: directory, bookmarking: bookmarking)
        ) { error in
            XCTAssertEqual(
                error as? DirectoryAccessError,
                .bookmarkCreationFailed(reason: "sandbox denied")
            )
        }
    }

    // MARK: - 状态（未授权给可读提示）

    func testStatusIsGrantedForResolvableBookmark() throws {
        let directory = try makeDirectory()
        let bookmarking = FakeBookmarking()
        let bookmark = try SecureDirectoryAccess.makeBookmark(for: directory, bookmarking: bookmarking)

        let status = SecureDirectoryAccess.status(for: bookmark, bookmarking: bookmarking)

        XCTAssertEqual(status, .granted(path: directory.path, isStale: false))
        XCTAssertTrue(status.isUsable)
        XCTAssertTrue(status.message.contains(directory.path))
        XCTAssertNil(status.recoverySuggestion)
    }

    /// 书签过期：本次仍可用，但提示要重新授权。
    func testStaleBookmarkStaysUsableButWarns() throws {
        let directory = try makeDirectory()
        let bookmarking = FakeBookmarking()
        let bookmark = try SecureDirectoryAccess.makeBookmark(for: directory, bookmarking: bookmarking)

        bookmarking.setBehaviour(.stale)
        let status = SecureDirectoryAccess.status(for: bookmark, bookmarking: bookmarking)

        XCTAssertEqual(status, .granted(path: directory.path, isStale: true))
        XCTAssertTrue(status.isUsable)
        XCTAssertTrue(status.message.contains("过期"))
    }

    /// 目录被删除 / 移动：给出「已不存在」的可读提示，而不是静默失败。
    func testMissingDirectoryIsReportedWithSuggestion() throws {
        let directory = try makeDirectory()
        let bookmarking = FakeBookmarking()
        let bookmark = try SecureDirectoryAccess.makeBookmark(for: directory, bookmarking: bookmarking)

        try FileManager.default.removeItem(at: directory)
        let status = SecureDirectoryAccess.status(for: bookmark, bookmarking: bookmarking)

        XCTAssertEqual(status, .missing(path: directory.path))
        XCTAssertFalse(status.isUsable)
        XCTAssertTrue(status.message.contains("已不存在"))
        XCTAssertNotNil(status.recoverySuggestion)
        XCTAssertFalse(status.message.isEmpty)
    }

    func testResolutionFailureIsReportedReadably() throws {
        let directory = try makeDirectory()
        let bookmarking = FakeBookmarking()
        let bookmark = try SecureDirectoryAccess.makeBookmark(for: directory, bookmarking: bookmarking)

        bookmarking.setBehaviour(.resolutionFails("bookmark corrupted"))
        let status = SecureDirectoryAccess.status(for: bookmark, bookmarking: bookmarking)

        guard case .resolutionFailed(let reason) = status else {
            return XCTFail("应当判为解析失败，实际：\(status)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(status.message.contains("无法解析"))
        XCTAssertNotNil(status.recoverySuggestion)
        XCTAssertFalse(status.isUsable)
    }

    /// 「从未授权」是明确状态，有可读提示与补救建议 —— 不静默失败。
    func testNotAuthorizedStatusIsExplicitAndActionable() {
        let status = DirectoryAccessStatus.notAuthorized

        XCTAssertFalse(status.isUsable)
        XCTAssertTrue(status.message.contains("尚未授权"))
        XCTAssertNotNil(status.recoverySuggestion)
        XCTAssertNil(status.path)
    }

    /// 每个状态的提示都要能直接给人看。
    func testEveryStatusHasReadableMessage() {
        let statuses: [DirectoryAccessStatus] = [
            .granted(path: "/tmp/x", isStale: false),
            .granted(path: "/tmp/x", isStale: true),
            .notAuthorized,
            .missing(path: "/tmp/x"),
            .denied(path: "/tmp/x"),
            .resolutionFailed(reason: "r")
        ]
        for status in statuses {
            XCTAssertFalse(status.message.isEmpty)
            if !status.isUsable {
                XCTAssertNotNil(status.recoverySuggestion, "\(status) 缺少补救建议")
            }
        }
    }

    // MARK: - 取用与释放

    func testOpenStartsAndStopsAccessing() throws {
        let directory = try makeDirectory()
        let bookmarking = FakeBookmarking()
        let bookmark = try SecureDirectoryAccess.makeBookmark(for: directory, bookmarking: bookmarking)

        var grant: DirectoryGrant? = try SecureDirectoryAccess.open(bookmark, bookmarking: bookmarking)
        XCTAssertEqual(grant?.url.path, directory.path)
        XCTAssertTrue(grant?.startedAccessing ?? false)
        XCTAssertEqual(bookmarking.startCount, 1)
        // 在授权目录下拼产物文件路径。
        XCTAssertEqual(
            grant?.fileURL(named: "orders.csv").path,
            directory.appendingPathComponent("orders.csv").path
        )

        grant?.stopAccessing()
        XCTAssertEqual(bookmarking.stopCount, 1)
        // 重复 stop 不会重复释放。
        grant?.stopAccessing()
        XCTAssertEqual(bookmarking.stopCount, 1)

        grant = nil
    }

    /// 句柄释放时自动停止访问（RAII），不需要调用方记得 stop。
    func testGrantStopsAccessingOnDeinit() throws {
        let directory = try makeDirectory()
        let bookmarking = FakeBookmarking()
        let bookmark = try SecureDirectoryAccess.makeBookmark(for: directory, bookmarking: bookmarking)

        var grant: DirectoryGrant? = try SecureDirectoryAccess.open(bookmark, bookmarking: bookmarking)
        XCTAssertNotNil(grant)
        grant = nil

        XCTAssertEqual(bookmarking.stopCount, 1)
    }

    func testOpenOnUnusableBookmarkThrowsReadableError() throws {
        let directory = try makeDirectory()
        let bookmarking = FakeBookmarking()
        let bookmark = try SecureDirectoryAccess.makeBookmark(for: directory, bookmarking: bookmarking)
        try FileManager.default.removeItem(at: directory)

        XCTAssertThrowsError(
            try SecureDirectoryAccess.open(bookmark, bookmarking: bookmarking)
        ) { error in
            let accessError = error as? DirectoryAccessError
            XCTAssertNotNil(accessError)
            XCTAssertTrue(accessError?.errorDescription?.contains("已不存在") ?? false)
            XCTAssertNotNil(accessError?.recoverySuggestion)
        }
    }

    // MARK: - 与数据任务的衔接（FR-AI-05 + FR-AI-08）

    func testRequestExportSettingsProducesBookmarkBackedSettings() throws {
        let directory = try makeDirectory()
        let bookmarking = FakeBookmarking()

        let settings = try SecureDirectoryAccess.requestExportSettings(
            format: .csv,
            fileNameTemplate: "orders-{date}.csv",
            picker: FakeDirectoryPicker(directory: directory),
            bookmarking: bookmarking
        )

        let unwrapped = try XCTUnwrap(settings)
        XCTAssertEqual(unwrapped.format, .csv)
        XCTAssertEqual(unwrapped.fileNameTemplate, "orders-{date}.csv")
        XCTAssertNotNil(unwrapped.directoryBookmark)
        // 导出设置里存的是书签字节，不是路径。
        XCTAssertEqual(unwrapped.directoryBookmark, Data(directory.path.utf8))

        // 从设置恢复书签 → 状态可用。
        let restored = try XCTUnwrap(SecureDirectoryAccess.bookmark(from: unwrapped))
        XCTAssertEqual(
            SecureDirectoryAccess.status(for: restored, bookmarking: bookmarking),
            .granted(path: directory.path, isStale: false)
        )
    }

    /// 用户在选择面板里取消：返回 nil（不是错误）。
    func testRequestExportSettingsReturnsNilWhenCancelled() throws {
        let settings = try SecureDirectoryAccess.requestExportSettings(
            picker: FakeDirectoryPicker(directory: nil),
            bookmarking: FakeBookmarking()
        )

        XCTAssertNil(settings)
    }

    func testRequestExportSettingsPropagatesPickerError() {
        struct Cancelled: Error {}
        let picker = FakeDirectoryPicker(error: Cancelled())

        XCTAssertThrowsError(
            try SecureDirectoryAccess.requestExportSettings(picker: picker, bookmarking: FakeBookmarking())
        )
    }

    func testBookmarkFromSettingsWithoutExportDirectory() {
        let settings = DataTaskDefinition.ExportSettings(format: .json, directoryBookmark: nil)

        XCTAssertNil(SecureDirectoryAccess.bookmark(from: settings))
    }

    // MARK: - 持久化

    func testBookmarkStoreRoundTrip() async throws {
        let directory = try makeDirectory()
        let store = DirectoryBookmarkStore(directoryURL: directory)
        let target = try makeDirectory()
        // ISO8601 编码不带小数秒：用整秒时间戳，避免把「编码精度」误判成「数据丢失」。
        let bookmark = DirectoryBookmark(
            displayName: "导出目录",
            bookmarkData: Data(target.path.utf8),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastKnownPath: target.path
        )

        let empty = try await store.all()
        XCTAssertTrue(empty.isEmpty)

        try await store.save(bookmark)
        var all = try await store.all()
        XCTAssertEqual(all, [bookmark])

        try await store.rememberResolvedPath("/moved/elsewhere", for: bookmark.id)
        all = try await store.all()
        XCTAssertEqual(all.first?.lastKnownPath, "/moved/elsewhere")

        // 同 id 覆盖而不是追加。
        try await store.save(bookmark)
        all = try await store.all()
        XCTAssertEqual(all.count, 1)

        try await store.delete(id: bookmark.id)
        let remaining = try await store.all()
        XCTAssertTrue(remaining.isEmpty)
    }
}
