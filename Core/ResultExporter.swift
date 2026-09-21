import Foundation

/// 查询结果的导出格式（FR-RES-06、FR-IO-01 ~ FR-IO-03）。
public enum ResultExportFormat: String, CaseIterable, Sendable {
    case csv
    case json
    /// 制表符分隔，便于直接粘进 Excel / Numbers。
    case tsv
    /// GitHub 风格 Markdown 表格，便于贴进文档与工单。
    case markdown
    /// 逐行 `INSERT INTO ... VALUES (...);`，可直接回放到库里。
    case sqlInsert

    /// 保存面板使用的扩展名。
    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        case .tsv: return "tsv"
        case .markdown: return "md"
        case .sqlInsert: return "sql"
        }
    }

    /// 默认文件名（不含扩展名）。
    public var defaultBaseName: String {
        "query-result"
    }

    /// 保存面板的类型标识。
    public var contentTypeIdentifier: String {
        switch self {
        case .csv: return "public.comma-separated-values-text"
        case .json: return "public.json"
        case .tsv: return "public.tab-separated-values-text"
        case .markdown: return "net.daringfireball.markdown"
        case .sqlInsert: return "public.plain-text"
        }
    }

    /// 生成内容时是否需要表名（只有 INSERT 语句需要）。
    public var requiresTableName: Bool {
        self == .sqlInsert
    }
}

/// 结果导出器（FR-RES-06、FR-IO-01 ~ FR-IO-03）。
///
/// 只做纯数据到文本的转换，不涉及 AppKit，方便单测覆盖：
/// - CSV 遵循 RFC 4180：字段含逗号/引号/换行时用双引号包裹，内部引号翻倍；
/// - JSON 结构固定为 `{"columns": [...], "rows": [ {...} ]}`，
///   重复列名自动加 `_2`、`_3` 后缀，避免字典键冲突丢列；
/// - TSV 用制表符分隔，字段内的制表符 / 换行替换为空格（否则列会错位）；
/// - Markdown 输出 GitHub 风格表格，`|` 转义为 `\|`，换行转成 `<br>`；
/// - INSERT 按列的 `typeName` 决定是否加引号：数值 / 布尔不加，其余按字符串
///   加单引号并把 `'` 翻倍（`standard_conforming_strings = on` 下反斜杠无需转义）；
/// - 除 INSERT 外都用 `NULL` 区分「空字符串」和「NULL 值」，TSV 例外（NULL 输出为空）。
public enum ResultExporter {
    /// CSV 文本。默认带 UTF-8 BOM，便于 Excel 直接识别中文。
    public static func csv(
        for result: QueryResult,
        includeByteOrderMark: Bool = true
    ) -> String {
        var lines: [String] = []

        if !result.columns.isEmpty {
            lines.append(csvHeader(for: result.columns))
        }

        for row in result.rows {
            lines.append(csvLine(row, columns: result.columns))
        }

        let body = lines.joined(separator: "\r\n")
        let text = lines.isEmpty ? "" : body + "\r\n"
        return includeByteOrderMark ? "\u{FEFF}" + text : text
    }

    /// CSV 表头行（流式导出与一次性导出共用，保证两者逐字节一致）。
    static func csvHeader(for columns: [ColumnMeta]) -> String {
        columns.map { escapeCSVField($0.name) }.joined(separator: ",")
    }

    /// CSV 数据行：按列数取值，缺列 / NULL 输出空字段。
    static func csvLine(_ row: [String?], columns: [ColumnMeta]) -> String {
        (0..<columns.count).map { index -> String in
            guard index < row.count, let value = row[index] else { return "" }
            return escapeCSVField(value)
        }.joined(separator: ",")
    }

    /// JSON 文本（UTF-8 字符串形式）。
    public static func json(for result: QueryResult) -> String {
        let keys = uniqueKeys(for: result.columns)
        let columnObjects = jsonColumnObjects(for: result.columns, keys: keys)

        let rowObjects = result.rows.map { row in
            "    " + jsonRowObject(row, keys: keys)
        }

        var parts: [String] = []
        parts.append("  \"rowCount\": \(result.rows.count)")
        parts.append("  \"affectedRows\": \(result.affectedRows.map(String.init) ?? "null")")
        parts.append("  \"columns\": [\n" + columnObjects.joined(separator: ",\n") + "\n  ]")
        parts.append("  \"rows\": [\n" + rowObjects.joined(separator: ",\n") + "\n  ]")

        return "{\n" + parts.joined(separator: ",\n") + "\n}\n"
    }

