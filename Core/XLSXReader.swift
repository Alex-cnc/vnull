import Foundation

/// `.xlsx` 读取（FR-IO-06）—— 纯 Swift、零依赖。
///
/// 与 FR-RES-14 的写入器是一对：那边自己写 ZIP + OOXML，这边自己**读** ZIP（含 deflate 解压，
/// 见 `Inflate`）与 OOXML。为什么不用第三方读取库：理由与写入器一样 —— Core 要平台中立、
/// 不想为一个"读表格"的需求背依赖，而且**能不能读对**可以用 Python 造的 xlsx 独立验证。
///
/// 支持的形状（够读真实 Excel / WPS / Numbers 导出的文件）：
/// - ZIP：**stored(0) 与 deflate(8)** 两种方法；中央目录定位；不做 ZIP64（明确报错，不猜）；
/// - `xl/workbook.xml`：工作表名与顺序（按 `xl/_rels/workbook.xml.rels` 解析真实路径，
///   因此 `sheet1.xml` 之外的编号也认）；
/// - `xl/sharedStrings.xml`：共享字符串（含富文本 `<r>` 分段拼接；**跳过 `<rPh>` 拼音块** ——
///   否则日文注音会被当成单元格内容）；
/// - `xl/styles.xml`：**日期判定**（内建格式号 + 自定义格式码），把 Excel 的日期序列号还原成
///   `YYYY-MM-DD [HH:MM:SS]`。不做这件事的后果很具体：Excel 里 2024-01-05 是一串数字
///   `45296`，直接导进日期列要么报错、要么（字符串列）存下一个谁都看不懂的数；
/// - 单元格类型：共享字符串(`s`) / 内联字符串(`inlineStr`) / 公式缓存(`str`) / 数字(默认) /
///   布尔(`b`) / 日期(`d`) / 错误(`e`，原样保留如 `#DIV/0!`)；
/// - **空单元格与空字符串分得开**：整格缺省 = NULL；存在但内容为空 = 空字符串
///   （与 `ResultExporter` 写出的 xlsx 语义一致，因此"导出再导入"能原样还原）。
///
/// **不做的事（如实写在这里，不假装）**：多工作表的合并读取（一次读一张，由调用方选）、
/// 单元格样式（颜色 / 批注 / 合并单元格）、公式求值（只取缓存值）、ZIP64、加密工作簿。
public enum XLSXReader {

    /// 一张工作表。
    public struct Sheet: Equatable, Sendable {
        public var name: String
        /// 稀疏网格补齐成矩形后的行（缺格为 nil = NULL）。
        public var rows: [[String?]]
        public var warnings: [String]

        public var columnCount: Int { rows.map(\.count).max() ?? 0 }
    }

    /// 读全部工作表（按 `workbook.xml` 里的顺序）。
    public static func sheets(_ data: Data) throws -> [Sheet] {
        let archive = try ZipArchive(data: data)
        guard let workbookXML = try archive.text(named: "xl/workbook.xml") else {
            throw XLSXReaderError.missingPart("xl/workbook.xml")
        }
        let relationshipsXML = try archive.text(named: "xl/_rels/workbook.xml.rels")
        let shared = try sharedStrings(archive)
        let dateStyles = try dateStyleIndexes(archive)
        let uses1904 = workbookXML.contains("date1904=\"1\"") || workbookXML.contains("date1904='1'")

        let sheetElements = MinimalXML.elements(in: workbookXML, named: "sheet")
        let relationships = RelationshipMap(xml: relationshipsXML ?? "")

        var result: [Sheet] = []
        for (index, element) in sheetElements.enumerated() {
            let name = element.attributes["name"] ?? "Sheet\(index + 1)"
            let relationshipID = element.attributes["r:id"] ?? element.attributes["id"] ?? ""
            // 目标路径优先走关系表；没有关系表时退回约定命名（老式写法的兜底）。
            let target = relationships.target(for: relationshipID) ?? "worksheets/sheet\(index + 1).xml"
            let path = normalizePartPath(target)
            guard let sheetXML = try archive.text(named: path) else {
                throw XLSXReaderError.missingPart(path)
            }
            var warnings: [String] = []
            let rows = parseSheet(
                xml: sheetXML,
                sharedStrings: shared,
                dateStyles: dateStyles,
                uses1904: uses1904,
                warnings: &warnings
            )
            result.append(Sheet(name: name, rows: rows, warnings: warnings))
        }
        guard !result.isEmpty else { throw XLSXReaderError.missingPart("xl/workbook.xml 里没有工作表") }
        return result
    }

