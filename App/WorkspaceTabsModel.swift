import Foundation
import AppKit
import Combine
import DoyahCore

/// 工作区的页签与文件（FR-EDIT-35 / 36）。
///
/// **为什么在 App 层而不是塞进 `AppState`**：`AppState` 已经承担连接 / 执行 / 元数据 / 事务 / 智能体……
/// 再把工作区页签挂上去，它会变成那种"谁都不敢动"的中心类。工作区有自己的模型、自己的页签集合，
/// 与数据库那套**并列**（数据库侧当前处于冻结状态，见 SRS v3.180）。
@MainActor
final class WorkspaceTabsModel: ObservableObject {

    /// 单个文件的大小上限。超过就**如实拒绝**：把几十 MB 的日志塞进 `NSTextView`
    /// 会把界面卡死，而"能打开但卡死"比"明确说不打开"糟得多。
    static let maximumFileSize = 2 * 1024 * 1024

    @Published private(set) var tabs: [WorkspaceTab] = [.home()]
    @Published private(set) var selectedID: UUID?
    @Published private(set) var history = WorkspaceHistory()
    /// 失败原因（界面上如实显示，不静默）。
    @Published var errorText: String?
    /// 一次性提示（保存成功 / 按非 UTF-8 编码打开之类）。
    @Published var noticeText: String?

    private let store: WorkspaceHistoryStore

    init(store: WorkspaceHistoryStore = .standard()) {
        self.store = store
        var loaded = WorkspaceHistory()
        var problem: String?
        do {
            loaded = try store.load()
        } catch {
            problem = error.localizedDescription
        }
        history = loaded
        selectedID = tabs.first?.id
        if let problem {
            errorText = L(.workspaceHistoryLoadFailed, problem)
        }
    }

    // MARK: 选中与页签

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedID } ?? tabs.first
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func openHome() {
        if let home = tabs.first(where: { $0.isHome }) {
            selectedID = home.id
        }
    }

    /// 关闭页签。**有未保存改动时不关**（并说明原因）——
    /// 静默丢弃用户刚敲的代码是这类编辑器最不可原谅的行为。
    func close(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        guard !tab.isDirty else {
            errorText = L(.workspaceCloseBlockedDirty, tab.title)
            return
        }
        let next = WorkspaceTabSet.selection(afterClosing: id, in: tabs, selected: selectedID)
        tabs = WorkspaceTabSet.closing(id: id, in: tabs)
        selectedID = next ?? tabs.first?.id
    }

    func updateContent(_ text: String, for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].content != text else { return }
        tabs[index].content = text
    }

    // MARK: 打开 / 保存

    /// 打开一个文件：已经开着就切过去（**不重复开**）。
    func openFile(at url: URL) {
        let path = url.path
        if let existing = tabs.first(where: { $0.path == path }) {
            selectedID = existing.id
            return
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values.isDirectory != true else {
                errorText = L(.workspaceOpenFailedDirectory, url.lastPathComponent)
                return
            }
            if let size = values.fileSize, size > Self.maximumFileSize {
                errorText = L(
                    .workspaceFileTooLarge,
                    url.lastPathComponent,
                    Self.sizeText(Int64(size)),
                    Self.sizeText(Int64(Self.maximumFileSize))
                )
                return
            }
            let data = try Data(contentsOf: url)
            guard !data.contains(0) else {
                errorText = L(.workspaceFileBinary, url.lastPathComponent)
                return
            }
            let decoded = try TextFileDecoder.decode(data)
            let opened = WorkspaceTabSet.opening(path: path, in: tabs, content: decoded.text)
            tabs = opened.tabs
            selectedID = opened.selected
            record(file: path)
            // 编码不是 UTF-8 时说出来：用户得知道"看到的字为什么对了"（FR-IO-07 的同一套判决）。
            if decoded.isFallback {
                noticeText = L(.workspaceOpenedWithEncoding, url.lastPathComponent, decoded.encoding.shortName)
            }
        } catch {
            errorText = L(.workspaceOpenFailed, url.lastPathComponent, error.localizedDescription)
        }
    }

    /// 保存（⌘S）：写回原路径。
    func save(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard let path = tabs[index].path else { return }
        do {
            try tabs[index].content.write(toFile: path, atomically: true, encoding: .utf8)
            tabs[index].markSaved()
            noticeText = L(.workspaceFileSaved, tabs[index].title)
        } catch {
            errorText = L(.workspaceSaveFailed, tabs[index].title, error.localizedDescription)
        }
    }

    /// 当前选中页签的保存（给 ⌘S 用）。
    func saveSelected() {
        guard let id = selectedID else { return }
        save(id)
    }

    // MARK: 最近打开（Home 用）

    func record(file path: String) {
        history = WorkspaceHistory.recording(file: path, into: history)
        persistHistory()
    }

    func record(workspace path: String?) {
        guard let path, !path.isEmpty else { return }
        history = WorkspaceHistory.recording(workspace: path, into: history)
        persistHistory()
    }

    func removeRecentFile(_ path: String) {
        history = WorkspaceHistory.removing(file: path, from: history)
        persistHistory()
    }

    func clearHistory() {
        history = WorkspaceHistory()
        persistHistory()
    }

    private func persistHistory() {
        do {
            try store.save(history)
        } catch {
            // 存不下不影响使用，但要如实说一句
            errorText = L(.workspaceHistorySaveFailed, error.localizedDescription)
        }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
