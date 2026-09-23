import Foundation
import DoyahCore

/// 编辑器补全的 App 侧入口（FR-EDIT-09 + FR-AI-13 S4）。
///
/// 规则本体在 Core（`QueryCompletion`，有单测），这里只做转发 ——
/// 留下来是因为 AppKit 回调需要这个调用形状。
enum SQLCompleter {
    /// 只给方言候选（关键字 + 内置函数）。空索引时的行为与历史版本逐字一致。
    static func suggestions(for prefix: String, dialect: SQLDialect) -> [String] {
        QueryCompletion.suggestions(prefix: prefix, dialect: dialect)
    }

    /// 方言候选 + **当前连接的查询记忆**（FR-AI-13 S4）。
    ///
    /// 记忆永远排在方言之后、只在有前缀时出现、且不顶掉关键字 —— 详见 `QueryCompletion`。
    static func suggestions(
        for prefix: String,
        dialect: SQLDialect,
        memory: QueryMemory.Index,
        connection: String?
    ) -> [String] {
        QueryCompletion.suggestions(
            prefix: prefix,
            dialect: dialect,
            memory: memory,
            connection: connection
        )
    }
}