    /// 读单张表并转成导入器认识的结构（与 CSV / JSON 的入口一致）。
    ///
    /// - Parameter sheet: 工作表序号，越界时抛 `sheetIndexOutOfRange`（不偷偷退回第一张 ——
    ///   那会让用户以为导的是他选的那张）。
    public static func importResult(
        _ data: Data,
        sheet index: Int = 0,
        hasHeader: Bool = true
    ) throws -> DelimitedTextReader.Result {
        let all = try sheets(data)
        guard index >= 0, index < all.count else {
            throw XLSXReaderError.sheetIndexOutOfRange(index, available: all.count)
        }
        return importResult(from: all[index], hasHeader: hasHeader)
    }

    /// 把一张表转成 `DelimitedTextReader.Result`（列名取首行；空列名补 `columnN`）。
    public static func importResult(from sheet: Sheet, hasHeader: Bool = true) -> DelimitedTextReader.Result {
        var warnings = sheet.warnings
        guard !sheet.rows.isEmpty else {
            return DelimitedTextReader.Result(header: [], rows: [], warnings: warnings)
        }

        let columnCount = max(sheet.columnCount, 1)
        var rows = sheet.rows
        let header: [String]
        if hasHeader {
            let first = rows.removeFirst()
            header = (0..<columnCount).map { index -> String in
                let value = index < first.count ? (first[index] ?? "") : ""
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "column\(index + 1)" : trimmed
            }
        } else {
            header = (0..<columnCount).map { "column\($0 + 1)" }
            warnings.append("文件没有表头：列名按位置生成（column1、column2…），列映射按名字匹配，可能对不上目标表")
        }

        // 补齐成矩形：短行补 nil，长行截到表头宽度 —— 否则列映射会错位。
        let normalized = rows.map { row -> [String?] in
            if row.count == columnCount { return row }
            if row.count > columnCount { return Array(row[0..<columnCount]) }
            return row + [String?](repeating: nil, count: columnCount - row.count)
        }
        return DelimitedTextReader.Result(header: header, rows: normalized, warnings: warnings)
    }

    // MARK: - 工作表解析

    static func parseSheet(
        xml: String,
        sharedStrings: [String],
        dateStyles: Set<Int>,
        uses1904: Bool,
        warnings: inout [String]
    ) -> [[String?]] {
        var rows: [[String?]] = []
        var rowIndex = 0

        for rowElement in MinimalXML.elements(in: xml, named: "row") {
            // `r` 是 1 基行号；缺省时按出现顺序递增（稀疏表要用它补齐中间的空行）。
            let declared = rowElement.attributes["r"].flatMap(Int.init)
            let targetIndex = (declared.map { $0 - 1 }) ?? rowIndex
            while rows.count < targetIndex { rows.append([]) }
            if rows.count == targetIndex { rows.append([]) }

            var cells: [String?] = []
            var columnIndex = 0
            for cell in MinimalXML.elements(in: rowElement.inner, named: "c") {
                let reference = cell.attributes["r"]
                let target = reference.flatMap(columnIndex(fromReference:)) ?? columnIndex
                while cells.count < target { cells.append(nil) }

                let value = cellValue(
                    cell: cell,
                    sharedStrings: sharedStrings,
                    dateStyles: dateStyles,
                    uses1904: uses1904,
                    rowNumber: targetIndex + 1,
                    warnings: &warnings
                )
                if cells.count == target { cells.append(value) } else { cells[target] = value }
                columnIndex = target + 1
            }
            rows[targetIndex] = cells
            rowIndex = targetIndex + 1
        }

        return trimTrailingEmpty(rows)
    }

