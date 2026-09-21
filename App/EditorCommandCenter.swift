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

    private init() {}

    func send(_ command: EditorCommand, to tabID: UUID) {
        request = Request(id: UUID(), tabID: tabID, command: command)
    }
}
