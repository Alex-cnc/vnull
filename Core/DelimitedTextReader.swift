import Foundation

/// 分隔文本（CSV / TSV）读取（FR-IO-03）。
///
/// 为什么不用 `String.split(separator: ",")`：那样遇到引号、引号内的逗号与换行、`""` 转义、
/// CRLF、BOM 全都会错 —— 而这些在真实导出文件里**每一个都很常见**。导入功能最怕的
/// 就是"看着成功了，数据却错位"。
///
/// 设计：**回调式流式**（每读一行交给调用方），这样内存与文件大小无关；
/// 调用方按批攒够了就落库，不需要把整个文件读进内存。
public enum DelimitedTextReader {

    public struct Options: Equatable, Sendable {
        public var delimiter: Character
        public var quote: Character
        /// 首行是否是表头。
        public var hasHeader: Bool
        /// 空字段是否当成 NULL（默认是 —— 与 CSV 导出的约定一致）。
        public var emptyFieldIsNull: Bool

        public init(
            delimiter: Character = ",",
            quote: Character = "\"",
            hasHeader: Bool = true,
            emptyFieldIsNull: Bool = true
        ) {
            self.delimiter = delimiter
            self.quote = quote
            self.hasHeader = hasHeader
            self.emptyFieldIsNull = emptyFieldIsNull
        }

        public static let csv = Options()
        public static let tsv = Options(delimiter: "\t")
    }

    public struct Result: Equatable, Sendable {
        public var header: [String]
        public var rows: [[String?]]
        /// 解析过程中遇到的**结构问题**（列数不齐等）；不打断导入，但要如实报告。
        public var warnings: [String]
    }

    /// 一次性读取（测试与小文件用）。
    public static func read(_ text: String, options: Options = .csv) -> Result {
        var header: [String] = []
        var rows: [[String?]] = []
        var warnings: [String] = []
        var expectedColumns = 0
        var lineNumber = 0

        forEachRow(text, options: options) { row, isHeader in
            lineNumber += 1
            if isHeader {
                header = row.map { $0 ?? "" }
                expectedColumns = header.count
                return
            }
            if expectedColumns > 0, row.count != expectedColumns {
                warnings.append("第 \(lineNumber) 行列数 \(row.count) 与表头 \(expectedColumns) 不一致")
            }
            rows.append(row)
        }

        // 没有表头时按**位置**给一组占位列名（`column1…N`）。
        //
        // 为什么不是留空：空表头会让"按名字匹配"的列映射一列都对不上（`--no-header` 等于不可用），
        // 而占位列名能让导入器走**按位置**这条明确的路，映射预览里也看得见"文件第几列 → 目标第几列"。
        if !options.hasHeader, header.isEmpty, let first = rows.first {
            header = (0..<first.count).map { "column\($0 + 1)" }
        }

        return Result(header: header, rows: rows, warnings: warnings)
    }