    private static func cellValue(
        cell: MinimalXML.Element,
        sharedStrings: [String],
        dateStyles: Set<Int>,
        uses1904: Bool,
        rowNumber: Int,
        warnings: inout [String]
    ) -> String? {
        let type = cell.attributes["t"]
        if type == "inlineStr" {
            // 拼接 `<is>` 下的所有 `<t>`（跳过 `<rPh>` 拼音块）；一个 `<t>` 都没有时是空字符串
            // ——**不是** NULL：格子存在、内容为空，这一点与导出侧的语义对齐。
            let withoutPhonetics = MinimalXML.removingElements(in: cell.inner, named: "rPh")
            let text = MinimalXML.elements(in: withoutPhonetics, named: "t").map(\.inner).joined()
            return MinimalXML.decodeEntities(text)
        }

        guard let valueElement = MinimalXML.elements(in: cell.inner, named: "v").first else {
            // 没有 `<v>`（也没有内联串）：整格缺省 = NULL。
            return nil
        }
        let raw = MinimalXML.decodeEntities(valueElement.inner)

        switch type {
        case "s":
            guard let index = Int(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
            guard index >= 0, index < sharedStrings.count else {
                warnings.append("第 \(rowNumber) 行引用了不存在的共享字符串 #\(index)（按 NULL 处理）")
                return nil
            }
            return sharedStrings[index]
        case "b":
            // 布尔：`1/0` 原样交给导入器（`TableImport` 认 1/0/true/false）。
            return raw
        case "d":
            // ISO 8601 日期字符串：原样。
            return raw
        case "n", "str", "e", nil:
            break
        default:
            break
        }

        // 数字：若该格的样式是日期格式，把序列号还原成日期字符串。
        if let styleIndex = cell.attributes["s"].flatMap(Int.init), dateStyles.contains(styleIndex),
           let serial = Double(raw.trimmingCharacters(in: .whitespaces)) {
            if let converted = excelDateString(serial: serial, uses1904: uses1904) {
                return converted
            }
        }
        return raw
    }

    // MARK: - 共享字符串

    static func sharedStrings(_ archive: ZipArchive) throws -> [String] {
        guard let xml = try archive.text(named: "xl/sharedStrings.xml") else { return [] }
        return MinimalXML.elements(in: xml, named: "si").map { item in
            // 富文本：`<r><t>…</t></r>` 逐段拼接；`<rPh>`（拼音）整块跳过。
            let withoutPhonetics = MinimalXML.removingElements(in: item.inner, named: "rPh")
            let pieces = MinimalXML.elements(in: withoutPhonetics, named: "t").map(\.inner)
            return MinimalXML.decodeEntities(pieces.joined())
        }
    }

    // MARK: - 日期样式

    /// 哪些 `<cellXfs>` 下标是"日期样式"。
    ///
    /// 判据分两层：**内建格式号**（Excel 保留 14~22、27~36、45~47、50~58 给日期时间）与
    /// **自定义格式码**（`numFmtId >= 164`，看格式串里有没有 y/m/d/h/s 这类记号）。
    /// 只看记号会误判（`0.00"m"` 里的 m 是字面量），所以先把引号内与方括号里的内容剥掉再找。
    static func dateStyleIndexes(_ archive: ZipArchive) throws -> Set<Int> {
        guard let xml = try archive.text(named: "xl/styles.xml") else { return [] }

        var customDateFormatIDs: Set<Int> = []
        for numFmt in MinimalXML.elements(in: xml, named: "numFmt") {
            guard let id = numFmt.attributes["numFmtId"].flatMap(Int.init),
                  let code = numFmt.attributes["formatCode"] else { continue }
            if isDateLikeFormatCode(code) { customDateFormatIDs.insert(id) }
        }

        guard let cellXfsElement = MinimalXML.elements(in: xml, named: "cellXfs").first else { return [] }
        var result: Set<Int> = []
        for (index, xf) in MinimalXML.elements(in: cellXfsElement.inner, named: "xf").enumerated() {
            guard let id = xf.attributes["numFmtId"].flatMap(Int.init) else { continue }
            if builtinDateFormatIDs.contains(id) || customDateFormatIDs.contains(id) {
                result.insert(index)
            }
        }
        return result
    }

    static let builtinDateFormatIDs: Set<Int> = Set(
        Array(14...22) + Array(27...36) + Array(45...47) + Array(50...58)
    )

    static func isDateLikeFormatCode(_ code: String) -> Bool {
        var stripped = ""
        var inQuotes = false
        var inBrackets = false
        for character in code {
            switch character {
            case "\"":
                inQuotes.toggle()
            case "[" where !inQuotes:
                inBrackets = true
            case "]" where !inQuotes:
                inBrackets = false
            default:
                if !inQuotes, !inBrackets { stripped.append(character) }
            }
        }
        let lowered = stripped.lowercased()
        // 只有颜色 / 条件 / 货币符号的格式串不算日期。
        return lowered.contains("y") || lowered.contains("d")
            || lowered.contains("h") || lowered.contains("s")
            || (lowered.contains("m") && lowered.contains(":"))
    }

    /// Excel 序列号 → `YYYY-MM-DD` / `YYYY-MM-DD HH:MM:SS` / `HH:MM:SS`。
    ///
    /// 1900 日期系统有个著名的历史包袱：Excel 认为 1900 年是闰年（序列号 60 = 不存在的
    /// 1900-02-29）。因此 60 以前与 61 以后要用不同的基准日；序列号 60 我们**照原样**输出
    /// `1900-02-29`（如实反映文件里的值，而不是悄悄挪一天）。
    static func excelDateString(serial: Double, uses1904: Bool) -> String? {
        guard serial.isFinite else { return nil }
        if uses1904 {
            return formatted(serial: serial, baseComponents: (1904, 1, 1))
        }
        if serial == 60 { return "1900-02-29" }
        return serial < 60
            ? formatted(serial: serial, baseComponents: (1899, 12, 31))
            : formatted(serial: serial, baseComponents: (1899, 12, 30))
    }

    private static func formatted(serial: Double, baseComponents: (Int, Int, Int)) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = baseComponents.0
        components.month = baseComponents.1
        components.day = baseComponents.2
        guard let base = calendar.date(from: components) else { return nil }

        let days = serial.rounded(.towardZero)
        // 只保留时间时（0 < serial < 1）仍然按"同一天 + 时间"处理，输出只给时间部分。
        let fraction = serial - days
        let secondsInDay = 24.0 * 3600.0
        var seconds = Int((fraction * secondsInDay).rounded())
        if seconds >= Int(secondsInDay) { seconds -= Int(secondsInDay) }

        let date = base.addingTimeInterval(days * secondsInDay + Double(seconds))
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone

        let timeOnly = serial > 0 && serial < 1
        let stamp = String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
        let clock = String(
            format: "%02d:%02d:%02d",
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        if timeOnly { return clock }
        if seconds == 0 { return stamp }
        return stamp + " " + clock
    }

    /// `A` → 0、`AA` → 26（列号是 26 进制、但没有 0 位）。
    static func columnIndex(fromReference reference: String) -> Int? {
        var value = 0
        var sawLetter = false
        for character in reference.uppercased() {
            guard let ascii = character.asciiValue, ascii >= 65, ascii <= 90 else { break }
            sawLetter = true
            value = value * 26 + Int(ascii - 64)
        }
        return sawLetter ? value - 1 : nil
    }

    private static func trimTrailingEmpty(_ rows: [[String?]]) -> [[String?]] {
        var result = rows
        // 去掉尾部整行皆空的行（Excel 的 `<dimension>` 常把范围写大）。
        while let last = result.last, last.allSatisfy({ $0 == nil }) { result.removeLast() }
        // 再去掉尾部整列皆空的列。
        var width = result.map(\.count).max() ?? 0
        while width > 0 {
            let columnEmpty = result.allSatisfy { row in
                !row.indices.contains(width - 1) || row[width - 1] == nil
            }
            if !columnEmpty { break }
            width -= 1
        }
        return result.map { row in
            row.count > width ? Array(row[0..<width]) : row + [String?](repeating: nil, count: width - row.count)
        }
    }

    static func normalizePartPath(_ target: String) -> String {
        var path = target
        if path.hasPrefix("/") { path.removeFirst() }
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("../") { path.removeFirst(3) }
        if path.hasPrefix("xl/") { return path }
        // 关系表里的 target 是相对 `xl/` 的（`worksheets/sheet1.xml`）。
        return path.hasPrefix("worksheets/") || path.hasPrefix("sharedStrings") || path.hasPrefix("styles")
            ? "xl/" + path
            : path
    }

    /// `xl/_rels/workbook.xml.rels`：`rIdN → 目标路径`。
    struct RelationshipMap {
        private var map: [String: String] = [:]

        init(xml: String) {
            for relationship in MinimalXML.elements(in: xml, named: "Relationship") {
                guard let id = relationship.attributes["Id"],
                      let target = relationship.attributes["Target"] else { continue }
                map[id] = target
            }
        }

        func target(for id: String) -> String? { map[id] }
    }
}

/// `.xlsx` 读取的失败（都要有一句人能看懂的原因）。
public enum XLSXReaderError: Error, Equatable, LocalizedError {
    case notAZipArchive
    case zip64NotSupported
    case unsupportedCompression(Int)
    case missingPart(String)
    case sheetIndexOutOfRange(Int, available: Int)
    case inflateFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return "这不是一个 .xlsx 文件（ZIP 结构没找到）。真正的 .xls（BIFF）与 WPS 的 .et 都不是 xlsx，需要先在表格软件里另存为 .xlsx。"
        case .zip64NotSupported:
            return "这个工作簿用了 ZIP64 扩展（通常是超大文件），当前读取器不支持。"
        case .unsupportedCompression(let method):
            return "工作簿里使用了不支持的压缩方法（\(method)），当前只支持 stored(0) 与 deflate(8)。"
        case .missingPart(let part):
            return "工作簿缺少必需部件：\(part)。"
        case .sheetIndexOutOfRange(let index, let available):
            return "工作表序号 \(index + 1) 超出范围（这个文件有 \(available) 张表）。"
        case .inflateFailed(let reason):
            return "工作簿内容解压失败：\(reason)"
        }
    }
}

