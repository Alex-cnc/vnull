import Foundation

/// 「复制为多格式」（FR-RES-12）：把结果区**选中的那些行**渲染成文本，放进剪贴板。
///
/// 与「导出」的区别只有两点，但都很关键：
/// 1. **范围是选中的行**（导出是全部）—— 用户常常只想把三行贴进工单；
/// 2. **目标决定格式**：贴进电子表格要 TSV、贴进文档 / 工单要 Markdown、贴进 SQL 编辑器要 `INSERT`。
///
/// 实现上**复用 `ResultExporter` 的渲染**（不另写一套）：那层已经把转义做对了 ——
/// TSV 会把制表符 / 换行替换成空格（否则一行会被拆成两行）、Markdown 会转义 `|` 并把换行写成 `<br>`。
/// 复制粘贴最怕的就是"看着一样、贴进去表格错位"，所以这里不重新发明。
public enum ResultClipboard {

    /// 可复制的格式。**默认 TSV**：贴进电子表格与工单都能直接成列。
    public enum Format: String, CaseIterable, Sendable {
        case tsv
        case markdown
        case insert
        case csv

        public var displayName: String {
            switch self {
            case .tsv: return "TSV"
            case .markdown: return "Markdown"
            case .insert: return "INSERT"
            case .csv: return "CSV"
            }
        }
    }

    public static let defaultFormat: Format = .tsv

    /// 渲染选中行为文本。没有行或没有列时返回空串（调用方据此跳过"复制"动作）。
    public static func text(
        rows: [[String?]],
        columns: [ColumnMeta],
        format: Format = ResultClipboard.defaultFormat,
        tableName: String = "table_name",
        schema: String? = nil,
        dialect: any SQLDialect = PostgresDialect()
    ) -> String {
        guard !columns.isEmpty, !rows.isEmpty else { return "" }
        // 只把选中的行拼成一个临时结果集：导出层的渲染逻辑原样复用。
        let subset = QueryResult(columns: columns, rows: rows)

        switch format {
        case .tsv: return ResultExporter.tsv(for: subset)
        case .markdown: return ResultExporter.markdown(for: subset)
        case .csv: return ResultExporter.csv(for: subset, includeByteOrderMark: false)
        case .insert:
            // `insertStatements` 返回的已经是多行文本（每行一条语句），不是数组。
            return ResultExporter.insertStatements(
                for: subset,
                tableName: tableName,
                schema: schema,
                dialect: dialect
            )
        }
    }

    /// 各格式在"空值"上的差异是**有意**的，这里集中说清（也有测试钉住）：
    /// - TSV / CSV：空着（表格软件里 NULL 与空串无法区分，硬写 `NULL` 反而会变成文字）；
    /// - Markdown：写 `NULL`（文档里必须能看出这是空值）；
    /// - INSERT：写 `NULL`（这是 SQL 语义，必须准确）。
    public static func nullRendering(for format: Format) -> String {
        switch format {
        case .tsv, .csv: return ""
        case .markdown, .insert: return "NULL"
        }
    }
}
