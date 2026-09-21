import Foundation
import PostgresClientCore

enum SQLHighlighter {
    static func highlight(_ sql: String, dialect: SQLDialect) -> AttributedString {
        // TODO: 后续替换为 NSTextStorage / STTextView 的高亮实现。
        // 当前先返回原文，保证编译与数据链路可跑。
        var attributed = AttributedString(sql)
        attributed.foregroundColor = .primary
        return attributed
    }
}