// MARK: - 极简 XML 读取

/// 只服务 OOXML 这几个已知形状的 XML 读取器。
///
/// 为什么不用 `XMLParser`：它在 Linux 上属于另一个模块（`FoundationXML`），用它就得在 Core 里写
/// 平台条件编译 —— 而 Core 的纪律是"不含平台判断"。这里用到的元素（`sheet` / `row` / `c` / `v` /
/// `t` / `si` / `xf` / `numFmt` / `Relationship`）都**互不嵌套同名**，所以"找起始标签 → 找到同名结束标签"
/// 这种朴素扫描是对的；真需要通用 XML 时再换实现不迟（那时也该换掉的是这个类型，不是调用方）。
enum MinimalXML {

    struct Element: Equatable {
        var attributes: [String: String]
        var inner: String
        var isSelfClosing: Bool
    }

    static func elements(in xml: String, named name: String) -> [Element] {
        var results: [Element] = []
        guard !xml.isEmpty else { return results }
        var searchStart = xml.startIndex

        while searchStart < xml.endIndex,
              let openRange = xml.range(of: "<\(name)", range: searchStart..<xml.endIndex) {
            let afterName = openRange.upperBound
            guard afterName < xml.endIndex else { break }
            let next = xml[afterName]
            guard next == ">" || next == "/" || next.isWhitespace else {
                searchStart = afterName
                continue
            }
            guard let tagEnd = endOfStartTag(xml, from: afterName) else { break }
            let tagText = String(xml[openRange.lowerBound...tagEnd])
            let attributes = parseAttributes(tagText)
            let isSelfClosing = tagText.hasSuffix("/>")

            if isSelfClosing {
                results.append(Element(attributes: attributes, inner: "", isSelfClosing: true))
                searchStart = xml.index(after: tagEnd)
                continue
            }

            let contentStart = xml.index(after: tagEnd)
            guard let closeRange = xml.range(of: "</\(name)>", range: contentStart..<xml.endIndex) else {
                // 没有闭合标签：把剩下的都当成内容（容错，不抛错 —— 读取侧宁可多给数据）。
                results.append(Element(attributes: attributes, inner: String(xml[contentStart...]), isSelfClosing: false))
                break
            }
            results.append(Element(attributes: attributes, inner: String(xml[contentStart..<closeRange.lowerBound]), isSelfClosing: false))
            searchStart = closeRange.upperBound
        }
        return results
    }

