import Foundation

/// 最小但**正确**的 xlsx 写入器（FR-RES-14）。
///
/// ## 为什么自己写而不是引第三方库
///
/// 这一项在需求里卡了很久，卡点是「引入 Excel 依赖前须评估体积与许可」。评估下来：
/// 常见 Swift/ObjC 的 xlsx 库都要求把一整棵依赖树与许可证一起带进仓（还有的会拉网络），
/// 而我们要的能力其实只有**写一个工作表**。xlsx 是 ZIP + 一组固定名字的 XML，
/// 这部分自己写是可控的：**逻辑全是纯函数，能逐条单测，产物能用 Python 的 zipfile
/// 独立解出来核对**（见 `Scripts/test-xlsx-export.sh`）。
///
/// ## 代价（写清楚，不藏着）
///
/// - ZIP 用 **stored（不压缩）**：实现简单且不依赖 zlib，代价是文件更大
///   （纯文本数据大约 3~5 倍）。要压缩得引入 raw DEFLATE，属后续。
/// - 只写**一个工作表**、只用到 inlineStr + 数字两种单元格类型，不做样式 / 公式 / 图表。
/// - 数据量按"一次导出"的规模设计（整表构建在内存里）。
public enum XLSXWriter {

    // MARK: - 入口

    /// 生成一个 xlsx 工作簿。
    ///
    /// - Parameters:
    ///   - sheetName: 工作表名（会按 Excel 的规则净化：去 `[]:*?/\`、截到 31 字符、空名回落 `Sheet1`）。
    ///   - columns: 表头（列名）。
    ///   - rows: 数据行（`nil` = 空单元格）。
    ///   - numericColumns: 哪些列按**数字**写（该列里解析不出数字的格子仍按文本写）。
    /// - Returns: xlsx 文件字节。同样的输入**逐字节相同**（ZIP 里的时间戳是固定值）。
    public static func workbook(
        sheetName: String,
        columns: [String],
        rows: [[String?]],
        numericColumns: Set<Int> = []
    ) -> Data {
        let sheet = sheetXML(columns: columns, rows: rows, numericColumns: numericColumns)
        let parts: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(rootRelsXML.utf8)),
            ("xl/workbook.xml", Data(workbookXML(sheetName: sheetName).utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelsXML.utf8)),
            ("xl/styles.xml", Data(stylesXML.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8))
        ]
        return zip(parts: parts)
    }

    // MARK: - 工作表名

    /// Excel 的工作表名规则：不能含 `[ ] : * ? / \`、长度 ≤ 31、不能为空、不能以单引号开头或结尾。
    public static func sanitizedSheetName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "[]:*?/\\")
        var cleaned = String(raw.unicodeScalars.filter { !forbidden.contains($0) })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("'") { cleaned.removeFirst() }
        if cleaned.hasSuffix("'") { cleaned.removeLast() }
        if cleaned.count > 31 { cleaned = String(cleaned.prefix(31)) }
        return cleaned.isEmpty ? "Sheet1" : cleaned
    }

    // MARK: - XML 片段

    private static var contentTypesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """
    }

    private static var rootRelsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
    }

    static func workbookXML(sheetName: String) -> String {
        let name = escape(sanitizedSheetName(sheetName))
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="\(name)" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
    }

    private static var workbookRelsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
    }

    /// 最小样式表。`fills` 里那两档（none + gray125）是 Excel 的**惯例要求**：
    /// 只给一档时 Excel 有时会报"文件已损坏"，而 LibreOffice 不报 —— 属于典型的"能过一半"的坑。
    private static var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border/></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
        </styleSheet>
        """
    }

    static func sheetXML(columns: [String], rows: [[String?]], numericColumns: Set<Int>) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """
        if !columns.isEmpty {
            xml += rowXML(index: 0, values: columns.map { Optional($0) }, numericColumns: [])
        }
        for (offset, row) in rows.enumerated() {
            xml += rowXML(index: offset + 1, values: row, numericColumns: numericColumns)
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    private static func rowXML(index: Int, values: [String?], numericColumns: Set<Int>) -> String {
        var xml = "<row r=\"\(index + 1)\">"
        for (column, value) in values.enumerated() {
            let reference = "\(columnName(column))\(index + 1)"
            guard let value else { continue }   // nil = 空单元格（不写 <c>，Excel 也认）
            if numericColumns.contains(column), let number = numericLiteral(value) {
                xml += "<c r=\"\(reference)\"><v>\(number)</v></c>"
            } else {
                let escaped = escape(value)
                // 前后有空白或含换行时必须 preserve，否则 Excel 会把它们吃掉。
                let needsPreserve = value != value.trimmingCharacters(in: .whitespacesAndNewlines)
                    || value.contains("\n") || value.contains("\r") || value.contains("\t")
                let space = needsPreserve ? " xml:space=\"preserve\"" : ""
                xml += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t\(space)>\(escaped)</t></is></c>"
            }
        }
        return xml + "</row>"
    }

    /// 数字字面量：只有在**能完整解析成有限 Double** 时才按数字写。
    ///
    /// 刻意不做"看着像数字就当数字"的宽松判断：`007`、`1e5`、`2026-09-24` 这类
    /// 按数字写会改变用户看得见的内容（丢前导零 / 变成科学计数 / 变成序列号），
    /// 宁可当文本 —— 宁可"看着不够聪明"，也不要悄悄改数据。
    static func numericLiteral(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed == value else { return nil }
        guard let number = Double(trimmed), number.isFinite else { return nil }
        // 前导零（`007`）与带前导 `+` 的写法都当文本，避免改变呈现。
        if trimmed.hasPrefix("+") { return nil }
        let body = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        if body.count > 1, body.hasPrefix("0"), !body.hasPrefix("0.") { return nil }
        return trimmed
    }

    /// A、B…Z、AA、AB…（列名 → 引用）
    static func columnName(_ index: Int) -> String {
        var value = index
        var name = ""
        repeat {
            let remainder = value % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            value = value / 26 - 1
        } while value >= 0
        return name
    }

    /// XML 文本转义。**还要处理 XML 1.0 不允许的控制字符**（`0x00-0x08`、`0x0B`、`0x0C`、`0x0E-0x1F`）：
    /// 它们不能出现在 XML 里，原样写进去 Excel 会直接判文件损坏，所以替换成 U+FFFD
    /// （而不是静默删掉 —— 让"这里有个坏字符"看得见）。
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                let value = scalar.value
                let forbidden = (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
                result.unicodeScalars.append(forbidden ? "\u{FFFD}" : scalar)
            }
        }
        return result
    }

    // MARK: - ZIP（stored）

    /// 打包成 ZIP。**时间戳固定**（1980-01-01 00:00:00，ZIP 的纪元）以保证同样输入逐字节相同 ——
    /// 否则每次导出的文件都不同，diff / 校验都无从谈起。
    static func zip(parts: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var directory = Data()

        for part in parts {
            let nameBytes = Data(part.name.utf8)
            let crc = crc32(part.data)
            let size = UInt32(part.data.count)
            let offset = UInt32(output.count)

            // 本地文件头
            output.appendUInt32(0x0403_4B50)
            output.appendUInt16(20)          // version needed
            output.appendUInt16(0)           // flags
            output.appendUInt16(0)           // method: stored
            output.appendUInt16(0)           // time
            output.appendUInt16(0x0021)      // date: 1980-01-01
            output.appendUInt32(crc)
            output.appendUInt32(size)        // compressed size
            output.appendUInt32(size)        // uncompressed size
            output.appendUInt16(UInt16(nameBytes.count))
            output.appendUInt16(0)           // extra length
            output.append(nameBytes)
            output.append(part.data)

            // 中央目录项
            directory.appendUInt32(0x0201_4B50)
            directory.appendUInt16(20)       // version made by
            directory.appendUInt16(20)       // version needed
            directory.appendUInt16(0)        // flags
            directory.appendUInt16(0)        // method
            directory.appendUInt16(0)        // time
            directory.appendUInt16(0x0021)   // date
            directory.appendUInt32(crc)
            directory.appendUInt32(size)
            directory.appendUInt32(size)
            directory.appendUInt16(UInt16(nameBytes.count))
            directory.appendUInt16(0)        // extra
            directory.appendUInt16(0)        // comment
            directory.appendUInt16(0)        // disk number
            directory.appendUInt16(0)        // internal attrs
            directory.appendUInt32(0)        // external attrs
            directory.appendUInt32(offset)
            directory.append(nameBytes)
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)

        // 中央目录结束记录
        output.appendUInt32(0x0605_4B50)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(parts.count))
        output.appendUInt16(UInt16(parts.count))
        output.appendUInt32(UInt32(directory.count))
        output.appendUInt32(directoryOffset)
        output.appendUInt16(0)
        return output
    }

    /// CRC-32（IEEE 802.3，ZIP 用的那个）。查表法，表是纯函数生成的。
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