    /// JSON 的列描述对象（已缩进）。
    static func jsonColumnObjects(for columns: [ColumnMeta], keys: [String]) -> [String] {
        zip(columns, keys).map { column, key in
            "    { \"name\": \(quote(key)), \"type\": \(quote(column.typeName)) }"
        }
    }

    /// JSON 的单行对象（不含缩进，便于流式导出按需缩进）。
    static func jsonRowObject(_ row: [String?], keys: [String]) -> String {
        let pairs = keys.enumerated().map { index, key -> String in
            guard index < row.count, let value = row[index] else {
                return "\(quote(key)): null"
            }
            return "\(quote(key)): \(quote(value))"
        }
        return "{ " + pairs.joined(separator: ", ") + " }"
    }

    /// TSV 文本（制表符分隔，无 BOM，`\n` 换行）。
    ///
    /// 字段内的制表符 / 回车 / 换行替换为空格：TSV 没有通用的转义约定，
    /// 与其输出一个把列结构撑坏的文本，不如牺牲单元格内的原始空白。
    /// NULL 与空字符串都输出为空（表格软件里两者无法区分）。
    public static func tsv(for result: QueryResult) -> String {
        var lines: [String] = []

        if !result.columns.isEmpty {
            lines.append(tsvHeader(for: result.columns))
        }

        for row in result.rows {
            lines.append(tsvLine(row, columns: result.columns))
        }

        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// TSV 表头行。
    static func tsvHeader(for columns: [ColumnMeta]) -> String {
        columns.map { sanitizeTSVField($0.name) }.joined(separator: "\t")
    }

    /// TSV 数据行：NULL 与空字符串都输出为空（表格软件里两者无法区分）。
    static func tsvLine(_ row: [String?], columns: [ColumnMeta]) -> String {
        (0..<columns.count).map { index -> String in
            guard index < row.count, let value = row[index] else { return "" }
            return sanitizeTSVField(value)
        }.joined(separator: "\t")
    }

    /// Markdown（GitHub 风格）表格。
    ///
    /// 无列时返回空串；NULL 显示为 `NULL`，空字符串显示为空白单元格。
    public static func markdown(for result: QueryResult) -> String {
        guard !result.columns.isEmpty else { return "" }

        var lines: [String] = []
        lines.append(markdownHeader(for: result.columns))
        lines.append(markdownSeparator(for: result.columns))

        for row in result.rows {
            lines.append(markdownLine(row, columns: result.columns))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Markdown 表头行。
    static func markdownHeader(for columns: [ColumnMeta]) -> String {
        "| " + columns.map { escapeMarkdownCell($0.name) }.joined(separator: " | ") + " |"
    }

    /// Markdown 分隔行。
    static func markdownSeparator(for columns: [ColumnMeta]) -> String {
        "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |"
    }

    /// Markdown 数据行：NULL 显示 `NULL`，空字符串显示空白单元格。
    static func markdownLine(_ row: [String?], columns: [ColumnMeta]) -> String {
        let cells = (0..<columns.count).map { index -> String in
            guard index < row.count, let value = row[index] else { return "NULL" }
            return value.isEmpty ? "" : escapeMarkdownCell(value)
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    /// 逐行 `INSERT INTO <表> (<列...>) VALUES (...);`
    ///
    /// - 表名与列名用方言的 `quoteIdentifier` 包裹（PG 双引号 / GBase 反引号）；
    /// - 数值、布尔列不加引号（值无法解析成对应类型时退回字符串写法，保证语法正确）；
    /// - NULL 输出 `NULL`；
    /// - 没有列或没有行时返回空串。
    public static func insertStatements(
        for result: QueryResult,
        tableName: String,
        dialect: (any SQLDialect)? = nil
    ) -> String {
        guard !result.columns.isEmpty, !result.rows.isEmpty else { return "" }

        let prefix = insertPrefix(tableName: tableName, columns: result.columns, dialect: dialect)
        var statements: [String] = []
        statements.reserveCapacity(result.rows.count)

        for row in result.rows {
            statements.append(
                insertStatement(row, columns: result.columns, table: prefix.table, columnList: prefix.columnList)
            )
        }

        return statements.joined(separator: "\n") + "\n"
    }

    /// INSERT 语句的「表名 + 列清单」前缀（流式导出与一次性导出共用）。
    static func insertPrefix(
        tableName: String,
        columns: [ColumnMeta],
        dialect: (any SQLDialect)?
    ) -> (table: String, columnList: String) {
        let quote: (String) -> String
        if let dialect {
            quote = { dialect.quoteIdentifier($0) }
        } else {
            quote = { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        }
        return (quote(tableName), columns.map { quote($0.name) }.joined(separator: ", "))
    }

    /// 单行 INSERT 语句。
    static func insertStatement(
        _ row: [String?],
        columns: [ColumnMeta],
        table: String,
        columnList: String
    ) -> String {
        let values = columns.enumerated().map { index, column -> String in
            let value: String? = index < row.count ? row[index] : nil
            return sqlLiteral(value, typeName: column.typeName)
        }
        return "INSERT INTO \(table) (\(columnList)) VALUES (\(values.joined(separator: ", ")));"
    }

    /// 按格式取文本。
    /// - Parameters:
    ///   - tableName: 生成 INSERT 时使用的表名，默认 `table_name`（由界面传入页签标题等）。
    ///   - dialect: 生成 INSERT 时用于引用标识符的方言；缺省用 SQL 标准的双引号。
    public static func text(
        for result: QueryResult,
        format: ResultExportFormat,
        tableName: String = "table_name",
        dialect: (any SQLDialect)? = nil
    ) -> String {
        switch format {
        case .csv: return csv(for: result)
        case .json: return json(for: result)
        case .tsv: return tsv(for: result)
        case .markdown: return markdown(for: result)
        case .sqlInsert: return insertStatements(for: result, tableName: tableName, dialect: dialect)
        }
    }

    /// 结果是否有可导出内容：有列（含 0 行）或明确的影响行数。
    public static func hasExportableContent(_ result: QueryResult) -> Bool {
        !result.columns.isEmpty || result.affectedRows != nil
    }

    // MARK: - 内部

    static func escapeCSVField(_ value: String) -> String {
        let needsQuoting = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// TSV 单元格：空白类控制字符替换为空格，避免破坏行列结构。
    static func sanitizeTSVField(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\t", "\n", "\r":
                result.append(" ")
            default:
                result.append(character)
            }
        }
        return result
    }

    /// Markdown 单元格：转义竖线、反斜杠，换行转 `<br>`。
    static func escapeMarkdownCell(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "|": result += "\\|"
            case "\\": result += "\\\\"
            case "\r": continue
            case "\n": result += "<br>"
            default: result.append(character)
            }
        }
        return result
    }

    /// 依据列类型把值写成 SQL 字面量。
    static func sqlLiteral(_ value: String?, typeName: String) -> String {
        guard let value else { return "NULL" }

        let type = typeName.lowercased()

        if isBooleanType(type) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "t", "true", "1", "yes", "y", "on": return "TRUE"
            case "f", "false", "0", "no", "n", "off": return "FALSE"
            default: break
            }
        }

        if isNumericType(type), let number = ResultView.number(from: value) {
            // 整数列保留原样写法，避免 1e+03 这类科学计数法破坏精度观感。
            if isIntegerType(type), let integer = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return String(integer)
            }
            if number.isFinite {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func isBooleanType(_ type: String) -> Bool {
        type == "bool" || type == "boolean"
    }

    static func isIntegerType(_ type: String) -> Bool {
        type.contains("int") || type == "serial" || type == "bigserial" || type == "oid"
    }

    static func isNumericType(_ type: String) -> Bool {
        if isIntegerType(type) { return true }
        let numericHints = ["numeric", "decimal", "real", "double", "float", "money", "number"]
        return numericHints.contains { type.contains($0) }
    }

    /// 生成 JSON 键：重复列名加后缀，保证不丢列。
    static func uniqueKeys(for columns: [ColumnMeta]) -> [String] {
        var used: [String: Int] = [:]
        return columns.map { column in
            let base = column.name.isEmpty ? "column" : column.name
            let count = (used[base] ?? 0) + 1
            used[base] = count
            return count == 1 ? base : "\(base)_\(count)"
        }
    }

    static func quote(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }

        return "\"" + escaped + "\""
    }
}