    /// 把某个元素的整块（含标签）从 XML 里去掉 —— 用于跳过 `<rPh>` 拼音块。
    static func removingElements(in xml: String, named name: String) -> String {
        var result = xml
        while let openRange = result.range(of: "<\(name)"),
              let tagEnd = endOfStartTag(result, from: openRange.upperBound) {
            let contentStart = result.index(after: tagEnd)
            if result[openRange.lowerBound...tagEnd].hasSuffix("/>") {
                result.removeSubrange(openRange.lowerBound...tagEnd)
                continue
            }
            guard let closeRange = result.range(of: "</\(name)>", range: contentStart..<result.endIndex) else { break }
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return result
    }

    /// 起始标签的 `>` 位置，跳过引号内的 `>`。
    static func endOfStartTag(_ xml: String, from index: String.Index) -> String.Index? {
        var cursor = index
        var quote: Character?
        while cursor < xml.endIndex {
            let character = xml[cursor]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return cursor
            }
            cursor = xml.index(after: cursor)
        }
        return nil
    }

    static func parseAttributes(_ tagText: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var cursor = tagText.startIndex
        // 跳过 `<name`
        while cursor < tagText.endIndex, tagText[cursor] != " " && tagText[cursor] != "\t"
            && tagText[cursor] != "\n" && tagText[cursor] != ">" && tagText[cursor] != "/" {
            cursor = tagText.index(after: cursor)
        }
        while cursor < tagText.endIndex {
            while cursor < tagText.endIndex, tagText[cursor].isWhitespace { cursor = tagText.index(after: cursor) }
            guard cursor < tagText.endIndex, tagText[cursor] != ">" , tagText[cursor] != "/" else { break }
            let nameStart = cursor
            while cursor < tagText.endIndex, tagText[cursor] != "=", tagText[cursor] != ">", !tagText[cursor].isWhitespace {
                cursor = tagText.index(after: cursor)
            }
            let name = String(tagText[nameStart..<cursor])
            while cursor < tagText.endIndex, tagText[cursor].isWhitespace { cursor = tagText.index(after: cursor) }
            guard cursor < tagText.endIndex, tagText[cursor] == "=" else {
                if cursor < tagText.endIndex { cursor = tagText.index(after: cursor) }
                continue
            }
            cursor = tagText.index(after: cursor)
            while cursor < tagText.endIndex, tagText[cursor].isWhitespace { cursor = tagText.index(after: cursor) }
            guard cursor < tagText.endIndex, tagText[cursor] == "\"" || tagText[cursor] == "'" else { continue }
            let quote = tagText[cursor]
            cursor = tagText.index(after: cursor)
            let valueStart = cursor
            while cursor < tagText.endIndex, tagText[cursor] != quote { cursor = tagText.index(after: cursor) }
            let value = String(tagText[valueStart..<cursor])
            if cursor < tagText.endIndex { cursor = tagText.index(after: cursor) }
            if !name.isEmpty { attributes[name] = decodeEntities(value) }
        }
        return attributes
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "&", let semicolon = text[cursor...].firstIndex(of: ";") else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            let entity = String(text[text.index(after: cursor)..<semicolon])
            if let decoded = decodeEntity(entity) {
                result.append(decoded)
                cursor = text.index(after: semicolon)
            } else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }
        return result
    }

    private static func decodeEntity(_ entity: String) -> Character? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                guard let value = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
                return Character(scalar)
            }
            if entity.hasPrefix("#") {
                guard let value = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(value) else { return nil }
                return Character(scalar)
            }
            return nil
        }
    }
}

