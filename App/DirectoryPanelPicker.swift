import AppKit
import DoyahCore

/// `NSOpenPanel` 实现的目录选择器（FR-AI-08）。
///
/// Core 只定义 `DirectoryPicker` 协议（不依赖 AppKit），真实选择在这里落地。
/// 为什么选择必须由用户亲手点出来：security-scoped bookmark **只能**由用户选择产生，
/// 这是「不硬编码路径」在接口形状上的约束（Core 那边没有「传个路径就能用」的入口）。
struct OpenPanelDirectoryPicker: DirectoryPicker {

    /// 弹出目录选择面板；**用户取消返回 `nil`（取消不是错误）**。
    func pickDirectory(prompt: String) throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
