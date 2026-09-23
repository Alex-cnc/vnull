import Foundation

/// 结果表格的**列对齐**判定（FR-RES 的呈现细节）。
///
/// 数值列右对齐、文本列左对齐，这不是审美偏好而是可用性：
/// 右对齐 + 等宽数字才能让小数点对齐、位数一眼可比。
///
/// 放在 Core 的理由：它是个纯函数，而**类型名匹配有一个经典陷阱** ——
/// 用 `contains("int")` 会把 `interval`、`point`、`print` 之类全判成数值；
/// 反过来漏掉 `numeric` / `double precision` / `timestamp with time zone` 也常见。
/// 这类判断"看起来显然"，但错了会让整列数字左对齐，很难在界面上一眼看出来。
public enum ColumnAlignment {

    public enum Alignment: Equatable, Sendable {
        case leading
        case trailing
    }

    /// 数值类型名（小写、去空白后**精确匹配**）。
    ///
    /// 覆盖 PostgreSQL 与 GBase / MySQL 两系的常见写法；
    /// 刻意列白名单而不是用子串匹配 —— 见类型文档里的陷阱说明。
    private static let numericTypes: Set<String> = [
        // 整数
        "smallint", "int2", "integer", "int", "int4", "bigint", "int8",
        "tinyint", "mediumint", "serial", "bigserial", "smallserial",
        // 浮点与定点
        "real", "float4", "float", "double", "float8", "double precision",
        "numeric", "decimal", "dec", "fixed", "money", "number",
        // 位串按数值看（对齐后更好核对）
        "bit", "varbit", "bit varying"
    ]

    /// 该类型是否按数值处理（右对齐 + 等宽数字）。
    public static func isNumeric(typeName: String) -> Bool {
        numericTypes.contains(normalize(typeName))
    }

    public static func alignment(for typeName: String) -> Alignment {
        isNumeric(typeName: typeName) ? .trailing : .leading
    }

    /// 归一化：小写、压空白、去掉精度与数组后缀。
    ///
    /// - `NUMERIC(12,2)` → `numeric`
    /// - `timestamp(6) with time zone` → `timestamp with time zone`
    /// - `varchar(64)[]` → `varchar[]`
    static func normalize(_ raw: String) -> String {
        var text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉括号里的精度（含 `(12,2)` / `(6)`）
        while let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") {
            text.removeSubrange(open...close)
        }
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
