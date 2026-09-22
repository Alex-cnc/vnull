import Foundation
import Combine

/// 编辑器命令（由工具栏「编辑」菜单发出）。
enum EditorCommand: Equatable {
    case showFind
    case showReplace
    case goToLine(line: Int, column: Int?)
    case indent
    case outdent
    case clear
    case format
}

/// 工具栏 → 当前编辑器（`NSTextView`）的一次性命令通道。
///
/// `SQLEditorView` 观察 `request`，命中自己的 `tabID` 且请求 id 变化时执行一次。
final class EditorCommandCenter: ObservableObject {
    static let shared = EditorCommandCenter()

    struct Request: Equatable {
        let id: UUID
        let tabID: UUID
        let command: EditorCommand
    }

    @Published private(set) var request: Request?

    /// 各页签编辑器最近一次的光标 / 选区（UTF-16，`NSRange` 语义）。
    ///
    /// **刻意不做成 `@Published`**：光标每移动一次都会上报，若触发 SwiftUI 重绘，
    /// 打字过程会持续重算工具栏。执行时按需读取即可。
    private var selections: [UUID: NSRange] = [:]
    private let selectionLock = NSLock()

    private init() {}

    func send(_ command: EditorCommand, to tabID: UUID) {
        request = Request(id: UUID(), tabID: tabID, command: command)
    }

    /// 编辑器上报选区（`length == 0` 表示只有光标）。
    func reportSelection(tabID: UUID, range: NSRange) {
        selectionLock.lock()
        selections[tabID] = range
        selectionLock.unlock()
    }

    /// 读取某个页签最近的选区；没有上报过则返回 `nil`。
    func selection(for tabID: UUID) -> NSRange? {
        selectionLock.lock()
        defer { selectionLock.unlock() }
        return selections[tabID]
    }

    /// 页签关闭时清掉记录，避免按旧页签 id 取到过期选区。
    func forgetSelection(tabID: UUID) {
        selectionLock.lock()
        selections.removeValue(forKey: tabID)
        selectionLock.unlock()
    }
}