// MARK: - ZIP 读取

/// 读 ZIP 中央目录 + 解压条目（stored / deflate）。只读，不写。
struct ZipArchive {
    struct Entry {
        var name: String
        var method: Int
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private let entries: [Entry]

    init(data: Data) throws {
        self.bytes = [UInt8](data)
        self.entries = try ZipArchive.readCentralDirectory(bytes)
        guard !entries.isEmpty else { throw XLSXReaderError.notAZipArchive }
    }

    var names: [String] { entries.map(\.name) }

    func data(named name: String) throws -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return try read(entry: entry)
    }

    func text(named name: String) throws -> String? {
        guard let payload = try data(named: name) else { return nil }
        return String(decoding: payload, as: UTF8.self)
    }

    private func read(entry: Entry) throws -> Data {
        let offset = entry.localHeaderOffset
        guard offset + 30 <= bytes.count, Self.readUInt32(bytes, offset) == 0x04034B50 else {
            throw XLSXReaderError.notAZipArchive
        }
        let nameLength = Int(Self.readUInt16(bytes, offset + 26))
        let extraLength = Int(Self.readUInt16(bytes, offset + 28))
        let start = offset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= bytes.count else { throw XLSXReaderError.notAZipArchive }
        let payload = Array(bytes[start..<(start + entry.compressedSize)])

        switch entry.method {
        case 0:
            return Data(payload)
        case 8:
            do {
                return Data(try Inflate.inflateRaw(payload))
            } catch {
                throw XLSXReaderError.inflateFailed(String(describing: error))
            }
        default:
            throw XLSXReaderError.unsupportedCompression(entry.method)
        }
    }

    static func readCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        // 从尾部往前找 EOCD（End of Central Directory）签名；注释最长 64K。
        let signature: UInt32 = 0x06054B50
        var eocd = -1
        var index = bytes.count - 22
        while index >= 0 {
            if readUInt32(bytes, index) == signature { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0, eocd + 22 <= bytes.count else { throw XLSXReaderError.notAZipArchive }

        let entryCount = Int(readUInt16(bytes, eocd + 10))
        let directoryOffset = Int(readUInt32(bytes, eocd + 16))
        guard entryCount > 0 else { return [] }

        var entries: [Entry] = []
        var cursor = directoryOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, readUInt32(bytes, cursor) == 0x02014B50 else {
                throw XLSXReaderError.notAZipArchive
            }
            let method = Int(readUInt16(bytes, cursor + 10))
            let compressedSize = Int(readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localOffset = Int(readUInt32(bytes, cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { throw XLSXReaderError.notAZipArchive }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw XLSXReaderError.zip64NotSupported
            }
            entries.append(
                Entry(
                    name: name,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset
                )
            )
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