    /// 逐行回调。`isHeader` 为 true 的那一行是表头（`hasHeader == false` 时不会出现）。
    ///
    /// **按 Unicode 标量扫描，不按 Character**：Swift 里 **CRLF（`\r\n`）是一个 Character**
    /// （单个扩展字素簇），拿它跟 `"\r"` / `"\n"` 比都不相等 —— 整块会被当成数据塞进字段，
    /// 于是"Windows 导出的文件被读成一行"。本轮实测踩到过（`CR COUNT: 0`）。
    /// 按标量处理后，CR / LF / 分隔符 / 引号都是单个标量，比较不再有歧义。
    public static func forEachRow(
        _ text: String,
        options: Options = .csv,
        _ body: (_ fields: [String?], _ isHeader: Bool) -> Void
    ) {
        let cleaned = stripBOM(text)
        let scalars = Array(cleaned.unicodeScalars)
        let delimiter = options.delimiter.unicodeScalars.first ?? ","
        let quote = options.quote.unicodeScalars.first ?? "\""
        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"

        var fields: [String?] = []
        var current = String.UnicodeScalarView()
        var isQuoted = false
        /// 该字段是否**被引号包裹过**：决定"空字段"是 NULL 还是空字符串。
        /// 必须在收字段时单独记 —— 闭合引号一消费，`isQuoted` 就已经变成 false 了（本轮踩到）。
        var wasQuoted = false
        var index = 0
        var isFirstRow = true

        func finishField() {
            if wasQuoted || !options.emptyFieldIsNull {
                fields.append(String(current))
            } else {
                fields.append(current.isEmpty ? nil : String(current))
            }
            current = String.UnicodeScalarView()
            isQuoted = false
            wasQuoted = false
        }

        func finishRow() {
            finishField()
            let isHeader = isFirstRow && options.hasHeader
            body(fields, isHeader)
            fields = []
            isFirstRow = false
        }

        while index < scalars.count {
            let scalar = scalars[index]

            if isQuoted {
                if scalar == quote {
                    // `""` 是转义后的引号本身
                    if index + 1 < scalars.count, scalars[index + 1] == quote {
                        current.append(quote)
                        index += 2
                        continue
                    }
                    isQuoted = false
                    index += 1
                    continue
                }
                // 引号内的换行与分隔符都是数据
                current.append(scalar)
                index += 1
                continue
            }

            if scalar == quote {
                isQuoted = true
                wasQuoted = true
                index += 1
                continue
            }
            if scalar == delimiter {
                finishField()
                index += 1
                continue
            }
            if scalar == cr || scalar == lf {
                // CRLF 是**两个标量**，这里按标量处理所以能正确识别。
                if scalar == cr, index + 1 < scalars.count, scalars[index + 1] == lf {
                    index += 1
                }
                finishRow()
                index += 1
                continue
            }

            current.append(scalar)
            index += 1
        }

        // 最后一行没有换行结尾时也要收
        if !fields.isEmpty || !current.isEmpty || isQuoted {
            finishRow()
        }
    }

    /// JSON 导入：接受 `[{...}, {...}]`（对象数组）。
    ///
    /// 只支持这一种形状并**明说**：CSV 与"对象数组"覆盖了绝大多数导出；
    /// 嵌套对象 / 数组字段一律转成 JSON 文本存进去，不猜。
    public static func readJSON(_ text: String) throws -> Result {
        guard let data = text.data(using: .utf8) else {
            throw ImportError.invalidJSON("不是合法 UTF-8")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let array = object as? [[String: Any]] else {
            throw ImportError.invalidJSON("顶层必须是对象数组（`[{...}, {...}]`）")
        }

        // 列顺序：以**出现顺序**为准（JSON 对象无序，但数组里的键顺序在解析后丢了，
        // 因此用所有对象键的并集按首次出现排序 —— 至少是稳定的）。
        var header: [String] = []
        for item in array {
            for key in item.keys.sorted() where !header.contains(key) {
                header.append(key)
            }
        }

        var warnings: [String] = []
        let rows: [[String?]] = array.enumerated().map { offset, item in
            let extra = Set(item.keys).subtracting(header)
            if !extra.isEmpty {
                warnings.append("第 \(offset + 1) 个对象有表头外的键：\(extra.sorted().joined(separator: "、"))")
            }
            return header.map { key in
                guard let value = item[key] else { return nil }
                return stringify(value)
            }
        }

        return Result(header: header, rows: rows, warnings: warnings)
    }

    /// 标量 → 字符串；嵌套结构转成 JSON 文本（不猜、不丢）。
    static func stringify(_ value: Any) -> String? {
        switch value {
        case is NSNull: return nil
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let text = String(data: data, encoding: .utf8)
            else { return "\(value)" }
            return text
        }
    }

    /// 去掉 UTF-8 BOM（否则第一个列名会带一个看不见的字符，映射就对不上了）。
    static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}

public enum ImportError: Error, Equatable, LocalizedError {
    case invalidJSON(String)
    case noColumns
    case unmappedColumns([String])
    case fileReadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let reason): return "JSON 格式不对：\(reason)"
        case .noColumns: return "没有可导入的列（表头为空？）"
        case .unmappedColumns(let names):
            return "这些列在目标表里不存在：\(names.joined(separator: "、"))"
        case .fileReadFailed(let reason): return "读取文件失败：\(reason)"
        }
    }
}
