import Foundation

/// 查询归档**落在哪里**的判定（FR-EDIT-31 + FR-EDIT-32 衔接）。
///
/// 放在 Core 的理由：这是一段纯决策逻辑，而它恰好有一个容易含糊的优先级 ——
/// **用户单独指定的归档目录 > 工作区 > 没有**。写成纯函数就能把它钉死，
/// 不必等到"归档没写进预期目录"时再去界面上猜。
public enum ArchiveLocation {

    /// 归档根目录的来源。
    public enum Source: Equatable, Sendable {
        /// 用户在归档面板里单独指定过目录（书签已解析成功）。
        case chosen
        /// 没单独指定，跟随工作区。
        case workspace
        /// 既没指定、也没有工作区 —— 归档不写盘（调用方应如实说明原因）。
        case none
    }

    /// 解析归档根目录。
    ///
    /// - Parameters:
    ///   - chosenPath: 归档书签解析出的路径（`nil` = 没单独指定 / 书签不可用）。
    ///   - workspacePath: 当前工作区路径（`nil` = 没选工作区）。
    public static func root(chosenPath: String?, workspacePath: String?) -> (url: URL, source: Source)? {
        if let path = cleaned(chosenPath) {
            return (URL(fileURLWithPath: path, isDirectory: true), .chosen)
        }
        if let path = cleaned(workspacePath) {
            return (URL(fileURLWithPath: path, isDirectory: true), .workspace)
        }
        return nil
    }

    /// 归档实际写入的目录：根目录下的 `queries/`。
    ///
    /// 用子目录是为了不和数据任务产物、工作区里的代码混在一起 ——
    /// 这条在"归档跟随工作区"之后更重要：工作区是用户的项目目录，
    /// 直接往根上撒 `.sql` 文件会把人烦死。
    public static func queriesDirectory(chosenPath: String?, workspacePath: String?) -> (url: URL, source: Source)? {
        guard let resolved = root(chosenPath: chosenPath, workspacePath: workspacePath) else { return nil }
        return (resolved.url.appendingPathComponent("queries", isDirectory: true), resolved.source)
    }

    /// 去掉首尾空白；空串按"没给"处理（配置文件被手改成空白时不能当成一个目录）。
    static func cleaned(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
