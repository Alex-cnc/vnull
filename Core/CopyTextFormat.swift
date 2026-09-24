import Foundation

/// `COPY … FROM STDIN` 的 **text 格式**编解码（FR-IO-03 的 COPY 路径）。
///
/// 为什么要单独把这一层写出来并单测：COPY 的 text 格式里，**"空串"与 NULL 只差一个字符**
/// （NULL 是 `\N`，空串是什么都不写），而制表符 / 换行 / 回车 / 反斜杠都必须在值里转义。
/// 这些规则一旦写错，症状是"导入进去的值悄悄少了反斜杠"或"NULL 变成空串"——
/// 都是**看着成功、数据已错**的那类问题，所以它值得有自己的单测。
///
/// 规则（PostgreSQL 文档 `COPY` 的 Text Format）：
/// - 列分隔符 `\t`、行分隔符 `\n`；
/// - **NULL 写成 `\N`**；空串写成**空**（两者不能混）；
/// - `\` → `\\`、`\t` → `\t`、`\n` → `\n`、`\r` → `\r`（反斜杠必须**先**处理）。
public enum CopyTextFormat {

    /// NULL 的表示。
    public static let nullLiteral = "\\N"
    public static let columnSeparator = "\t"
    public static let rowSeparator = "\n"

    /// 转义**一个值**（不含列分隔符）。
    ///
    /// - Parameter value: `nil` 表示 SQL NULL —— 与 `""`（空串）**不是**一回事。
    public static func escape(_ value: String?) -> String {
        guard let value else { return nullLiteral }
        // 反斜杠必须最先替换，否则后面插入的反斜杠会被再转义一次
        var text = value.replacingOccurrences(of: "\\", with: "\\\\")
        text = text.replacingOccurrences(of: "\t", with: "\\t")
        text = text.replacingOccurrences(of: "\n", with: "\\n")
        text = text.replacingOccurrences(of: "\r", with: "\\r")
        return text
    }

    /// 逆向：把 text 格式里的一个字段还原成值（`\N` → nil）。
    public static func unescape(_ field: String) -> String? {
        guard field != nullLiteral else { return nil }
        var result = ""
        var iterator = field.makeIterator()
        var pendingEscape = false
        while let character = iterator.next() {
            if pendingEscape {
                switch character {
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                default: result.append(character)
                }
                pendingEscape = false
                continue
            }
            if character == "\\" {
                pendingEscape = true
                continue
            }
            result.append(character)
        }
        // 结尾悬着的反斜杠：按字面反斜杠处理（不吞掉）
        if pendingEscape { result.append("\\") }
        return result
    }

    /// 编码一行（列之间用制表符分隔，**不含行尾换行**）。
    public static func encode(row: [String?]) -> String {
        row.map(escape).joined(separator: columnSeparator)
    }

    /// 编码多行（每行一个换行结尾 —— COPY 的 text 格式要求如此）。
    public static func encode(rows: [[String?]]) -> String {
        rows.map { encode(row: $0) + rowSeparator }.joined()
    }

    /// 反向解析一段 text 格式数据（用于单测与自检；不是导入路径的必需项）。
    public static func decode(_ text: String) -> [[String?]] {
        // 空输入 = **没有行**（`"".split` 会给出一个空子串，那是"一行空值"，语义不同）
        guard !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(text.hasSuffix("\n") ? 1 : 0)
            .map { line in
                line.split(separator: "\t", omittingEmptySubsequences: false).map { unescape(String($0)) }
            }
    }
}
